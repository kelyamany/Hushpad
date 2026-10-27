import Foundation
import LocalScribeKit
import Observation

enum JobState: Equatable {
    case queued
    case downloading(Double)
    case running(PipelineStage)
    /// Paused by you (or by a recording starting); resumes where it stopped.
    case paused(Double)
    case failed(String)

    var title: String {
        switch self {
        case .queued: "Waiting…"
        case .downloading(let fraction): "Downloading the speech model… \(Int((fraction * 100).rounded()))%"
        case .running(.preparingModels): "Loading models…"
        case .running(.transcribing(let fraction)): "Transcribing… \(Int((fraction * 100).rounded()))%"
        case .running(.separatingSpeakers): "Telling speakers apart…"
        case .running(.merging), .running(.done): "Finishing up…"
        case .paused(let fraction): fraction > 0 ? "Paused at \(Int((fraction * 100).rounded()))%" : "Paused"
        case .failed: "Transcription failed"
        }
    }

    /// Real progress where there is one: the model download, and transcription part by part. Loading models and
    /// telling speakers apart don't report progress, so they show a spinner instead of a made-up percentage.
    var fraction: Double? {
        switch self {
        case .downloading(let fraction), .running(.transcribing(let fraction)), .paused(let fraction): fraction
        default: nil
        }
    }

    /// Waiting or working (not failed, not paused).
    var isActive: Bool {
        switch self {
        case .failed, .paused: false
        default: true
        }
    }

    var isPaused: Bool { if case .paused = self { true } else { false } }
}

/// Transcribes recordings one at a time and owns the speech models: which are on this device, downloading and
/// deleting them, and the loaded model kept warm between jobs. Audio never leaves the device.
///
/// It knows nothing about settings or the library list; `AppModel` hands it what it needs through `Hooks`.
@Observable
final class TranscriptionQueue {
    /// What the queue needs from the app.
    struct Hooks {
        var store: () -> RecordingStore
        var defaultModel: () -> WhisperModel
        var isDeleted: (UUID) -> Bool
        /// A meeting is about to be transcribed (its files must be readable in the background).
        var willStart: (UUID) -> Void
        /// A meeting has a new transcript.
        var didFinish: (Recording) -> Void
        /// Asked before a big download; false cancels it (metered connection).
        var allowDownload: (WhisperModel) async -> Bool
        /// A model download failed.
        var downloadFailed: (String) -> Void
    }

    private(set) var jobs: [UUID: JobState] = [:]
    /// Download progress by model id (and "speakers"), while a download runs.
    private(set) var modelDownloads: [String: Double] = [:]
    /// Bumped when a model is downloaded or deleted, so model lists refresh.
    private(set) var revision = 0

    private let diarizer: SpeakerKitDiarizer
    private let hooks: Hooks
    /// The loaded Whisper model, kept warm between jobs so back-to-back transcriptions start instantly.
    @ObservationIgnored private var whisper: WhisperKitEngine?
    /// Jobs run one at a time, in order: one model in memory.
    private struct Request {
        var recording: Recording
        var model: WhisperModel
    }
    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var current: (request: Request, task: Task<Void, Never>)?
    /// Jobs paused by you (as opposed to held for a recording, which resume by themselves).
    @ObservationIgnored private var pausedByUser: Set<UUID> = []
    /// While recording, nothing new starts and a running job steps aside.
    @ObservationIgnored private var held = false
    @ObservationIgnored private var downloaded: [String: Bool] = [:]

    init(diarizer: SpeakerKitDiarizer, hooks: Hooks) {
        self.diarizer = diarizer
        self.hooks = hooks
    }

    // MARK: Jobs

    /// Transcribes with the default model unless another is given. Uses the recording's remembered language and
    /// people-count hints, so a retry behaves like the original request.
    /// A paused job resumes where it stopped (same model and language).
    func transcribe(_ recording: Recording, with model: WhisperModel? = nil) {
        guard recording.hasAudio, current?.request.recording.id != recording.id else { return }
        let model = model ?? hooks.defaultModel()
        hooks.willStart(recording.id)
        pausedByUser.remove(recording.id)
        pending.removeAll { $0.recording.id == recording.id }
        pending.append(Request(recording: recording, model: model))
        jobs[recording.id] = .queued
        pump()
    }

