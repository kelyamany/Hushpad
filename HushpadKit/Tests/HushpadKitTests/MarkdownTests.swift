import Testing
@testable import HushpadCore

struct MarkdownTests {
    @Test func parsesNotesStructure() {
        let markdown = """
        ---
        title: Weekly sync
        tags: [meeting]
        ---
        # Weekly sync
        Intro line one
        continues here.

        ## Action items
        - [ ] Send proposal — **Sara**
        - [x] Book room
        - Point
          - Sub point
        1. First
        > Quote
        <details>
        <summary>Transcript</summary>
        </details>
        ---
        """
        #expect(MarkdownBlock.parse(markdown) == [
            .heading(level: 1, text: "Weekly sync"),
            .paragraph("Intro line one continues here."),
            .heading(level: 2, text: "Action items"),
            .task(indent: 0, done: false, text: "Send proposal — **Sara**"),
            .task(indent: 0, done: true, text: "Book room"),
            .bullet(indent: 0, text: "Point"),
            .bullet(indent: 1, text: "Sub point"),
            .numbered(indent: 0, number: 1, text: "First"),
            .quote("Quote"),
            .heading(level: 3, text: "Transcript"),
            .rule,
        ])
    }
}
