import Foundation

/// Block-level Markdown, enough to display meeting notes nicely: headings, bullets, task lists,
/// numbered lists, quotes, rules and code. YAML frontmatter and HTML wrapper tags (<details>) are hidden.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case task(indent: Int, done: Bool, text: String)
    case numbered(indent: Int, number: Int, text: String)
    case quote(String)
    case paragraph(String)
    case code(String)
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Frontmatter: metadata for Obsidian, not for reading.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph.removeAll()
        }

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            // <summary>Transcript</summary> reads as a heading; other tag-only lines are layout.
            if let summary = trimmed.firstMatch(of: /^<summary>(.*)<\/summary>$/) {
                flushParagraph()
                blocks.append(.heading(level: 3, text: String(summary.1)))
                continue
            }
            if trimmed.wholeMatch(of: /<\/?[a-zA-Z][^>]*>/) != nil { flushParagraph(); continue }

            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2

            if let m = trimmed.wholeMatch(of: /(#{1,6})\s+(.*)/) {
                flushParagraph()
                blocks.append(.heading(level: m.1.count, text: String(m.2)))
            } else if trimmed.wholeMatch(of: /(-{3,}|\*{3,}|_{3,})/) != nil {
                flushParagraph()
                blocks.append(.rule)
            } else if let m = trimmed.wholeMatch(of: /[-*+]\s+\[([ xX])\]\s+(.*)/) {
                flushParagraph()
                blocks.append(.task(indent: indent, done: m.1 != " ", text: String(m.2)))
            } else if let m = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: String(m.1)))
            } else if let m = trimmed.wholeMatch(of: /(\d+)[.)]\s+(.*)/) {
                flushParagraph()
                blocks.append(.numbered(indent: indent, number: Int(m.1) ?? 1, text: String(m.2)))
            } else if let m = trimmed.wholeMatch(of: />\s?(.*)/) {
                flushParagraph()
                blocks.append(.quote(String(m.1)))
            } else {
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        return blocks
    }
}
