#if os(macOS)
import AppKit

/// Keeps every LocalScribe window out of screen shares and screen recordings made by other apps (Zoom, Teams, Meet,
/// QuickTime): the main window, settings, sheets, alerts, menus, popovers and the nub. Nobody in a meeting sees
/// LocalScribe when you share your screen, even if you share the whole display.
///
/// Rather than marking windows one by one, it marks each window once as it appears, after every event-loop pass
/// (`didUpdateNotification`). The check is a few pointer comparisons for a handful of windows.
@MainActor
enum ScreenSharePrivacy {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        hideAll()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideAll() }
        }
    }

    private static func hideAll() {
        for window in NSApp.windows where window.sharingType != .none {
            window.sharingType = .none
        }
    }
}
#endif
