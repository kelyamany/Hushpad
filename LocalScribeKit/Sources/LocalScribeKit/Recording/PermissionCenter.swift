import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The one place the app reads permission state from. It re-checks whenever the app becomes active (for
/// example after the user flips a switch in System Settings) and after every request, and `watch()` keeps
/// checking every second while a permissions screen is open, so the UI never shows stale state.
@MainActor
@Observable
public final class PermissionCenter {
    public private(set) var statuses: [Permission: PermissionStatus] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {
        #if os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        let name = UIApplication.didBecomeActiveNotification
        #endif
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    public func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    public var allRequiredGranted: Bool {
        Permission.required.allSatisfy { status($0) == .granted }
    }

    public func refresh() async {
        await Permissions.refresh()
        var fresh: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases { fresh[permission] = Permissions.status(permission) }
        // Only publish real changes, so views don't re-render every second while watching.
        if fresh != statuses { statuses = fresh }
    }

    @discardableResult
    public func request(_ permission: Permission) async -> PermissionStatus {
        _ = await Permissions.request(permission)
        await refresh()
        return status(permission)
    }

    /// Re-checks once a second until everything is granted or the calling task is cancelled
    /// (use from a view's `.task`, so it only runs while that screen is visible).
    public func watch() async {
        while !Task.isCancelled {
            await refresh()
            if Permission.allCases.allSatisfy({ status($0) == .granted }) { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
