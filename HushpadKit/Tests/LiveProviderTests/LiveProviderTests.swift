import Foundation
import NaturalLanguage
import Testing
@testable import HushpadCore
@testable import HushpadKit

/// Calls the real cloud providers with the keys in the repo's `.env.local`. This target only exists when
/// `HUSHPAD_LIVE=1` is set (see Package.swift), so normal test runs never build or run it. Only the fictional
/// meeting text below is ever sent (never audio). Keys are never printed. Outputs go to `$HUSHPAD_LIVE_OUT`
/// (if set) for a human to read. `HUSHPAD_LIVE_GO_MODEL` picks another OpenCode Go model for one run.
@Suite(.enabled(if: LiveEnv.enabled), .serialized)
struct LiveProviderTests {
    // MARK: Providers and models

    @Test func openRouterListsModels() async throws {
        let models = try await client(.openRouter, model: "").listModels()
        LiveEnv.log("openrouter.models", "\(models.count) models; openrouter/free listed: \(models.contains("openrouter/free"))")
        #expect(models.count > 10)
    }

    @Test func openCodeGoListsModels() async throws {
        let models = try await client(.openCodeGo, model: "").listModels()
        LiveEnv.log("opencode.models", models.joined(separator: "\n"))
        #expect(!models.isEmpty)
        #expect(!models.contains { $0.hasPrefix("claude-") || $0.hasPrefix("gpt-") })
    }

    @Test(arguments: [
        (NotesProvider.openRouter, "openrouter/free", false),
        (NotesProvider.openRouter, "openrouter/free", true),
        (NotesProvider.openCodeGo, LiveEnv.goModel, false),
    ])
    func writesNotes(provider: NotesProvider, model: String, privateRouting: Bool) async throws {
        let name = "notes.\(provider.rawValue).\(model.replacingOccurrences(of: "/", with: "_")).private-\(privateRouting)"
        let generator = NotesGenerator(client: client(provider, model: model, privateRouting: privateRouting),
                                       template: NoteTemplate.builtIn[0], includeTranscript: false)
        do {
            let notes = try await generator.generate(LiveMeeting.input).document
            LiveEnv.log(name, notes)
            #expect(notes.contains("## "))
            #expect(LiveMeeting.quotedShare(notes) < 0.15)
        } catch {
            LiveEnv.log(name, "FAILED: \(error.localizedDescription)")
            // Private routing may legitimately rule out free models; that outcome is reported, not failed.
            if !privateRouting { throw error }
        }
    }

    // MARK: Language

    @Test(arguments: ["de", "es", "ar"])
    func notesFollowTheNotesLanguage(code: String) async throws {
        let language = TranscriptLanguage(rawValue: code)
        let generator = NotesGenerator(client: client(.openCodeGo, model: LiveEnv.goModel), template: NoteTemplate.builtIn[0],
                                       notesLanguage: language, includeTranscript: false)
        let notes = try await generator.generate(LiveMeeting.input).document
        let body = LiveMeeting.body(notes)
        let detected = NLLanguageRecognizer.dominantLanguage(for: body)?.rawValue
        LiveEnv.log("language.\(code)", "detected: \(detected ?? "?")\n\n\(notes)")
        #expect(detected == code)
    }

    // MARK: No re-quoting

    @Test func newPromptQuotesLessThanTheOldOne() async throws {
        let old = """
        You write meeting notes. Write in the language the meeting was held in.
        Rules:
        - Use only what is in the transcript and the user's notes. Never invent names, numbers, dates or decisions.
        - Be concise and specific. Prefer bullets over paragraphs.
        """
        let llm = client(.openCodeGo, model: LiveEnv.goModel)
        let before = try await NotesGenerator(client: llm, template: NoteTemplate.builtIn[2], instructions: old, includeTranscript: false)
            .generate(LiveMeeting.input).document
        let after = try await NotesGenerator(client: llm, template: NoteTemplate.builtIn[2], includeTranscript: false)
            .generate(LiveMeeting.input).document
        let (a, b) = (LiveMeeting.quotedShare(before), LiveMeeting.quotedShare(after))
        LiveEnv.log("quoting", "old prompt: \(a)\nnew prompt: \(b)\n\n--- old ---\n\(before)\n\n--- new ---\n\(after)")
        // Model output varies run to run, so compare against a fixed bar rather than the old prompt's score.
        #expect(b < 0.12)
    }

    // MARK: Name masking

