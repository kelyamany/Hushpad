import LocalScribeCore
import SwiftUI

/// Renders meeting notes Markdown with comfortable reading typography (serif headings, sans body).
/// Parsing is cached per input string, so re-renders (and the unchanged part of a streaming document) are free.
public struct MarkdownView: View {
    private let blocks: [Rendered]
    private let secondary: Bool
    /// Blocks written by you; when set, everything else (the AI's additions) is grey.
    private let authored: Set<Int>?

    /// `secondary` renders in a quieter colour (AI text grey, your own words in full colour).
    /// `hidesTitle` drops a leading "# Title" heading when the page already shows the title above.
    /// `myNotes`: show which lines are yours (full ink) and which the AI added (grey).
    public init(_ markdown: String, secondary: Bool = false, hidesTitle: Bool = false, myNotes: String? = nil) {
        let all = Self.rendered(markdown)
        if hidesTitle, case .heading(1)? = all.first?.kind { blocks = Array(all.dropFirst()) } else { blocks = all }
        self.secondary = secondary
        if let myNotes, !myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authored = NoteAttribution.authored(MarkdownBlock.parse(markdown), myNotes: myNotes)
        } else {
            authored = nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(blocks) { block in
                view(for: block).foregroundStyle(tone(of: block))
            }
        }
        .foregroundStyle(secondary ? Theme.inkSecondary : Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if !os(watchOS)
        .textSelection(.enabled)
        #endif
    }

    private func tone(of block: Rendered) -> Color {
        guard let authored else { return secondary ? Theme.inkSecondary : Theme.ink }
        if case .heading = block.kind { return Theme.ink }
        return authored.contains(block.id) ? Theme.ink : Theme.inkSecondary
    }

    @ViewBuilder private func view(for block: Rendered) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? .heading : level == 2 ? .editor.weight(.semibold) : .base.weight(.semibold))
                .padding(.top, level <= 2 ? Space.s : Space.xs)
        case .bullet(let indent):
            row(indent: indent) {
                Circle().fill(Theme.inkTertiary).frame(width: 5, height: 5).offset(y: -3)
            } text: { Text(block.text) }
        case .task(let indent, let done):
            row(indent: indent) {
                Image(systemName: done ? "checkmark.square" : "square")
                    .foregroundStyle(Theme.inkTertiary)
                    .imageScale(.small)
            } text: {
                Text(block.text).strikethrough(done, color: Theme.inkTertiary)
            }
        case .numbered(let indent, let number):
            row(indent: indent) {
                Text("\(number).").monospacedDigit().foregroundStyle(Theme.inkSecondary)
            } text: { Text(block.text) }
        case .quote:
            HStack(spacing: Space.m) {
                Capsule().fill(Theme.accent.opacity(0.45)).frame(width: 3)
                Text(block.text).italic().foregroundStyle(Theme.inkSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            Text(block.text).lineSpacing(3)
        case .code:
            Text(block.text)
                .font(.small.monospaced())
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.paperSunken, in: Radius.shape(Radius.s))
        case .rule:
            Divider().padding(.vertical, Space.xs)
        }
    }

    private func row<Marker: View, Content: View>(indent: Int, @ViewBuilder marker: () -> Marker,
                                                  @ViewBuilder text: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s + 1) {
            marker().frame(minWidth: 14)
            text().lineSpacing(3)
        }
        .padding(.leading, CGFloat(indent) * 18)
    }

    // MARK: Parsing (cached)

    struct Rendered: Identifiable {
        enum Kind { case heading(Int), bullet(Int), task(Int, Bool), numbered(Int, Int), quote, paragraph, code, rule }
        var id: Int
        var kind: Kind
        var text: AttributedString
    }

    private final class Box { let blocks: [Rendered]; init(_ blocks: [Rendered]) { self.blocks = blocks } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    static func rendered(_ markdown: String) -> [Rendered] {
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlock.parse(markdown).enumerated().map { index, block -> Rendered in
            switch block {
            case .heading(let level, let text): Rendered(id: index, kind: .heading(level), text: inline(text))
            case .bullet(let indent, let text): Rendered(id: index, kind: .bullet(indent), text: inline(text))
            case .task(let indent, let done, let text): Rendered(id: index, kind: .task(indent, done), text: inline(text))
            case .numbered(let indent, let number, let text): Rendered(id: index, kind: .numbered(indent, number), text: inline(text))
            case .quote(let text): Rendered(id: index, kind: .quote, text: inline(text))
            case .paragraph(let text): Rendered(id: index, kind: .paragraph, text: inline(text))
            case .code(let text): Rendered(id: index, kind: .code, text: AttributedString(text))
            case .rule: Rendered(id: index, kind: .rule, text: AttributedString())
            }
        }
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
