import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

@Suite struct FolderTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func folderDecodesLeniently() throws {
        let id = UUID()
        let folder = try RecordingStore.decode(Folder.self, from: Data(#"{"id":"\#(id.uuidString)"}"#.utf8))
        #expect(folder.id == id)
        #expect(folder.name == "Folder")
        #expect(folder.symbol == "folder")
        #expect(folder.colorIndex == 0)
    }

    @Test func foldersRoundTripInOrder() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        #expect(store.folders().isEmpty)
        let list = [Folder(name: "B", symbol: "star", colorIndex: 3, createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                    Folder(name: "A", createdAt: Date(timeIntervalSince1970: 1_700_000_100))]
        try store.saveFolders(list)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("folders.json").path))
        #expect(try RecordingStore(root: root).folders() == list)
    }

    @Test func recordingDecodesWithoutNewFields() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","title":"Old"}"#
        let recording = try RecordingStore.decode(Recording.self, from: Data(json.utf8))
        #expect(recording.title == "Old")
        #expect(recording.folderID == nil)
        #expect(recording.roomSpeakers == nil)
        #expect(recording.remoteSpeakers == nil)
    }

    @Test func folderAndSpeakerHintsRoundTrip() throws {
        var recording = Recording(title: "R", folderID: UUID())
        recording.roomSpeakers = 3
        recording.remoteSpeakers = 2
        let decoded = try RecordingStore.decode(Recording.self, from: RecordingStore.encode(recording))
        #expect(decoded.folderID == recording.folderID)
        #expect(decoded.roomSpeakers == 3)
        #expect(decoded.remoteSpeakers == 2)
    }

    @Test func moveChangesOnlyFolderIDAndPersists() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Keep me", createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 42, attendees: ["Sara"])
        try store.save(recording)
        let target = UUID()

        let moved = try store.move(recording.id, to: target)
        var expected = recording
        expected.folderID = target
        #expect(moved == expected)
        #expect(try RecordingStore(root: root).loadAll().first == expected)

        let unfiled = try store.move(recording.id, to: nil)
        #expect(unfiled == recording)
        #expect(store.loadAll().first?.folderID == nil)
    }

    @Test func loadAllIgnoresFoldersFile() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Only one")
        try store.save(recording)
        try store.saveFolders([Folder(name: "X")])
        #expect(store.loadAll().map(\.id) == [recording.id])
        #expect(store.folders().count == 1)
    }

    @Test func importKeepsExistingMetadata() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        var existing = Recording(title: "Renamed", source: .watch)
        existing.folderID = UUID()
        try store.save(existing)

        let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: incoming)
        try store.importRecording(Recording(id: existing.id, title: "Watch recording", source: .watch), micFile: incoming)

        let loaded = try #require(store.loadAll().first)
        #expect(loaded.title == "Renamed")
        #expect(loaded.folderID == existing.folderID)
        #expect(try Data(contentsOf: store.micURL(for: existing.id)) == Data([1, 2, 3]))
    }

    @Test func contentStampChangesAfterNotesAndTranscript() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Stamp")
        try store.save(recording)
        let base = store.folder(for: recording.id)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        func age() throws {
            for dir in [base, base.appendingPathComponent("transcripts"), base.appendingPathComponent("notes")]
            where FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
            }
        }

        try age()
        let before = store.contentStamp(for: recording.id)
        #expect(before == old)
        try store.saveNotes("hello", for: recording.id, .mine)
        let afterNotes = store.contentStamp(for: recording.id)
        #expect(afterNotes > before)

        try age()
        try store.save(Transcript(language: .english, speakers: [], utterances: [], engine: "e"), for: recording.id)
        #expect(store.contentStamp(for: recording.id) > old)
    }

    @Test func mergedRecordingInheritsFolderID() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let folder = UUID()
        let a = Recording(title: "A", hasMic: false, source: .granola)
        let b = Recording(title: "B", createdAt: Date().addingTimeInterval(600), hasMic: false, source: .granola, folderID: folder)
        try store.save(a); try store.save(b)
        let merged = try RecordingMerger.merge(.init(first: a, second: b), in: store)
        #expect(merged.folderID == folder)
    }
}
