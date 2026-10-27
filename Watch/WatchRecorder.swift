import AVFoundation
import Foundation
import LocalScribeCore
import Observation

/// Records on the Watch, then hands the audio to the iPhone, which transcribes it.
/// Audio is deleted from the Watch once the iPhone confirms it has the file (Watch storage is small), and the
/// whole entry a day later.
@Observable
final class WatchRecorder {
    enum SyncState: Equatable {
        case recordedOnly      // waiting for the iPhone (out of range / app never installed)
        case sending
        case onPhone
        case failed(String)
    }

    private(set) var recordings: [Recording] = []
    private(set) var syncStates: [UUID: SyncState] = [:]
    private(set) var startedAt: Date?
    private(set) var isStarting = false
    var errorMessage: String?

    var isRecording: Bool { startedAt != nil }
    var level: Float { writer?.level ?? 0 }

    private let store: RecordingStore
    private let link = PhoneLink()
    private var writer: TrackWriter?
    private var mic: MicRecorder?
    private var current: Recording?

    init() {
        do {
            store = try RecordingStore()
        } catch {
            // Without its own folder the Watch can still record into a temporary one and send it to the iPhone.
            guard let temporary = try? RecordingStore(root: FileManager.default.temporaryDirectory) else {
                fatalError("Can't create a folder for recordings: \(error)")
            }
            store = temporary
        }
        link.onActivated = { [weak self] in self?.resendPending() }
        link.onFinished = { [weak self] id, error in self?.transferFinished(id, error: error) }
        link.onAcknowledged = { [weak self] ids in self?.acknowledged(ids) }
        link.activate()
        reload()
    }

    // MARK: Recording

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        if AVAudioApplication.shared.recordPermission != .granted {
            guard await AVAudioApplication.requestRecordPermission() else {
                errorMessage = "Allow the microphone in Settings › Privacy › Microphone on your Watch."
                return
            }
        }
        let recording = Recording(title: Self.defaultTitle(), hasMic: true, source: .watch)
        do {
            try store.createFolder(for: recording)
            let writer = try TrackWriter(url: store.micURL(for: recording.id), startHostTime: mach_absolute_time())
            let mic = MicRecorder(writer: writer)
            try mic.start()
            try store.save(recording)
            self.writer = writer
            self.mic = mic
            current = recording
            startedAt = Date()
        } catch {
            try? store.delete(recording.id)
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard let mic, let writer, var recording = current else { return }
        mic.stop()
        let summary = writer.finish()
        recording.duration = summary.duration
        self.mic = nil
        self.writer = nil
        current = nil
        startedAt = nil
        do {
            try store.save(recording)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
        send(recording)
    }

    // MARK: Sending to iPhone

    private func send(_ recording: Recording) {
        let audio = store.micURL(for: recording.id)
        guard FileManager.default.fileExists(atPath: audio.path) else { return }
        guard link.isReady else {
            syncStates[recording.id] = .recordedOnly
            return
        }
        do {
            try link.send(recording, audio: audio)
            syncStates[recording.id] = .sending
        } catch {
            syncStates[recording.id] = .failed(error.localizedDescription)
        }
    }

    /// After launch / reconnect: queue anything that never reached the iPhone.
    private func resendPending() {
        let inFlight = link.pendingIDs
        for recording in recordings where syncStates[recording.id] != .onPhone && recording.id != current?.id {
            if inFlight.contains(recording.id) {
                syncStates[recording.id] = .sending
            } else {
                send(recording)
            }
        }
    }

    private func transferFinished(_ id: UUID, error: Error?) {
        if let error {
            syncStates[id] = .failed(error.localizedDescription)
        }
        // Success only means it left the Watch; keep the audio until the iPhone app acknowledges it.
    }

    /// The iPhone app has filed these: free the space, keep the entry so the list shows "On iPhone".
    private func acknowledged(_ ids: Set<UUID>) {
        for id in ids where syncStates[id] != .onPhone && recordings.contains(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: store.micURL(for: id))
            try? Data().write(to: Self.syncedMarker(in: store.folder(for: id)))
            syncStates[id] = .onPhone
        }
    }

    /// Try again after a failed transfer.
    func retry(_ recording: Recording) {
        guard recording.id != current?.id, case .failed = syncStates[recording.id] else { return }
        send(recording)
    }

    func delete(_ recording: Recording) {
        guard recording.id != current?.id else { return }
        try? store.delete(recording.id)
        reload()
    }

    private func reload() {
        pruneSynced()
        recordings = store.loadAll()
        for recording in recordings where syncStates[recording.id] == nil {
            let synced = FileManager.default.fileExists(atPath: Self.syncedMarker(in: store.folder(for: recording.id)).path)
            syncStates[recording.id] = synced ? .onPhone : .recordedOnly
        }
    }

    /// Recordings the iPhone has had for over a day leave the Watch entirely (the iPhone keeps the meeting).
    private func pruneSynced() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for recording in store.loadAll() where recording.id != current?.id {
            let marker = Self.syncedMarker(in: store.folder(for: recording.id))
            guard let date = try? marker.resourceValues(forKeys: [.creationDateKey]).creationDate, date < cutoff else { continue }
            try? store.delete(recording.id)
            syncStates[recording.id] = nil
        }
    }

    private static func syncedMarker(in folder: URL) -> URL { folder.appendingPathComponent(".on-iphone") }

    static func defaultTitle(at date: Date = Date()) -> String {
        "Meeting at " + date.formatted(date: .omitted, time: .shortened)
    }
}
