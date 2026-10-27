import AVFoundation
import CoreGraphics
import Foundation

public struct RecordingOptions: Sendable {
    public var title: String
    public var language: TranscriptLanguage
    public var notesLanguage: TranscriptLanguage
    /// macOS: also record call audio from Zoom / Teams / Meet.
    public var captureSystemAudio: Bool
    public var screenshots: ScreenshotMode
    /// Caption the recording as it happens, on the device (see `LiveTranscriber`).
    public var liveTranscript: Bool

    public init(title: String, language: TranscriptLanguage = .auto, notesLanguage: TranscriptLanguage = .auto,
                captureSystemAudio: Bool = true, screenshots: ScreenshotMode = .manual, liveTranscript: Bool = false) {
        self.title = title
        self.language = language
        self.notesLanguage = notesLanguage
        self.captureSystemAudio = captureSystemAudio
        self.screenshots = screenshots
        self.liveTranscript = liveTranscript
    }
}

/// One live recording: the room mic, call audio (Mac), and screenshots, all on one clock.
@MainActor
public final class RecordingSession {
    public private(set) var recording: Recording
    public let startDate = Date()
    /// Non-fatal problems to show the user (e.g. system audio unavailable, so only the mic is recorded).
    public private(set) var warnings: [String] = []

    /// Where the recording is captured (local), and where it goes when it's finished (maybe a synced folder).
    private let store: RecordingStore
    private let library: RecordingStore
    private let startHostTime = mach_absolute_time()
    private let options: RecordingOptions
    private let micWriter: TrackWriter
    private let micRecorder: MicRecorder
    private var systemWriter: TrackWriter?
    /// Keeps the Mac (and its display) awake while recording, so a long call isn't cut by sleep.
    private var awake: NSObjectProtocol?
    #if os(macOS)
    private var systemRecorder: SystemAudioRecorder?
    private var screenCapturer: ScreenCapturer?
    #endif

    public init(library: RecordingStore, options: RecordingOptions) throws {
        self.library = library
        store = try RecordingStore.staging()
        self.options = options
        recording = Recording(title: options.title, hasMic: true, hasSystemAudio: false, language: options.language,
                              notesLanguage: options.notesLanguage)
        try store.createFolder(for: recording)
        micWriter = try TrackWriter(url: store.micURL(for: recording.id), startHostTime: startHostTime)
        micRecorder = MicRecorder(writer: micWriter)
    }

    public var folder: URL { store.folder(for: recording.id) }
    public var elapsed: Double { Date().timeIntervalSince(startDate) }
    public private(set) var isPaused = false
    /// Live captions, when turned on.
    public private(set) var live: LiveTranscriber?
    public var micLevel: Float { micWriter.level }
    public var systemLevel: Float? { systemWriter?.level }

    /// A problem that is losing audio right now (disk full, call audio dropped). Nil while all is well.
    public var problem: String? {
        #if os(macOS)
        let system = systemRecorder?.problem
        #else
        let system: String? = nil
        #endif
        return micWriter.writeFailure.map { "Recording stopped saving the microphone: \($0)" }
            ?? systemWriter?.writeFailure.map { "Recording stopped saving call audio: \($0)" }
            ?? system
    }

    public func start() throws {
        guard Permissions.status(.microphone) == .granted else {
            throw LocalScribeError.permissionDenied("Microphone access is off. Turn it on in Settings to record.")
        }
        try micRecorder.start()
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                      reason: "Recording a meeting")

