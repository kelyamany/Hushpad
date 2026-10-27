import Foundation
import os

/// The recordings library: one folder per recording, the same layout on Mac, iPhone and Watch.
///
///     2026-10-09 1405 Meeting at 14.05/
///       recording.json          metadata, including the stable id
///       mic.wav, system.wav     16 kHz mono audio
///       transcripts/<engine>.json
///       notes/mine.md, notes/enhanced.md
///       screens/<milliseconds>.jpg
///
/// The library can live in a user-chosen folder that iCloud Drive syncs (e.g. ~/Documents/LocalScribe),
/// so every file access is coordinated with NSFileCoordinator and folders are found by id, not by name.
public struct RecordingStore: Sendable {
    public let root: URL
    private let index = FolderIndex()
    /// App-private folders get backup exclusion and file protection; a user's folder is left as they set it up.
    private let isPrivate: Bool

    /// Local, app-private area for recordings still being captured (see `AppDirectories.inProgress`).
    public static func staging() throws -> RecordingStore {
        try RecordingStore(privateRoot: AppDirectories.inProgress)
    }

    private init(privateRoot: URL) {
        root = privateRoot
        isPrivate = true
    }

    public init(root: URL? = nil) throws {
        if let root {
            self.root = root
            isPrivate = false
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            self.root = try AppDirectories.recordings
            isPrivate = true
        }
    }

    // MARK: Locations