    /// Stops a waiting or running job. The parts already transcribed are kept for `transcribe` to resume.
    func pause(_ id: UUID) {
        let fraction = jobs[id]?.fraction ?? hooks.store().partialTranscript(for: id)?.fraction ?? 0
        pending.removeAll { $0.recording.id == id }
        if let current, current.request.recording.id == id {
            pausedByUser.insert(id)
            current.task.cancel()
        }
        jobs[id] = .paused(fraction)
    }

    /// How far a transcription that isn't running got before it was paused or interrupted (e.g. by quitting).
    func pausedFraction(for id: UUID) -> Double? {
        if case .paused(let fraction) = jobs[id] { return fraction }
        guard jobs[id] == nil else { return nil }
        if let cached = partialCache[id] { return cached }
        let fraction = hooks.store().partialTranscript(for: id)?.fraction
        partialCache[id] = .some(fraction)
        return fraction
    }
    /// Disk lookups of interrupted jobs, so views can ask while drawing.
    @ObservationIgnored private var partialCache: [UUID: Double?] = [:]

    /// Recording: hold the queue so the meeting gets the device's full attention. A running job goes back to the
    /// front of the queue and resumes from its last finished part when the recording stops.
    func hold(_ hold: Bool) {
        held = hold
        if hold, let current {
            pending.insert(current.request, at: 0)
            jobs[current.request.recording.id] = .queued
            current.task.cancel()
        } else if !hold {
            pump()
        }
    }

    private func pump() {
        guard current == nil, !held, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        let recording = request.recording
        // Background priority: the Mac stays responsive while it works.
        let task = Task(priority: .utility) { [weak self] in
            await self?.run(recording, model: request.model, options: PipelineOptions(
                language: recording.language, roomSpeakers: recording.roomSpeakers, remoteSpeakers: recording.remoteSpeakers))
            self?.current = nil
            self?.pump()
        }
        current = (request, task)
    }

    /// The meeting was deleted: drop its job.
    func forget(_ id: UUID) { jobs[id] = nil }

    private func setJob(_ id: UUID, _ state: JobState?) {
        if hooks.isDeleted(id) {
            jobs[id] = nil
            return
        }
        jobs[id] = state
        partialCache[id] = nil
        #if os(iOS)
        if let fraction = state?.fraction { BackgroundWork.shared.update(id: id, kind: .transcribe, fraction: fraction, status: state?.title) }
        #endif
    }

