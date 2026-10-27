#if DEBUG
import Foundation
import os

/// Debug-only timing for the performance budget (DESIGN.md › Performance). Logs to the "perf" category:
///   log stream --predicate 'subsystem == "dev.localscribe.app" && category == "perf"'
enum PerfProbe {
    private static let logger = Logger(subsystem: "dev.localscribe.app", category: "perf")

    static func log(_ label: String, since start: Date) {
        let ms = Date().timeIntervalSince(start) * 1000
        logger.debug("\(label, privacy: .public): \(ms, format: .fixed(precision: 1)) ms")
    }
}
#endif