    /// The folder of an existing recording, or where a new one with this id would go.
    public func folder(for id: UUID) -> URL {
        if let url = index.url(for: id) { return url }
        rebuildIndex()
        return index.url(for: id) ?? root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func micURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("mic.wav") }
    public func systemURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("system.wav") }

    /// The audio files to play or transcribe (plain copies when the library is encrypted).
    public func tracks(for recording: Recording) -> AudioTracks {
        AudioTracks(
            mic: recording.hasMic ? LibraryCrypto.readable(micURL(for: recording.id)) : nil,
            system: recording.hasSystemAudio ? LibraryCrypto.readable(systemURL(for: recording.id)) : nil,
            systemOffset: recording.systemOffset
        )
    }

    /// Creates the folder for a new recording, named after its date and title so the library is browsable.
    @discardableResult
    public func createFolder(for recording: Recording) throws -> URL {
        if let existing = index.url(for: recording.id) ?? existingFolder(for: recording.id) { return existing }
        var url = root.appendingPathComponent(Self.folderName(for: recording), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(Self.folderName(for: recording)) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try makeDirectory(url.appendingPathComponent("transcripts", isDirectory: true))
        index.set(url, for: recording.id)
        return url
    }

    private func existingFolder(for id: UUID) -> URL? {
        rebuildIndex()
        return index.url(for: id)
    }

    public static func folderName(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let title = sanitize(recording.title).prefix(60)
        return "\(formatter.string(from: recording.createdAt)) \(title)".trimmingCharacters(in: .whitespaces)
    }

    /// Safe on every file system and in Obsidian links: no / \ : * ? " < > | # ^ [ ].
    public static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "[/\\\\:*?\"<>|#^\\[\\]]", with: ".", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    // MARK: Recordings

    public func save(_ recording: Recording) throws {
        let folder = try createFolder(for: recording)
        try write(recording, to: folder.appendingPathComponent("recording.json"))
    }

    public func loadAll() -> [Recording] { scan().recordings }

    /// One recording by id: reads a single file instead of scanning the library.
    public func recording(id: UUID) -> Recording? {
        let known = index.url(for: id).flatMap { try? read(Recording.self, from: $0.appendingPathComponent("recording.json")) }
        if let known { return known }
        rebuildIndex()
        return index.url(for: id).flatMap { try? read(Recording.self, from: $0.appendingPathComponent("recording.json")) }
    }

    /// Every recording in the library, plus whether any could not be opened because the library key is missing.
    public func scan() -> (recordings: [Recording], locked: Bool) {
        var locked = false
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        var found: [UUID: URL] = [:]
        let recordings: [Recording] = folders.compactMap { folder in
            // Library-level files (folders.json) sit next to the recording folders.
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let recording: Recording
            do {
                recording = try read(Recording.self, from: folder.appendingPathComponent("recording.json"))
            } catch {
                if case LocalScribeError.libraryLocked = error { locked = true }
                FileCoordination.requestDownload(of: folder.appendingPathComponent("recording.json"))
                return nil
            }
            found[recording.id] = folder
            return recording
        }
        index.replace(with: found)
        return (recordings.sorted { $0.createdAt > $1.createdAt }, locked)
    }

    private func rebuildIndex() {
        _ = scan()
    }

    /// Deletes the whole recording folder (audio, transcripts, notes, screenshots, metadata) for good. Not via the
    /// system Trash: meeting audio and notes must not linger outside the library where anyone can open them.
    /// Does nothing if the recording isn't in the library.
    public func delete(_ id: UUID) throws {
        guard let url = existingFolder(id) else { return }
        try FileCoordination.delete(url)
        index.remove(id)
    }

    /// The folder of a recording that exists on disk, or nil (e.g. deleted meanwhile, maybe on another device).
    public func existingFolder(_ id: UUID) -> URL? {
        if let url = index.url(for: id), FileManager.default.fileExists(atPath: url.path) { return url }
        rebuildIndex()
        return index.url(for: id)
    }

    /// Writes into a recording must not resurrect one that was deleted while a job was running.
    private func requireFolder(_ id: UUID) throws -> URL {
        guard let url = existingFolder(id) else { throw LocalScribeError.recordingGone }
        return url
    }

    /// Takes ownership of audio recorded on another device (Apple Watch) and files it like a local recording.
    /// Idempotent: receiving the same transfer twice just replaces the audio.
    /// If the recording is already in the library (a re-sent transfer), its metadata is kept: the user may have
    /// renamed it or filed it in a folder since.
    public func importRecording(_ recording: Recording, micFile: URL) throws {
        let folder = try createFolder(for: recording)
        try FileCoordination.move(micFile, to: folder.appendingPathComponent("mic.wav"), replacing: true)
        if (try? read(Recording.self, from: folder.appendingPathComponent("recording.json"))) == nil {
            try save(recording)
        }
    }

    // MARK: Privacy

    /// Deletes a meeting's audio for good (not via the Trash) and records when; transcripts and notes stay.
    @discardableResult
    public func removeAudio(_ recording: Recording, at date: Date = Date()) throws -> Recording {
        for url in [micURL(for: recording.id), systemURL(for: recording.id)] { try FileCoordination.delete(url) }
        var updated = recording
        updated.hasMic = false
        updated.hasSystemAudio = false
        updated.audioRemovedAt = date
        try save(updated)
        return updated
    }

    /// iPhone: `complete` makes a finished meeting's files unreadable while the phone is locked; turn it off again
    /// before background work (transcription) needs them. No effect on the Mac.
    public func setStrongProtection(_ id: UUID, _ complete: Bool) {
        #if os(iOS) || os(watchOS)
        guard let folder = existingFolder(id),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        let protection: FileProtectionType = complete ? .complete : .completeUntilFirstUserAuthentication
        for case let file as URL in files {
            try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: file.path)
        }
        #endif
    }

    // MARK: Folders

    public var foldersURL: URL { root.appendingPathComponent("folders.json") }

    /// The user's folders, in their saved order.
    public func folders() -> [Folder] {
        (try? read([Folder].self, from: foldersURL)) ?? []
    }

    public func saveFolders(_ folders: [Folder]) throws {
        try write(folders, to: foldersURL)
    }

    /// Changes only `folderID`, re-reading the file first so a concurrent edit from another device isn't overwritten.
    @discardableResult
    public func move(_ id: UUID, to folderID: UUID?) throws -> Recording {
        let url = folder(for: id).appendingPathComponent("recording.json")
        var recording = try read(Recording.self, from: url)
        recording.folderID = folderID
        try write(recording, to: url)
        return recording
    }

    // MARK: Change detection

    /// Changes whenever the recording's metadata, transcripts or notes change (atomic writes replace files,
    /// which bumps the containing folder's modification date). Three stats instead of decoding every file,
    /// so the app can refresh its list cheaply.
    public func contentStamp(for id: UUID) -> Date {
        let base = folder(for: id)
        return [base, base.appendingPathComponent("transcripts"), base.appendingPathComponent("notes")]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantPast
    }

    /// Moves a whole recording folder (e.g. from the local staging area once a recording finishes) into this library.
    @discardableResult
    public func adopt(folder source: URL, recording: Recording) throws -> URL {
        if let existing = index.url(for: recording.id) ?? existingFolder(for: recording.id) {
            try FileCoordination.delete(existing)
        }
        var destination = root.appendingPathComponent(Self.folderName(for: recording), isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent("\(Self.folderName(for: recording)) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileCoordination.move(source, to: destination, replacing: false)
        index.set(destination, for: recording.id)
        return destination
    }

    /// Makes sure a (possibly cloud-only) file is downloaded before it's read, e.g. audio before transcription.
    public func ensureLocal(_ url: URL) throws {
        try FileCoordination.download(url)
    }

    // MARK: Notes (Markdown files, so they sync and export as-is)

    public enum NotesKind: String, Sendable {
        /// What you typed during the meeting.
        case mine
        /// The LLM-enhanced version.
        case enhanced
    }

    public func notesURL(for id: UUID, _ kind: NotesKind) -> URL {
        folder(for: id).appendingPathComponent("notes/\(kind.rawValue).md")
    }

    public func notes(for id: UUID, _ kind: NotesKind) -> String? {
        let url = notesURL(for: id, kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? FileCoordination.read(url).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func saveNotes(_ text: String, for id: UUID, _ kind: NotesKind) throws {
        let url = try requireFolder(id).appendingPathComponent("notes/\(kind.rawValue).md")
        try makeDirectory(url.deletingLastPathComponent())
        try FileCoordination.write(Data(text.utf8), to: url, options: writeOptions)
    }

    // MARK: Transcripts (one per engine, so models can be compared)

    public func save(_ transcript: Transcript, for id: UUID) throws {
        let folder = try requireFolder(id).appendingPathComponent("transcripts", isDirectory: true)
        try makeDirectory(folder)
        try write(transcript, to: folder.appendingPathComponent(Self.fileName(for: transcript.engine)))
    }

    public func transcripts(for id: UUID) -> [Transcript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: transcriptsFolder(id), includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? read(Transcript.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Paused transcription

    /// Progress of a transcription that was paused or interrupted, if any.
    public func partialTranscript(for id: UUID) -> PartialTranscript? {
        try? read(PartialTranscript.self, from: partialURL(id))
    }

    public func savePartial(_ partial: PartialTranscript, for id: UUID) throws {
        try makeDirectory(transcriptsFolder(id))
        try write(partial, to: partialURL(id))
    }

    public func removePartial(for id: UUID) {
        try? FileManager.default.removeItem(at: partialURL(id))
    }

    /// Hidden, so it is never listed as a transcript.
    private func partialURL(_ id: UUID) -> URL {
        transcriptsFolder(id).appendingPathComponent(".partial.json")
    }

    private func transcriptsFolder(_ id: UUID) -> URL {
        folder(for: id).appendingPathComponent("transcripts", isDirectory: true)
    }

    public static func fileName(for engine: String) -> String {
        engine.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) + ".json"
    }

    // MARK: Files

    private var writeOptions: Data.WritingOptions {
        #if os(macOS)
        .atomic
        #else
        isPrivate ? [.atomic, .completeFileProtectionUntilFirstUserAuthentication] : .atomic
        #endif
    }

    private func makeDirectory(_ url: URL) throws {
        if isPrivate {
            try AppDirectories.ensure(url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileCoordination.write(Self.encode(value), to: url, options: writeOptions)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard let data = try FileCoordination.read(url) else { throw CocoaError(.fileReadNoSuchFile) }
        return try Self.decode(type, from: data)
    }

    /// The JSON format used on disk and on the wire (watch transfers).
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// id → folder lookup, shared by copies of the store.
final class FolderIndex: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [UUID: URL]())
    func url(for id: UUID) -> URL? { lock.withLock { $0[id] } }
    func set(_ url: URL, for id: UUID) { lock.withLock { $0[id] = url } }
    func remove(_ id: UUID) { lock.withLock { _ = $0.removeValue(forKey: id) } }
    func replace(with map: [UUID: URL]) { lock.withLock { $0 = map } }
}
