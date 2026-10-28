import Foundation

/// App-private data under Application Support, excluded from device backups: models, the default
/// (private) library, and recordings still in progress. A user can move the library to a folder of their
/// choice (see `LibraryLocation`); models and in-progress audio always stay here.
public enum AppDirectories {
    public static var root: URL {
        get throws {
            if let demo = DemoMode.appData { return try ensure(demo) }
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return try ensure(base.appendingPathComponent("Hushpad", isDirectory: true))
        }
    }

    public static var models: URL { get throws { try ensure(root.appendingPathComponent("Models", isDirectory: true)) } }
    public static var recordings: URL { get throws { try ensure(root.appendingPathComponent("Recordings", isDirectory: true)) } }
    /// Recordings being captured right now. Moved into the library when they finish, so a synced
    /// folder never uploads a half-written, growing audio file.
    public static var inProgress: URL { get throws { try ensure(root.appendingPathComponent("In Progress", isDirectory: true)) } }

    @discardableResult
    static func ensure(_ url: URL) throws -> URL {
        var url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            #if !os(macOS)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #else
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #endif
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
}
