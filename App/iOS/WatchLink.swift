#if os(iOS)
import Foundation
import LocalScribeKit
import WatchConnectivity

/// Receives recordings from the Apple Watch and files them as normal recordings.
nonisolated final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Updated when the user moves the library; read on WatchConnectivity's queue.
    var store: RecordingStore
    /// Called on the main actor with each recording that arrived.
    var onReceive: (@MainActor (Recording) -> Void)?

    init(store: RecordingStore) {
        self.store = store
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this method returns, so move it synchronously.
        guard let data = file.metadata?["recording"] as? Data,
              let recording = try? RecordingStore.decode(Recording.self, from: data) else { return }
        do {
            try store.importRecording(recording, micFile: file.fileURL)
            acknowledge(recording.id)
            Task { @MainActor in self.onReceive?(recording) }
        } catch {
            // Not acknowledged, so the Watch keeps its copy and sends it again later.
        }
    }

    /// Tells the Watch which recordings are safely stored here, so it can free its copies.
    /// Application context always holds the latest value and is delivered even if the Watch app isn't running.
    private let ackLock = NSLock()
    private func acknowledge(_ id: UUID) {
        ackLock.lock()
        defer { ackLock.unlock() }
        var received = WCSession.default.applicationContext["received"] as? [String] ?? []
        received.removeAll { $0 == id.uuidString }
        received.append(id.uuidString)
        try? WCSession.default.updateApplicationContext(["received": Array(received.suffix(200))])
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
#endif
