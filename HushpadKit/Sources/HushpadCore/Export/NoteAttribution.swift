import Foundation

/// Which lines of the enhanced notes are yours: a line counts as yours when most of the words of one
/// of your own note lines appear in it. The UI shows yours in full ink and the AI's additions in grey.
public enum NoteAttribution {
    /// Indexes (as in `MarkdownBlock.parse`) of the blocks that carry one of your lines. Headings are never counted.
    public static func authored(_ blocks: [MarkdownBlock], myNotes: String, threshold: Double = 0.6) -> Set<Int> {
        let mine = myNotes.split(whereSeparator: \.isNewline).map { words(String($0)) }.filter { !$0.isEmpty }
        guard !mine.isEmpty else { return [] }
        var result = Set<Int>()
        for (index, block) in blocks.enumerated() {
            guard let text = text(of: block) else { continue }
            let found = Set(words(text))
            for line in mine {
                let needed = Set(line)
                // One- or two-word notes must match completely; longer ones mostly.
                let share = Double(needed.intersection(found).count) / Double(needed.count)
                if needed.count <= 2 ? share == 1 : share >= threshold {
                    result.insert(index)
                    break
                }
            }
        }
        return result
    }

    static func text(of block: MarkdownBlock) -> String? {
        switch block {
        case .bullet(_, let text), .task(_, _, let text), .numbered(_, _, let text), .quote(let text), .paragraph(let text): text
        case .heading, .code, .rule: nil
        }
    }

    /// Lower-cased words of two or more letters or digits, without Markdown markup.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }
}
