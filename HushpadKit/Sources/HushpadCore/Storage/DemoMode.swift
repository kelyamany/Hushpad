import Foundation

/// Debug builds only: `HUSHPAD_DEMO_LIBRARY=<folder>` runs the app on invented meetings (see `hushpad demo-library`),
/// kept fully apart from the real app. The library is that folder, app data (models, recordings in progress) lives in
/// a sibling folder, and keychain entries and the plain-copy cache use their own names. Settings are kept apart by the bundle id, so a demo
/// build must have one ending in `.demo`; anything else stops at launch rather than touch the real app's settings.
public enum DemoMode {
    public static let library: URL? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["HUSHPAD_DEMO_LIBRARY"] else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        precondition(bundleID.hasSuffix(".demo") || Bundle.main.bundlePath.hasSuffix(".xctest") || bundleID.isEmpty,
                     "Demo mode needs a demo build (PRODUCT_BUNDLE_IDENTIFIER=….demo) so it can't change the real app's settings.")
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }()

    /// App data for the demo, next to the demo library.
    static var appData: URL? {
        library.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + " (app data)", isDirectory: true) }
    }
}
