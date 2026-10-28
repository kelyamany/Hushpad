import Foundation
import Testing

/// Keeps Settings easy to scan (DESIGN.md › Settings): short captions, a small total, details behind ⓘ.
@Suite struct SettingsCopyTests {
    /// `HushpadKit/Tests/HushpadKitTests/<file>` → four levels up is the repo root.
    private static let copyFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Shared/Settings/SettingsCopy.swift")

    /// `static let name = "text"` pairs from SettingsCopy.swift.
    private static func entries() throws -> [(name: String, words: Int)] {
        let text = try String(contentsOf: copyFile, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"static let (\w+) = "((?:[^"\\]|\\.)*)""#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let name = String(text[Range(match.range(at: 1), in: text)!])
            let value = String(text[Range(match.range(at: 2), in: text)!])
            return (name, value.split(whereSeparator: \.isWhitespace).count)
        }
    }

    @Test func captionsAreShort() throws {
        let entries = try Self.entries()
        #expect(entries.count > 10, "No copy found; check the path to SettingsCopy.swift.")
        let long = entries.filter { !$0.name.hasPrefix("info") && $0.words > 12 }
        #expect(long.isEmpty, "Captions over 12 words (move detail into an info… entry): \(long.map(\.name))")
        let longInfo = entries.filter { $0.name.hasPrefix("info") && $0.words > 45 }
        #expect(longInfo.isEmpty, "Info text over 45 words: \(longInfo.map(\.name))")
    }

    @Test func totalOnScreenStaysSmall() throws {
        let onScreen = try Self.entries().filter { !$0.name.hasPrefix("info") }.reduce(0) { $0 + $1.words }
        #expect(onScreen <= 150, "Settings shows \(onScreen) words of explanation; the budget is 150.")
    }
}