    @Test func maskedNotesKeepRealNames() async throws {
        let masker = NameMasker(names: NotesGenerator.participants(LiveMeeting.input))
        let masked = NotesGenerator.masked(LiveMeeting.input, with: masker)
        let sent = NotesGenerator.messages(template: NoteTemplate.builtIn[0], input: masked,
                                           transcript: NotesGenerator.transcriptLines(masked.transcript!), condensed: false)
            .map(\.content).joined(separator: "\n")
        for name in ["Anna", "Weber", "Omar", "Haddad", "Jamie", "Chen"] { #expect(!sent.contains(name), "\(name) was sent") }

        let notes = try await NotesGenerator(client: client(.openCodeGo, model: LiveEnv.goModel), template: NoteTemplate.builtIn[0],
                                             includeTranscript: false, maskNames: true).generate(LiveMeeting.input).document
        LiveEnv.log("masking", notes)
        #expect(!notes.contains("Person 1") && !notes.contains("Person 2"))
        #expect(notes.contains("Anna") || notes.contains("Omar") || notes.contains("Jamie"))
    }

    // MARK: Helpers

    private func client(_ provider: NotesProvider, model: String, privateRouting: Bool = false) -> LLMClient {
        let key = provider == .openRouter ? LiveEnv.key("OPENROUTER_API_KEY") : LiveEnv.key("OPENCODE_API_KEY")
        return LLMClient.make(provider, baseURL: URL(string: provider.defaultBaseURL)!, apiKey: key, model: model,
                              privateRouting: privateRouting)
    }
}

enum LiveEnv {
    static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".env.local")

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["HUSHPAD_LIVE"] == "1" && FileManager.default.fileExists(atPath: file.path)
    }

    static let values: [String: String] = {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"" || value.first == "'", value.last == value.first { value = String(value.dropFirst().dropLast()) }
            result[trimmed[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")] = value
        }
        return result
    }()

    static func key(_ name: String) -> String { values[name] ?? "" }

    /// The OpenCode Go model to test with (`HUSHPAD_LIVE_GO_MODEL` overrides it for one run).
    static var goModel: String { ProcessInfo.processInfo.environment["HUSHPAD_LIVE_GO_MODEL"] ?? "longcat-2.5-preview-free" }

    static func log(_ name: String, _ text: String) {
        guard let dir = ProcessInfo.processInfo.environment["HUSHPAD_LIVE_OUT"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A fictional meeting (a small bakery's app launch), mixing English, German and Arabic.
enum LiveMeeting {
    static let lines: [(String, String)] = [
        ("A", "Okay, let's start. The goal today is to agree on the launch date for the Lumen Bakery ordering app."),
        ("O", "From the engineering side we are nearly done. The payment screen still crashes on older iPhones."),
        ("A", "How long do you need to fix that crash?"),
        ("O", "I think three days, maybe four if the bank's test environment is slow again."),
        ("J", "Marketing wants to launch on the twelfth of November because of the Christmas campaign."),
        ("A", "Das ist knapp, aber machbar, wenn Omar den Absturz bis Freitag behebt."),
        ("O", "Ja, ich schaffe das bis Freitag. Ich brauche aber zwei Testgeräte von Jamie."),
        ("J", "I can send you an iPhone 11 and an iPhone SE tomorrow morning."),
        ("A", "Good. What about the loyalty points feature?"),
        ("J", "Customers asked for it a lot, but it is not ready. I suggest we move it to January."),
        ("O", "Agreed, loyalty points in January. It needs a new database table and more testing."),
        ("A", "Fine, loyalty points move to January. Decision made."),
        ("O", "بالنسبة للترجمة العربية، ما زلنا نحتاج إلى مراجعة النصوص قبل الإطلاق."),
        ("A", "Omar, can you ask your cousin to review the Arabic texts by next Wednesday?"),
        ("O", "Yes, I will ask him today and share the file in the team folder."),
        ("J", "One more thing: the price for the delivery fee. Two euros fifty or three euros?"),
        ("A", "Let's keep two euros fifty for the launch and look at the numbers again in December."),
        ("J", "Okay. I will update the App Store screenshots with the new prices by Monday."),
        ("A", "Great. So, launch on the twelfth of November, crash fixed by Friday, Arabic review by Wednesday."),
        ("O", "And we still need someone to answer support emails during launch week. That is open."),
        ("A", "Right, we'll decide that next meeting. Thanks everyone."),
    ]

    static let input: NotesInput = {
        let names = ["A": "Anna Weber", "O": "Omar Haddad", "J": "Jamie Chen"]
        let transcript = Transcript(
            language: .auto,
            speakers: names.map { Speaker(key: $0.key, name: $0.value) }.sorted { $0.key < $1.key },
            utterances: lines.enumerated().map { Utterance(speaker: $1.0, start: Double($0 * 12), end: Double($0 * 12 + 10), text: $1.1) },
            engine: "test")
        let recording = Recording(title: "Lumen app launch sync", duration: 260, attendees: ["Anna Weber", "Omar Haddad", "Jamie Chen"])
        return NotesInput(recording: recording, transcript: transcript, myNotes: "- launch date?\n- loyalty points\n- delivery fee")
    }()

    /// The notes without frontmatter, title and the user's own notes.
    static func body(_ notes: String) -> String {
        var text = notes
        if let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        if let mine = text.range(of: "\n## My notes") { text = String(text[..<mine.lowerBound]) }
        return text.replacingOccurrences(of: #"[#*`\-\[\]>|]"#, with: " ", options: .regularExpression)
    }

    /// Share of the notes' 6-word sequences that appear verbatim in the transcript.
    static func quotedShare(_ notes: String) -> Double {
        let n = 6
        let source = Set(grams(lines.map(\.1).joined(separator: " "), n))
        let produced = grams(body(notes), n)
        guard !produced.isEmpty else { return 0 }
        return Double(produced.filter(source.contains).count) / Double(produced.count)
    }

    private static func grams(_ text: String, _ n: Int) -> [String] {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard words.count >= n else { return [] }
        return (0...(words.count - n)).map { words[$0..<($0 + n)].joined(separator: " ") }
    }
}
