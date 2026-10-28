import Foundation
import Testing

/// Keeps views on the type tokens (DESIGN.md › Type): no built-in SwiftUI text styles via `.font(...)`, no serif `Font.system` titles.
@Suite struct TypographyLintTests {
    private static let builtInStyle = try! NSRegularExpression(
        pattern: #"\.font\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b"#)
    private static let serifTitle = try! NSRegularExpression(
        pattern: #"\.system\(\.[a-zA-Z0-9]+, design: \.serif\)"#)

    /// `HushpadKit/Tests/HushpadKitTests/<file>` → four levels up is the repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HushpadKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // HushpadKit
        .deletingLastPathComponent()  // repo root

    private static func swiftFiles(under relativeDir: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(relativeDir)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func viewsUseTypeTokens() throws {
        let files = Self.swiftFiles(under: "App") + Self.swiftFiles(under: "HushpadKit/Sources/HushpadUI")
        #expect(!files.isEmpty, "No Swift files found; check the repo-root path calculation.")

        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if Self.builtInStyle.firstMatch(in: line, range: range) != nil
                    || Self.serifTitle.firstMatch(in: line, range: range) != nil {
                    hits.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(hits.isEmpty, Comment(rawValue: "Use the type tokens (DESIGN.md › Type) instead of built-in text styles:\n" + hits.joined(separator: "\n")))
    }
}
