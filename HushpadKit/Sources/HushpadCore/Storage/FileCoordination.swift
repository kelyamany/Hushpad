import Foundation

/// Coordinated file access, so iCloud Drive (or any other file provider) never sees half-written files
/// and cloud-only files are downloaded before they're read. Cheap no-ops for plain local folders.
///
/// In an encrypted library, reads open sealed files and writes seal them (see `LibraryCrypto`); pass
/// `sealed: false` for files that must stay readable without the key (`settings.json`).
public enum FileCoordination {
    public static func read(_ url: URL) throws -> Data? {
        var result: Result<Data?, Error> = .success(nil)
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: url, options: [], error: error) { url in
                result = Result { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
            }
        }
        return try result.get().map(LibraryCrypto.open)
    }

    public static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic, sealed: Bool = true) throws {
        let data = sealed ? try LibraryCrypto.prepareForWriting(data) : data
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: error) { url in
                result = Result { try data.write(to: url, options: options) }
            }
        }
        try result.get()
    }

    public static func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: source, options: .forMoving,
                                   writingItemAt: destination, options: .forReplacing, error: error) { from, to in
                result = Result {
                    let fm = FileManager.default
                    if replacing, fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: from, to: to)
                }
            }
        }
        try result.get()
    }

    public static func delete(_ url: URL) throws {
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: error) { url in
                result = Result {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
            }
        }
        try result.get()
    }

    /// Blocks until a cloud-only file is local (a coordinated read downloads it).
    public static func download(_ url: URL) throws {
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: url, options: [], error: error) { url in
                result = FileManager.default.fileExists(atPath: url.path) ? .success(()) : .failure(CocoaError(.fileReadNoSuchFile))
            }
        }
        try result.get()
    }

    /// Asks the system to fetch a file that isn't downloaded yet, without waiting.
    public static func requestDownload(of url: URL) {
        #if !os(watchOS)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        #endif
    }

    private static func coordinate(_ body: (NSFileCoordinator, NSErrorPointer) -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        body(coordinator, &error)
        if let error { throw error }
    }
}
