import Foundation

/// Replaces people's names with placeholders ("Person 1", "Person 2"…) before text goes to a cloud model, and puts
/// them back in the answer. Full names and first names map to the same placeholder, so "Anna" and "Anna Schmidt"
/// both become "Person 1" (and come back as "Anna Schmidt").
///
/// Only names Hushpad knows (speaker names and attendees) are masked; generic labels like "Speaker 2" are left alone.
public struct NameMasker: Sendable {
    /// Placeholder → the name it stands for.
    public private(set) var names: [String: String] = [:]
    /// Lowercased name or first name → placeholder, longest first when masking.
    private var lookup: [(name: String, placeholder: String)] = []

    public init(names candidates: [String]) {
        var seen: [String: String] = [:]
        var index = 0
        for raw in candidates {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.isGeneric(name), seen[name.lowercased()] == nil else { continue }
            index += 1
            let placeholder = "Person \(index)"
            names[placeholder] = name
            seen[name.lowercased()] = placeholder
        }
        // First names too, when they're unambiguous.
        var firsts: [String: [String]] = [:]
        for (lower, placeholder) in seen {
            let parts = lower.split(separator: " ")
            if parts.count > 1, let first = parts.first, first.count >= 3 { firsts[String(first), default: []].append(placeholder) }
        }
        for (first, placeholders) in firsts where placeholders.count == 1 && seen[first] == nil {
            seen[first] = placeholders[0]
        }
        lookup = seen.map { ($0.key, $0.value) }.sorted { $0.name.count > $1.name.count }
    }

    public var isEmpty: Bool { names.isEmpty }

    public func mask(_ text: String) -> String {
        guard !lookup.isEmpty, !text.isEmpty else { return text }
        var result = text
        for (name, placeholder) in lookup {
            result = Self.replace(name, with: placeholder, in: result)
        }
        return result
    }

    public func unmask(_ text: String) -> String {
        guard !names.isEmpty, !text.isEmpty else { return text }
        // Highest numbers first, so "Person 1" doesn't eat the start of "Person 12".
        var result = text
        for (placeholder, name) in names.sorted(by: { $0.key.count > $1.key.count || ($0.key.count == $1.key.count && $0.key > $1.key) }) {
            result = Self.replace(placeholder, with: name, in: result, caseInsensitive: false)
        }
        return result
    }

    static func isGeneric(_ name: String) -> Bool {
        name.range(of: #"^(speaker|remote|room|person|unknown|me|you)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func replace(_ target: String, with replacement: String, in text: String, caseInsensitive: Bool = true) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: target) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