        #if os(macOS)
        if options.captureSystemAudio {
            do {
                let writer = try TrackWriter(url: store.systemURL(for: recording.id), startHostTime: startHostTime)
                let recorder = SystemAudioRecorder(writer: writer)
                try recorder.start()
                systemWriter = writer
                systemRecorder = recorder
                recording.hasSystemAudio = true
            } catch {
                warnings.append("Call audio isn't being recorded: \(error.localizedDescription)")
            }
        }
        if options.screenshots != .off {
            if !CGPreflightScreenCaptureAccess() {
                warnings.append("Screenshots are off: allow LocalScribe under System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
            let capturer = ScreenCapturer(recordingFolder: folder, startHostTime: startHostTime, mode: options.screenshots)
            screenCapturer = capturer
            Task { await capturer.start() }
        }
        #endif
        if options.liveTranscript {
            let live = LiveTranscriber(language: options.language, sources: systemWriter == nil ? [.microphone] : [.microphone, .call])
            micWriter.onAudio = live.sink(for: .microphone)
            systemWriter?.onAudio = live.sink(for: .call)
            live.start()
            self.live = live
        }
        try store.save(recording)
    }

    /// Stops capturing audio until `resume()`. Nothing said while paused is recorded.
    public func pause() {
        isPaused = true
        micWriter.isPaused = true
        systemWriter?.isPaused = true
        #if os(macOS)
        if let capturer = screenCapturer { Task { await capturer.setPaused(true) } }
        #endif
    }

    public func resume() {
        isPaused = false
        micWriter.isPaused = false
        systemWriter?.isPaused = false
        #if os(macOS)
        if let capturer = screenCapturer { Task { await capturer.setPaused(false) } }
        #endif
    }

    #if os(macOS)
    @discardableResult
    public func captureScreenshot() async -> Screenshot? {
        guard !isPaused, let capturer = screenCapturer else { return nil }
        return await capturer.captureNow()
    }
    #endif

    /// Renames the recording while it's still running.
    public func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.title else { return }
        recording.title = trimmed
        try? store.save(recording)
    }

    /// Adds a photo (iPhone camera) at the current point in the recording.
    @discardableResult
    public func addPhoto(jpeg: Data) throws -> Screenshot {
        try ScreenshotStore.save(jpeg: jpeg, at: elapsed, in: folder)
    }

    /// Stops all capture and finalises the files. Returns the saved recording.
    public func stop() async -> Recording {
        micRecorder.stop()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        #if os(macOS)
        systemRecorder?.stop()
        if let capturer = screenCapturer { await capturer.stop() }
        #endif

        let mic = micWriter.finish()
        recording.duration = mic.duration
        if let failure = mic.failure { warnings.append("The microphone recording is incomplete: \(failure)") }
        if let systemWriter {
            let system = systemWriter.finish()
            recording.duration = max(recording.duration, system.duration)
            if let failure = system.failure { warnings.append("The call audio is incomplete: \(failure)") }
            #if os(macOS)
            if let problem = systemRecorder?.problem { warnings.append(problem) }
            #endif
            if system.peak == 0 {
                // Pure digital silence usually means the permission was denied. The file stays on disk but isn't transcribed.
                recording.hasSystemAudio = false
                warnings.append("Call audio was silent. If you were on a call, allow LocalScribe under System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
        }
        // Both tracks are written on the same clock, so no offset is needed.
        recording.systemOffset = 0
        try? store.save(recording)
        // The captions become a first transcript, so notes and questions work right away. The full transcript
        // replaces it as the meeting's transcript when it's done.
        if let live {
            await live.stop()
            if let transcript = live.transcript.transcript(language: options.language) {
                try? store.save(transcript, for: recording.id)
            }
        }
        moveToLibrary()
        return recording
    }

    /// Notes typed during the recording; stored next to the audio.
    public func saveNotes(_ text: String) {
        try? store.saveNotes(text, for: recording.id, .mine)
    }

    private func moveToLibrary() {
        do {
            try library.adopt(folder: store.folder(for: recording.id), recording: recording)
        } catch {
            // Stays safe in the local staging area; `recoverUnfinished` retries on next launch.
            warnings.append("The recording is saved on this device but couldn't be moved to your library folder yet: \(error.localizedDescription)")
        }
    }

    /// After a crash or force-quit mid-recording: finish whatever is left in the staging area
    /// (the WAV headers are kept valid while recording) and move it into the library.
    /// Returns the recordings that were recovered.
    public static func recoverUnfinished(into library: RecordingStore, excluding active: UUID? = nil) -> [Recording] {
        guard let staging = try? RecordingStore.staging() else { return [] }
        return staging.loadAll().compactMap { recording in
            guard recording.id != active else { return nil }
            var recovered = recording
            let mic = staging.micURL(for: recording.id), system = staging.systemURL(for: recording.id)
            recovered.hasMic = FileManager.default.fileExists(atPath: mic.path)
            recovered.hasSystemAudio = FileManager.default.fileExists(atPath: system.path)
            recovered.duration = max(AudioInfo.duration(of: mic), AudioInfo.duration(of: system))
            try? staging.save(recovered)
            guard (try? library.adopt(folder: staging.folder(for: recording.id), recording: recovered)) != nil else { return nil }
            return recovered
        }
    }
}
