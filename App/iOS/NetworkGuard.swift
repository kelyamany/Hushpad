#if os(iOS)
import Network
import os

/// Knows whether the phone is on a metered connection (cellular or Personal Hotspot), so a big download can ask first.
nonisolated final class NetworkGuard: Sendable {
    static let shared = NetworkGuard()

    private let monitor = NWPathMonitor()
    private let expensive = OSAllocatedUnfairLock(initialState: false)

    private init() {
        let expensive = expensive
        monitor.pathUpdateHandler = { path in expensive.withLock { $0 = path.isExpensive } }
        monitor.start(queue: DispatchQueue(label: "LocalScribe.NetworkGuard"))
    }

    var isExpensive: Bool { expensive.withLock { $0 } }
}
#endif
