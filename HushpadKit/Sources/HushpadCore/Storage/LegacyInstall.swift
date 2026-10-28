import Foundation

/// Hushpad 1.0 still used the project's first name, LocalScribe, for the things users never see: the bundle id, the
/// keychain entries, the Application Support folder and meeting links. These are those old names, and the one-time
/// move to the new ones, so an existing install keeps its meetings, settings, models and keys.
public enum LegacyInstall {
    public static let bundleID = "dev.localscribe.app"
    public static let keychainService = "LocalScribe"
    /// Meeting links in notes written before the rename look like `localscribe://meeting/<id>`.
    public static let linkScheme = "localscribe"
    static let folderName = "LocalScribe"
    static let doneKey = "Hushpad.movedFromLocalScribe"

    /// Mac only. Call at launch, before anything reads settings or app data: copies the old settings and moves the old
    /// Application Support folder (models and the private library) to the new name. Never overwrites anything newer.
    /// The iPhone can't do this, since each bundle id has its own sandbox: meetings move through a synced library folder.
    public static func migrate() throws {
        #if os(macOS)
        // Only the real app: demo and test builds must never touch the real data.
        guard Bundle.main.bundleIdentifier == "dev.hushpad.app" else { return }
        moveSettings(from: bundleID, into: .standard, named: "dev.hushpad.app")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try moveFolder(support.appendingPathComponent(folderName, isDirectory: true),
                       to: support.appendingPathComponent("Hushpad", isDirectory: true))
        // Plain copies of encrypted files the old app opened (see `LibraryCrypto`): only a cache, never needed again.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribe-open"))
        #endif
    }

    /// Copies every setting the new domain doesn't have yet, once. "Already asked for permission" flags stay behind:
    /// macOS treats the renamed app as new and asks again.
    static func moveSettings(from oldDomain: String, into defaults: UserDefaults, named newDomain: String) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let current = defaults.persistentDomain(forName: newDomain) ?? [:]
        for (key, value) in defaults.persistentDomain(forName: oldDomain) ?? [:] where !key.hasPrefix("LocalScribe.asked") {
            let newKey = key.hasPrefix("LocalScribe.") ? "Hushpad." + key.dropFirst("LocalScribe.".count) : key
            if current[newKey] == nil { defaults.set(value, forKey: newKey) }
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Renames the old folder, unless the new one already exists (then both are left alone).
    static func moveFolder(_ old: URL, to new: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) else { return }
        try files.moveItem(at: old, to: new)
    }
}
