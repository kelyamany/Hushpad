import Foundation
import Testing
@testable import HushpadCore
@testable import HushpadKit

@Suite struct DeleteAndSpeakerTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func directories(in root: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // One test only calls delete on a real recording, to keep Trash litter minimal.
    @Test func deleteRemovesFolderAndBlocksOrphanWrites() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Doomed")
        let transcript = Transcript(language: .english, speakers: [], utterances: [], engine: "whisperkit:a")
        try store.save(recording)
        try store.save(transcript, for: recording.id)
        try store.saveNotes("hello", for: recording.id, .mine)
        let folder = store.folder(for: recording.id)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(directories(in: root).count == 1)

        try store.delete(recording.id)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(directories(in: root).isEmpty)
        #expect(!store.loadAll().contains { $0.id == recording.id })
        #expect(store.existingFolder(recording.id) == nil)

        // Orphan guard: late writes from a running job must not resurrect the folder.
        #expect(throws: HushpadError.self) { try store.save(transcript, for: recording.id) }
        #expect(throws: HushpadError.self) { try store.saveNotes("late", for: recording.id, .enhanced) }
        do {
            try store.save(transcript, for: recording.id)
            Issue.record("expected recordingGone")
        } catch let error as HushpadError {
            guard case .recordingGone = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(directories(in: root).isEmpty)
    }

    @Test func deleteUnknownIDDoesNotThrow() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        try store.delete(UUID())
    }

    // MARK: Speakers

    private func transcript(_ lines: [(String, Double, Double, String)]) -> Transcript {
        Transcript(
            language: .english,
            speakers: [Speaker(key: "A", name: "Alice"), Speaker(key: "B", name: "Bob"), Speaker(key: "C", name: "Carol")],
            utterances: lines.map { Utterance(speaker: $0.0, start: $0.1, end: $0.2, text: $0.3) },
            engine: "test"
        )
    }

    @Test func mergeReassignsAndRemovesSource() {
        var t = transcript([("A", 0, 1, "one"), ("C", 1, 2, "two"), ("B", 2, 3, "three")])
        t.mergeSpeaker("B", into: "A")
        #expect(t.speakers.map(\.key) == ["A", "C"])
        #expect(t.utterances.map(\.speaker) == ["A", "C", "A"])
    }

    @Test func mergeJoinsAcrossOldBoundary() {
        var t = transcript([("A", 0, 2, "hello"), ("B", 2, 5, "there"), ("C", 5, 6, "ok")])
        t.mergeSpeaker("B", into: "A")
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0] == Utterance(speaker: "A", start: 0, end: 5, text: "hello there"))
        #expect(t.utterances[1].speaker == "C")
    }

    @Test func mergeJoinsWhenSourceComesFirst() {
        var t = transcript([("B", 0, 4, "first"), ("A", 4, 3, "second")])
        t.mergeSpeaker("B", into: "A")
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].end == 4) // max end
        #expect(t.utterances[0].text == "first second")
    }

    @Test func mergeKeepsAlreadySeparateTargetLinesApart() {
        var t = transcript([("A", 0, 1, "x"), ("A", 1, 2, "y"), ("C", 2, 3, "z")])
        t.mergeSpeaker("B", into: "A")
        #expect(t.utterances.count == 3)
        #expect(t.utterances.map(\.text) == ["x", "y", "z"])
    }

    @Test func mergeNoOps() {
        let original = transcript([("A", 0, 1, "x"), ("B", 1, 2, "y")])
        var same = original
        same.mergeSpeaker("A", into: "A")
        #expect(same == original)
        var missing = original
        missing.mergeSpeaker("B", into: "nope")
        #expect(missing == original)
    }

    @Test func speakerNamedIsCaseAndWhitespaceInsensitiveAndExcludesKey() {
        let t = transcript([])
        #expect(t.speaker(named: "  aLiCe ", except: "B")?.key == "A")
        #expect(t.speaker(named: "alice", except: "A") == nil)
        #expect(t.speaker(named: "Dave", except: "A") == nil)
    }
}
