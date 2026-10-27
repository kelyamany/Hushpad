import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

struct MergeTests {
    @Test func transcriptsShiftAndShareSpeakersByName() throws {
        let a = Transcript(language: .english, speakers: [Speaker(key: "R1", name: "Me"), Speaker(key: "S1", name: "Sara")],
                           utterances: [Utterance(speaker: "R1", start: 1, end: 2, text: "Hi"),
                                        Utterance(speaker: "S1", start: 3, end: 4, text: "Hello")],
                           engine: "whisperkit:a")
        let b = Transcript(language: .english, speakers: [Speaker(key: "R1", name: "me"), Speaker(key: "S1", name: "Omar")],
                           utterances: [Utterance(speaker: "S1", start: 0.5, end: 1, text: "Part two"),
                                        Utterance(speaker: "R1", start: 2, end: 3, text: "Me again")],
                           engine: "whisperkit:a")
        let merged = try #require(RecordingMerger.mergeTranscripts(a, b, offset: 60))
        #expect(merged.speakers.map(\.name) == ["Me", "Sara", "Omar"])
        #expect(merged.speakers.map(\.key) == ["R1", "S1", "S1·2"])
        #expect(merged.utterances.map(\.speaker) == ["R1", "S1", "S1·2", "R1"])
        #expect(merged.utterances[2].start == 60.5)
        #expect(merged.engine == "whisperkit:a")
    }

    @Test func genericLabelsAreNotTreatedAsTheSamePerson() throws {
        let a = Transcript(language: .german, speakers: [Speaker(key: "Speaker A", name: "Speaker A")],
                           utterances: [Utterance(speaker: "Speaker A", start: 0, end: 1, text: "Eins")], engine: "import:granola", isTimed: false)
        let b = a
        let merged = try #require(RecordingMerger.mergeTranscripts(a, b, offset: 0))
        #expect(merged.speakers.map(\.name) == ["Speaker A", "Speaker A (part 2)"])
        #expect(merged.utterances.map(\.speaker) == ["Speaker A", "Speaker A·2"])
        #expect(merged.utterances[1].start > merged.utterances[0].start)
    }

    @Test func notesAreCombinedPerPart() {
        let combined = RecordingMerger.combine(notes: ["## Summary\nA", "## Summary\nB"], titles: ["One", "Two"], demote: true)
        #expect(combined == "## One\n\n### Summary\nA\n\n## Two\n\n### Summary\nB")
        #expect(RecordingMerger.combine(notes: [nil, "only"], titles: ["One", "Two"]) == "only")
        #expect(RecordingMerger.combine(notes: [nil, "  "], titles: ["One", "Two"]) == nil)
        let doc = "---\ntitle: X\n---\n\n# X\n\n## Summary\nA\n\n<details>\n<summary>Transcript</summary>\n</details>\n"
        #expect(RecordingMerger.stripDocumentHeader(doc) == "## Summary\nA")
    }

    @Test func mergesAudioNotesAndScreenshotsOnOneTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)

        // Part one: 2 s room + 2 s call. Part two: 1 s room only.
        var one = Recording(title: "One", duration: 2, hasMic: true, hasSystemAudio: true)
        var two = Recording(title: "Two", createdAt: Date().addingTimeInterval(600), duration: 1, hasMic: true)
        try store.save(one); try store.save(two)
        try writeTone(store.micURL(for: one.id), seconds: 2)
        try writeTone(store.systemURL(for: one.id), seconds: 2)
        try writeTone(store.micURL(for: two.id), seconds: 1)
        one.activeEngine = "e"; two.activeEngine = "e"
        try store.save(one); try store.save(two)
        try store.save(Transcript(language: .english, speakers: [Speaker(key: "R1", name: "Me")],
                                  utterances: [Utterance(speaker: "R1", start: 0.2, end: 1, text: "First")], engine: "e"), for: one.id)
        try store.save(Transcript(language: .english, speakers: [Speaker(key: "R1", name: "Me")],
                                  utterances: [Utterance(speaker: "R1", start: 0.1, end: 0.8, text: "Second")], engine: "e"), for: two.id)
        try store.saveNotes("- note one", for: one.id, .mine)
        try store.saveNotes("- note two", for: two.id, .mine)
        try ScreenshotStore.save(jpeg: Data([0xFF, 0xD8]), at: 0.5, in: store.folder(for: two.id))

        let merged = try RecordingMerger.merge(.init(first: one, second: two), in: store)

        #expect(merged.title == "One + Two")
        #expect(abs(merged.duration - 3) < 0.01)
        #expect(abs(AudioInfo.duration(of: store.micURL(for: merged.id)) - 3) < 0.01)
        // Call audio padded with silence for part two, so both tracks stay the same length.
        #expect(abs(AudioInfo.duration(of: store.systemURL(for: merged.id)) - 3) < 0.01)
        let transcript = try #require(store.transcripts(for: merged.id).first)
        #expect(transcript.utterances.map(\.text) == ["First", "Second"])
        #expect(abs(transcript.utterances[1].start - 2.1) < 0.001)
        #expect(store.notes(for: merged.id, .mine) == "### One\n\n- note one\n\n### Two\n\n- note two")
        #expect(ScreenshotStore.list(in: store.folder(for: merged.id)).map(\.time) == [2.5])
        // Originals untouched.
        #expect(store.loadAll().count == 3)
    }

    private func writeTone(_ url: URL, seconds: Double) throws {
        let file = try WAVFile(url: url, sampleRate: 16_000)
        try file.append((0..<Int(seconds * 16_000)).map { Int16(sin(Double($0) * 0.05) * 8000) })
        try file.close()
    }
}
