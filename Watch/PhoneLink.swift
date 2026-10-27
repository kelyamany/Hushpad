import Foundation
import LocalScribeCore
import WatchConnectivity

/// Sends finished recordings to the iPhone with WatchConnectivity file transfers.
/// The system queues transfers and delivers them in the background, even if the iPhone app isn't running.
nonisolated final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let recordingKey = "recording"

    static let receivedKey = "received"

    /// Called on the main actor when a transfer leaves the Watch (error nil). This does NOT mean the iPhone
    /// app has filed it yet — that's `onAcknowledged`.
    var onFinished: (@MainActor (UUID, Error?) -> Void)?
    /// The iPhone app confirms the recordings it has stored (via its application context).
    var onAcknowledged: (@MainActor (Set<UUID>) -> Void)?
    var onActivated: (@MainActor () -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isReady: Bool { WCSession.default.activationState == .activated }
    var isCompanionInstalled: Bool { WCSession.default.isCompanionAppInstalled }

    /// IDs of recordings currently queued or in flight.
    var pendingIDs: Set<UUID> {
        Set(WCSession.default.outstandingFileTransfers.compactMap { Self.recordingID(in: $0.file.metadata) })
    }

    func send(_ recording: Recording, audio: URL) throws {
        let metadata: [String: Any] = [Self.recordingKey: try RecordingStore.encode(recording)]
        WCSession.default.transferFile(audio, metadata: metadata)
    }

    static func recordingID(in metadata: [String: Any]?) -> UUID? {
        guard let data = metadata?[recordingKey] as? Data,
              let recording = try? RecordingStore.decode(Recording.self, from: data) else { return nil }
        return recording.id
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        let acknowledged = Self.acknowledgedIDs(in: session.receivedApplicationContext)
        Task { @MainActor in
            self.onAcknowledged?(acknowledged)
            self.onActivated?()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let acknowledged = Self.acknowledgedIDs(in: context)
        Task { @MainActor in self.onAcknowledged?(acknowledged) }
    }

    static func acknowledgedIDs(in context: [String: Any]) -> Set<UUID> {
        Set((context[receivedKey] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = Self.recordingID(in: fileTransfer.file.metadata) else { return }
        Task { @MainActor in self.onFinished?(id, error) }
    }
}
