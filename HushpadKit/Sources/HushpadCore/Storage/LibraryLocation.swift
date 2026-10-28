import Foundation

/// Where the recordings library lives: the app's private folder (default), or a folder the user picked,
/// e.g. ~/Documents/Hushpad synced by iCloud Drive — the same way Obsidian vaults work.
/// The choice is remembered as a bookmark, which keeps access across launches (security-scoped on iOS).
public enum LibraryLocation {
    private static let bookmarkKey = "Hushpad.libraryBookmark"

    /// The folder to use right now. Falls back to the private library if a chosen folder is gone.
    public static func resolve(defaults: UserDefaults = .standard) -> (url: URL, isCustom: Bool) {
        if let demo = DemoMode.library { return (demo, true) }
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale { try? remember(url, defaults: defaults) }
                return (url, true)
            }
        }
        return ((try? AppDirectories.recordings) ?? FileManager.default.temporaryDirectory, false)
    }

    /// Remembers a folder the user picked (from a folder picker / file importer). Pass nil to go back to private.
    public static func remember(_ url: URL?, defaults: UserDefaults = .standard) throws {
        guard let url else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }

    /// Moves every recording from one library to another (used when the user changes location).
    /// Recordings already present at the destination (same id) are left alone.
    public static func migrate(from source: RecordingStore, to destination: RecordingStore) throws -> Int {
        let existing = Set(destination.loadAll().map(\.id))
        var moved = 0
        for recording in source.loadAll() where !existing.contains(recording.id) {
            try destination.adopt(folder: source.folder(for: recording.id), recording: recording)
            moved += 1
        }
        return moved
    }

    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = .minimalBookmark
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
