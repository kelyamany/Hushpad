import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

@Suite struct RecordingStoreTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func keepsOneTranscriptPerEngine() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Test", hasSystemAudio: true)
        try store.save(recording)

        for engine in ["whisperkit:a", "whisperkit:b", "whisperkit:a"] {
            try store.save(Transcript(language: .english, speakers: [], utterances: [], engine: engine), for: recording.id)
        }
        #expect(store.loadAll().map(\.id) == [recording.id])
        #expect(Set(store.transcripts(for: recording.id).map(\.engine)) == ["whisperkit:a", "whisperkit:b"])
        #expect(store.tracks(for: recording).system?.lastPathComponent == "system.wav")
    }

    @Test func privateStagingIsExcludedFromBackup() throws {
        let staging = try RecordingStore.staging()
        let recording = Recording(title: "Backup test")
        let folder = try staging.createFolder(for: recording)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try folder.appendingPathComponent("transcripts").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func foldersAreReadableAndFoundByIDAfterRename() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var recording = Recording(title: "Weekly sync: Q4/plans?", createdAt: Date(timeIntervalSince1970: 1_791_590_700))
        try store.save(recording)

        let name = store.folder(for: recording.id).lastPathComponent
        #expect(name.hasSuffix("Weekly sync. Q4.plans"))
        #expect(name.range(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, options: .regularExpression) != nil)

        // Renaming keeps the folder; a fresh store (another device) finds it by id.
        recording.title = "Renamed"
        try store.save(recording)
        let other = try RecordingStore(root: root)
        #expect(other.folder(for: recording.id).lastPathComponent == name)
        #expect(other.loadAll().first?.title == "Renamed")
    }

    @Test func adoptsStagedFolderWithItsFiles() throws {
        let staging = try RecordingStore(root: tempRoot())
        let library = try RecordingStore(root: tempRoot())
        defer {
            try? FileManager.default.removeItem(at: staging.root)
            try? FileManager.default.removeItem(at: library.root)
        }
        let recording = Recording(title: "Staged")
        try staging.save(recording)
        try Data([1, 2, 3]).write(to: staging.micURL(for: recording.id))
        try staging.saveNotes("- note", for: recording.id, .mine)

        try library.adopt(folder: staging.folder(for: recording.id), recording: recording)

        #expect(staging.loadAll().isEmpty)
        #expect(library.loadAll().map(\.id) == [recording.id])
        #expect(FileManager.default.fileExists(atPath: library.micURL(for: recording.id).path))
        #expect(library.notes(for: recording.id, .mine) == "- note")
    }

    @Test func legacyUUIDFoldersStillLoad() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let legacy = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        // A v1 file: no source/attendees keys.
        let json = #"{"id":"\#(id.uuidString)","title":"Old","createdAt":"2026-10-01T10:00:00Z","duration":5,"hasMic":true,"hasSystemAudio":false,"systemOffset":0,"language":"en"}"#
        try Data(json.utf8).write(to: legacy.appendingPathComponent("recording.json"))

        let store = try RecordingStore(root: root)
        let loaded = try #require(store.loadAll().first)
        #expect(loaded.title == "Old")
        #expect(loaded.source == .mac)
        #expect(store.folder(for: id).resolvingSymlinksInPath().path == legacy.resolvingSymlinksInPath().path)
    }
}
