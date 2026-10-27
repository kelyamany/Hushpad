import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

struct NotesTests {
    private var input: NotesInput {
        let recording = Recording(title: "Q4 planning: budget", createdAt: Date(timeIntervalSince1970: 1_791_590_700),
                                  duration: 1800, attendees: ["Sara"])
        let transcript = Transcript(language: .english,
                                    speakers: [Speaker(key: "R1", name: "Me"), Speaker(key: "S1", name: "Sara")],
                                    utterances: [Utterance(speaker: "S1", start: 3, end: 6, text: "We ship in November."),
                                                 Utterance(speaker: "R1", start: 7, end: 9, text: "Agreed.")],
                                    engine: "whisperkit:openai_whisper-large-v3")
        return NotesInput(recording: recording, transcript: transcript, myNotes: "- ship date?")
    }

    @Test func documentHasObsidianFrontmatterAndSections() {
        let doc = NotesGenerator.document(body: "## Summary\nShipping in November.", input: input, model: "qwen3-8b", includeTranscript: true)
        #expect(doc.hasPrefix("---\ntitle: \"Q4 planning: budget\"\ndate: 2026-10-"))
        #expect(doc.contains("participants:\n  - Sara\n  - Me\n"))
        #expect(doc.contains("tags:\n  - meeting\n"))
        #expect(doc.contains("notes_model: qwen3-8b"))
        #expect(doc.contains("\n# Q4 planning: budget\n\n## Summary\n"))
        #expect(doc.contains("## My notes\n\n- ship date?"))
        #expect(doc.contains("<summary>Transcript</summary>"))
        #expect(doc.contains("**Sara** 00:03 — We ship in November."))
        // Renders cleanly in our own viewer too: frontmatter hidden, title first.
        #expect(MarkdownBlock.parse(doc).first == .heading(level: 1, text: "Q4 planning: budget"))
    }

    @Test func promptCarriesNotesTranscriptAndTemplate() {
        let template = NoteTemplate.builtIn[0]
        let messages = NotesGenerator.messages(template: template, input: input,
                                               transcript: NotesGenerator.transcriptLines(input.transcript!), condensed: false)
        #expect(messages.first?.role == "system")
        let user = messages.last!.content
        #expect(user.contains("<my_notes>\n- ship date?\n</my_notes>"))
        #expect(user.contains("[00:03] Sara: We ship in November."))
        #expect(user.contains("## Action items"))
        #expect(user.contains("Participants: Sara, Me"))
    }

    @Test func longTranscriptsAreSplitOnLineBoundaries() {
        let text = (1...10).map { "line \($0) " + String(repeating: "x", count: 20) }.joined(separator: "\n")
        let chunks = NotesGenerator.chunks(text, limit: 70)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: "\n") == text)
        #expect(chunks.allSatisfy { $0.count <= 70 })
    }

    @Test func parsesStreamingChunks() {
        var parser = StreamParser()
        #expect(parser.consume(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#) == .delta("Hel"))
        #expect(parser.consume(": keep-alive") == nil)
        #expect(parser.consume(#"data: {"choices":[{"delta":{}}]}"#) == nil)
        #expect(parser.consume("data: [DONE]") == .done)
        #expect(parser.consume(#"data: {"choices":[{"delta":{"reasoning_content":"Thinking"}}]}"#) == .reasoning)
        #expect(parser.consume(#"data: {"error":{"message":"Compute error."}}"#) == .error("Compute error."))
    }

    @Test func budgetFitsSmallContextWindows() {
        // 8k context (LM Studio's default): ~12k characters of transcript per request.
        #expect(NotesGenerator.transcriptBudget(contextTokens: 8192) == 11_976)
        #expect(NotesGenerator.transcriptBudget(contextTokens: 2048) == 4_000)
    }

    @Test func cleansModelWrappers() {
        #expect(NotesGenerator.cleaned("<think>hmm</think>\n## Summary\nOK") == "## Summary\nOK")
        #expect(NotesGenerator.cleaned("```markdown\n## Summary\n```") == "## Summary")
    }
}

struct SuggestedTitleTests {
    @Test func recognisesAutomaticNames() {
        for name in ["Meeting at 10:16", "Meeting at 9:05 AM", "Meeting at 9:05\u{202F}PM", "Meeting at 21.30"] {
            #expect(Recording(title: name).hasDefaultTitle, "\(name)")
        }
        for name in ["Q4 planning", "Meeting at Google", "Meeting at 10:16 with Sara about pricing", "Imported from Granola"] {
            #expect(!Recording(title: name).hasDefaultTitle, "\(name)")
        }
        // The app's own default, in this machine's locale.
        #expect(Recording(title: "Meeting at " + Date().formatted(date: .omitted, time: .shortened)).hasDefaultTitle)
    }

    @Test func cleansTheModelsReply() {
        #expect(NotesGenerator.title(fromReply: "\"Q3 budget review.\"") == "Q3 budget review")
        #expect(NotesGenerator.title(fromReply: "\n## Onboarding redesign\nMore text") == "Onboarding redesign")
        #expect(NotesGenerator.title(fromReply: "Title: **Hiring plan**") == "Hiring plan")
        #expect(NotesGenerator.title(fromReply: "   ") == nil)
        #expect(NotesGenerator.title(fromReply: String(repeating: "word ", count: 30)) == nil)
    }
}
