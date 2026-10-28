import AVFoundation
import Foundation

/// Exports meetings as ordinary files anyone can open: one folder per meeting with the transcript (Markdown and
/// subtitles), the notes, the audio, the screenshots, and the raw data (`recording.json`, `transcripts/`).
///
///     2026-10-09 1405 Weekly sync/
///       Transcript.md, Transcript.srt, Notes.md, My Notes.md
///       Room audio.m4a, Call audio.m4a
///       screens/<milliseconds>.jpg
///       data/recording.json, data/transcripts/<engine>.json
public struct MeetingExporter: Sendable {
    public enum Audio: Sendable {
        /// AAC, about a tenth of the size of the original WAV.
        case compressed
        /// The original 16 kHz WAV files.
        case original
        case none
    }

    public let store: RecordingStore
    public var audio: Audio

    public init(store: RecordingStore, audio: Audio = .compressed) {
        self.store = store
        self.audio = audio
    }

    /// Writes one meeting into a new folder inside `directory` and returns that folder.
    @discardableResult
    public func export(_ recording: Recording, into directory: URL) async throws -> URL {
        let fm = FileManager.default
        let source = store.folder(for: recording.id)
        let destination = Self.unique(directory.appendingPathComponent(RecordingStore.folderName(for: recording), isDirectory: true))
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Screenshots first: the Markdown links to screens/.
        let screenshots = ScreenshotStore.list(in: source)
        if !screenshots.isEmpty {
            let screens = destination.appendingPathComponent("screens", isDirectory: true)
            try fm.createDirectory(at: screens, withIntermediateDirectories: true)
            for shot in screenshots {
                try store.ensureLocal(shot.url)
                try fm.copyItem(at: shot.url, to: screens.appendingPathComponent(shot.url.lastPathComponent))
            }
        }

        let transcripts = store.transcripts(for: recording.id)
        if let transcript = transcripts.first(where: { $0.engine == recording.activeEngine }) ?? transcripts.last {
            try write(Exporter.render(transcript, title: recording.title, as: .markdown, screenshots: screenshots),
                      to: destination.appendingPathComponent("Transcript.md"))
            if transcript.isTimed {
                try write(Exporter.render(transcript, title: recording.title, as: .subtitles),
                          to: destination.appendingPathComponent("Transcript.srt"))
            }
        }
        if let notes = store.notes(for: recording.id, .enhanced) {
            try write(notes, to: destination.appendingPathComponent("Notes.md"))
        }
        if let mine = store.notes(for: recording.id, .mine), !mine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try write(mine, to: destination.appendingPathComponent("My Notes.md"))
        }

        if audio != .none {
            let tracks = store.tracks(for: recording)
            for (url, name) in [(tracks.mic, "Room audio"), (tracks.system, "Call audio")] {
                guard let url, fm.fileExists(atPath: url.path) || isCloudOnly(url) else { continue }
                try store.ensureLocal(url)
                try await exportAudio(url, to: destination.appendingPathComponent(name))
            }
        }

        // The raw data, so nothing is lost (another app or a future Hushpad can read it back).
        let data = destination.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: data.appendingPathComponent("transcripts", isDirectory: true), withIntermediateDirectories: true)
        if let json = try FileCoordination.read(source.appendingPathComponent("recording.json")) {
            try json.write(to: data.appendingPathComponent("recording.json"))
        }
        for transcript in transcripts {
            try RecordingStore.encode(transcript)
                .write(to: data.appendingPathComponent("transcripts/\(RecordingStore.fileName(for: transcript.engine))"))
        }
        return destination
    }

    /// Exports every meeting into "Hushpad Export <date>/" inside `directory`, one subfolder per Hushpad
    /// folder (meetings without a folder sit at the top). Returns the export folder.
    @discardableResult
    public func exportLibrary(_ recordings: [Recording], folders: [Folder], into directory: URL,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let date = Date().formatted(.iso8601.year().month().day())
        let root = Self.unique(directory.appendingPathComponent("Hushpad Export \(date)", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = Dictionary(folders.map { ($0.id, RecordingStore.sanitize($0.name)) }, uniquingKeysWith: { first, _ in first })
        for (index, recording) in recordings.enumerated() {
            try Task.checkCancellation()
            var parent = root
            if let id = recording.folderID, let name = names[id], !name.isEmpty {
                parent = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try await export(recording, into: parent)
            progress(Double(index + 1) / Double(max(recordings.count, 1)))
        }
        if !folders.isEmpty {
            try RecordingStore.encode(folders).write(to: root.appendingPathComponent("folders.json"))
        }
        return root
    }

    /// Zips a folder (for the share sheet on iPhone). The zip is placed in the temporary directory.
    public static func zip(_ folder: URL) throws -> URL {
        var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordinationError: NSError?
        // A coordinated read "for uploading" makes the system produce a zip of a directory.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent).appendingPathExtension("zip")
            result = Result {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // MARK: Helpers

    private func exportAudio(_ source: URL, to base: URL) async throws {
        switch audio {
        case .none:
            return
        case .original:
            try FileManager.default.copyItem(at: source, to: base.appendingPathExtension("wav"))
        case .compressed:
            let destination = base.appendingPathExtension("m4a")
            let asset = AVURLAsset(url: source)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                try FileManager.default.copyItem(at: source, to: base.appendingPathExtension("wav"))
                return
            }
            do {
                try await session.export(to: destination, as: .m4a)
            } catch {
                // Never lose the audio over a conversion problem: fall back to the original.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: base.appendingPathExtension("wav"))
            }
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func isCloudOnly(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    private static func unique(_ url: URL) -> URL {
        var candidate = url
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