    private func run(_ recording: Recording, model: WhisperModel, options: PipelineOptions) async {
        let id = recording.id
        guard !hooks.isDeleted(id) else { return }
        #if os(iOS)
        // Keeps transcription running if the user locks the phone, with system progress UI.
        BackgroundWork.shared.begin(id: id, kind: .transcribe, title: "Transcribing", subtitle: recording.title) { [weak self] in
            self?.setJob(id, .failed("Stopped because the app was in the background too long. Open the app and try again."))
        }
        #endif
        var success = false
        defer {
            #if os(iOS)
            BackgroundWork.shared.finish(id: id, kind: .transcribe, success: success)
            #endif
        }
        do {
            if !isDownloaded(model) || !speakerModelDownloaded {
                guard await hooks.allowDownload(model) else {
                    setJob(id, .failed("The speech model needs a download. Connect to Wi-Fi, then tap Try Again."))
                    return
                }
                setJob(id, .downloading(0))
            }
            let engine = try await loadedEngine(for: model) { [weak self] fraction in
                Task { @MainActor in self?.setJob(id, .downloading(fraction)) }
            }
            downloaded[model.id] = true
            setJob(id, .running(.preparingModels))
            // The audio may live in iCloud Drive and not be downloaded on this device yet.
            let store = hooks.store()
            let tracks = store.tracks(for: recording)
            for url in [tracks.mic, tracks.system].compactMap({ $0 }) { try store.ensureLocal(url) }
            let pipeline = TranscriptPipeline(engine: engine, diarizer: diarizer)
            let checkpoint = TranscriptionCheckpoint(load: { store.partialTranscript(for: id) },
                                                     save: { try? store.savePartial($0, for: id) })
            let transcript = try await pipeline.run(tracks: tracks, options: options, checkpoint: checkpoint) { [weak self] stage in
                Task { @MainActor in
                    // A pause can land just before a progress update; don't let the update undo it.
                    guard let self, self.jobs[id]?.isPaused != true, !Task.isCancelled else { return }
                    self.setJob(id, .running(stage))
                }
            }
            try store.save(transcript, for: id)
            store.removePartial(for: id)
            var updated = store.recording(id: id) ?? recording
            updated.activeEngine = transcript.engine
            try store.save(updated)
            setJob(id, nil)
            success = true
            hooks.didFinish(updated)
        } catch is CancellationError {
            // Paused by you, or held for a recording: `pause` and `hold` already set the state.
            if pausedByUser.contains(id) { jobs[id] = .paused(partial(id)?.fraction ?? jobs[id]?.fraction ?? 0) }
        } catch where Task.isCancelled {
            if pausedByUser.contains(id) { jobs[id] = .paused(partial(id)?.fraction ?? jobs[id]?.fraction ?? 0) }
        } catch {
            // Deleted while transcribing: nothing to report.
            setJob(id, hooks.isDeleted(id) ? nil : .failed(error.localizedDescription))
        }
    }

    private func partial(_ id: UUID) -> PartialTranscript? { hooks.store().partialTranscript(for: id) }

    private func loadedEngine(for model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKitEngine {
        if let whisper, whisper.model == model { return whisper }
        await whisper?.unload()
        whisper = nil
        let engine = try WhisperKitEngine(model: model)
        try await engine.prepare(progress: progress)
        whisper = engine
        return engine
    }

    // MARK: Models

    /// Checked on disk once per model and cached; refreshed after downloads and deletions.
    func isDownloaded(_ model: WhisperModel) -> Bool {
        if let known = downloaded[model.id] { return known }
        let value = (try? WhisperKitEngine(model: model))?.isDownloaded ?? false
        downloaded[model.id] = value
        return value
    }

    var speakerModelDownloaded: Bool { diarizer.isDownloaded }

    /// Both models needed for the default transcription are on the device.
    var modelsReady: Bool { isDownloaded(hooks.defaultModel()) && speakerModelDownloaded }

    func download(_ model: WhisperModel) async {
        guard await hooks.allowDownload(model) else { return }
        modelDownloads[model.id] = 0
        defer { modelDownloads[model.id] = nil; downloaded[model.id] = nil; revision += 1 }
        do {
            let id = model.id
            let engine = try WhisperKitEngine(model: model)
            try await engine.prepare { [weak self] fraction in
                Task { @MainActor in self?.modelDownloads[id] = fraction }
            }
            if model == hooks.defaultModel(), whisper == nil { whisper = engine } else { await engine.unload() }
        } catch {
            hooks.downloadFailed("Download failed: \(error.localizedDescription)")
        }
    }

    func downloadSpeakerModel() async {
        modelDownloads["speakers"] = 0
        defer { modelDownloads["speakers"] = nil; revision += 1 }
        do { try await diarizer.prepare() } catch { hooks.downloadFailed("Download failed: \(error.localizedDescription)") }
    }

    /// False if the files couldn't be removed (the model stays listed as downloaded).
    @discardableResult
    func deleteModel(_ model: WhisperModel) async -> Bool {
        if whisper?.model == model {
            await whisper?.unload()
            whisper = nil
        }
        if let engine = try? WhisperKitEngine(model: model), FileManager.default.fileExists(atPath: engine.localFolder.path) {
            do {
                try FileManager.default.removeItem(at: engine.localFolder)
            } catch {
                hooks.downloadFailed("Couldn't delete \(model.displayName): \(error.localizedDescription)")
                return false
            }
        }
        downloaded[model.id] = nil
        revision += 1
        return true
    }
}
