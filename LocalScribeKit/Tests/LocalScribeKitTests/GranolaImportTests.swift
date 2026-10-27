import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

struct CSVTests {
    @Test func handlesQuotesNewlinesAndBOM() {
        let text = "\u{FEFF}a,b,c\r\n1,\"two, \"\"quoted\"\"\nlines\",3\n4,,6\n"
        #expect(CSV.parse(text) == [["a", "b", "c"], ["1", "two, \"quoted\"\nlines", "3"], ["4", "", "6"]])
    }
}

struct GranolaImportTests {
    /// Same columns and shapes as a real Granola export (content made up).
    static let sample = """
    document_id,user_email,document_title,workspace_name,document_created,summary,notes,transcript
    fbe742f2-5f36-47cb-9989-d8c6769639fd,me@example.com,Budget review,My workspace,2026-10-09T09:31:08.492Z,"# Budget

    - Q4 is on track",\"
    Check travel line\",\"Speaker A: Morning all.
    Speaker B: Hi. Shall we start?
    Speaker A: Yes. Travel is over.
    Speaker C: By how much?
    Speaker A: Ten percent.
    Speaker C: Okay.
    Speaker B: Noted.\"
    0a7c0f5e-1111-4a3b-9c1d-2b3c4d5e6f70,me@example.com,German lesson,My workspace,2026-10-08T11:02:41.037Z,### Vocabulary,,\"Zuerst Sarah.
    Wie geht's Ihnen?
    Von 8 bis 15: geöffnet.
    Gut, danke.\"
    """

    @Test func parsesMeetingsAndSpeakers() throws {
        let meetings = try GranolaImporter.meetings(fromCSV: Self.sample)
        #expect(meetings.count == 2)

        let budget = meetings[0]
        #expect(budget.id == UUID(uuidString: "fbe742f2-5f36-47cb-9989-d8c6769639fd"))
        #expect(budget.title == "Budget review")
        #expect(budget.notes.contains("Check travel line"))
        let transcript = try #require(budget.transcript)
        #expect(transcript.speakers.map(\.name) == ["Speaker A", "Speaker B", "Speaker C"])
        #expect(transcript.utterances.first?.text == "Morning all.")
        #expect(transcript.isTimed == false)

        // Unlabelled transcript: "Von 8 bis 15:" appears once, so it's text, not a speaker.
        let lesson = try #require(meetings[1].transcript)
        #expect(lesson.speakers.map(\.name) == ["Transcript"])
        #expect(lesson.utterances.count == 1)
        #expect(lesson.utterances[0].text.contains("Von 8 bis 15: geöffnet."))
    }

    @Test func importIsIdempotentAndWritesNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let meetings = try GranolaImporter.meetings(fromCSV: Self.sample)

        #expect(try GranolaImporter.importMeetings(meetings, into: store) == 2)
        #expect(try GranolaImporter.importMeetings(meetings, into: store) == 0)

        let recording = try #require(store.loadAll().first { $0.title == "Budget review" })
        #expect(recording.source == .granola)
        #expect(!recording.hasAudio)
        #expect(store.notes(for: recording.id, .mine)?.contains("Check travel line") == true)
        let enhanced = try #require(store.notes(for: recording.id, .enhanced))
        #expect(enhanced.contains("source: localscribe-granola"))
        #expect(enhanced.contains("- Q4 is on track"))
        #expect(store.transcripts(for: recording.id).first?.engine == "import:granola")
        // Untimed transcripts export without fake timestamps.
        let text = Exporter.render(store.transcripts(for: recording.id)[0], title: recording.title, as: .text)
        #expect(text.hasPrefix("Speaker A: Morning all."))
    }

    /// Runs against the real export when it's present in Fixtures/ (it's personal data and not committed).
    @Test func realExportIfPresent() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/granola-export-2026-10-09.zip")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }
        let meetings = try GranolaImporter.meetings(from: fixture)
        #expect(meetings.count == 4)
        #expect(meetings.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && $0.transcript != nil })
        #expect(meetings.filter { ($0.transcript?.speakers.count ?? 0) > 1 }.count == 2)
    }
}
