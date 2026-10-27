#if os(macOS) && DEBUG
import AppKit

/// Debug builds only: `LOCALSCRIBE_SNAPSHOT=/path/prefix` makes the app write PNGs of its windows a few seconds
/// after launch, for reviewing layouts without screen-recording permission. Not compiled into release builds.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        guard let prefix = ProcessInfo.processInfo.environment["LOCALSCRIBE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["LOCALSCRIBE_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = (window.identifier?.rawValue ?? "window").replacingOccurrences(of: "/", with: "-")
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(index)-\(name).png"))
            }
        }
    }
}
#endif
