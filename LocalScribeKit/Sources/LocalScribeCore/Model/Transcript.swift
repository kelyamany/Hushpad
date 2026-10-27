import Foundation

/// A spoken or written language: what Whisper should transcribe in, or what the notes should be written in.
/// `auto` lets the model detect it (and allows several languages in one meeting).
///
/// Stored as its raw value (`"auto"` or an ISO 639 code such as `"de"`), so files from older versions still
/// decode, and codes this version doesn't list are kept rather than lost.
public struct TranscriptLanguage: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init?(code: String?) {
        guard let code = code?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty else { return nil }
        self.rawValue = code
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        rawValue = value.isEmpty ? "auto" : value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: String { rawValue }

    public static let auto = TranscriptLanguage(rawValue: "auto")
    public static let english = TranscriptLanguage(rawValue: "en")
    public static let german = TranscriptLanguage(rawValue: "de")
    public static let arabic = TranscriptLanguage(rawValue: "ar")

    /// ISO code passed to the transcription engine, or nil for auto-detection.
    public var code: String? { self == .auto ? nil : rawValue }

    /// In the user's own language, e.g. "German" (or "Deutsch" on a German system).
    public var displayName: String {
        if self == .auto { return "Auto-detect" }
        return Locale.current.localizedString(forLanguageCode: localeCode)?.localizedCapitalized ?? rawValue
    }

    /// Always in English, for prompts sent to language models.
    public var englishName: String {
        if self == .auto { return "the language of the meeting" }
        return Locale(identifier: "en").localizedString(forLanguageCode: localeCode) ?? rawValue
    }

    public var isRightToLeft: Bool { Self.isRightToLeft(code: code) }

    public static func isRightToLeft(code: String?) -> Bool {
        guard let code else { return false }
        return Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    /// Whisper uses a few non-standard codes.
    private var localeCode: String {
        switch rawValue {
        case "jw": "jv"
        default: rawValue
        }
    }

    /// The most widely spoken languages, shown first in pickers.
    public static let common: [TranscriptLanguage] = ["en", "es", "fr", "de", "it", "pt", "nl", "ar", "zh", "ja", "ko", "hi",
        "ru", "tr", "pl", "uk", "sv", "he", "fa", "ur", "id", "vi", "th", "el", "cs"].map(TranscriptLanguage.init(rawValue:))

    /// Every language Whisper can transcribe (also used for notes), sorted by name.
    public static var all: [TranscriptLanguage] {
        whisperCodes.map(TranscriptLanguage.init(rawValue:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public static let whisperCodes = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi",
        "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg", "lt", "la", "mi", "ml",
        "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs",
        "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am",
        "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln",
        "ha", "ba", "jw", "su", "yue",
    ]
}

/// A single word with timing, as produced by a transcription engine.
public struct TimedWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Engine confidence 0...1 when available.
    public var probability: Double?

    public init(text: String, start: Double, end: Double, probability: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// A span of time attributed to one speaker, as produced by a diarizer.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public struct Speaker: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable key referenced by utterances ("me", "S1", "S2", …).
    public var key: String
    /// User-editable label shown in the UI and exports.
    public var name: String

    public var id: String { key }

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// One contiguous stretch of speech by a single speaker.
public struct Utterance: Codable, Equatable, Sendable, Identifiable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public var id: String { "\(speaker)-\(start)" }

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var language: TranscriptLanguage
    /// Language the engine actually detected (useful when `language == .auto`).
    public var detectedLanguage: String?
    public var speakers: [Speaker]
    public var utterances: [Utterance]
    /// Which engine produced the text, e.g. "whisperkit:openai_whisper-large-v3" or "openrouter:google/gemini-2.5-flash".
    public var engine: String
    public var createdAt: Date
    /// False for imported transcripts without timestamps (Granola): times are then just ordering, not shown.
    public var isTimed: Bool

    public init(
        language: TranscriptLanguage,
        detectedLanguage: String? = nil,
        speakers: [Speaker],
        utterances: [Utterance],
        engine: String,
        createdAt: Date = Date(),
        isTimed: Bool = true
    ) {
        self.language = language
        self.detectedLanguage = detectedLanguage
        self.speakers = speakers
        self.utterances = utterances
        self.engine = engine
        self.createdAt = createdAt
        self.isTimed = isTimed
    }

    private enum CodingKeys: String, CodingKey {
        case language, detectedLanguage, speakers, utterances, engine, createdAt, isTimed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? c.decodeIfPresent(TranscriptLanguage.self, forKey: .language)) ?? .auto
        detectedLanguage = try c.decodeIfPresent(String.self, forKey: .detectedLanguage)
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        engine = try c.decode(String.self, forKey: .engine)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isTimed = try c.decodeIfPresent(Bool.self, forKey: .isTimed) ?? true
    }

    /// True for transcripts made by the cloud transcription of older versions (audio sent to OpenRouter).
    /// Current versions always transcribe on the device.
    public var usedCloud: Bool { engine.hasPrefix("openrouter:") }

    public var isImported: Bool { engine.hasPrefix("import:") }

    public func speakerName(for key: String) -> String {
        speakers.first { $0.key == key }?.name ?? key
    }

    public mutating func renameSpeaker(_ key: String, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.key == key }) else { return }
        speakers[index].name = name
    }

    /// The speaker already called `name` (ignoring case and surrounding spaces), other than `key`.
    public func speaker(named name: String, except key: String) -> Speaker? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return speakers.first { $0.key != key && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }

    /// Treats `source` as the same person as `target`: their lines move to `target` and `source` disappears.
    /// Back-to-back lines that now share a speaker are joined, since an utterance is one stretch of speech.
    public mutating func mergeSpeaker(_ source: String, into target: String) {
        guard source != target, speakers.contains(where: { $0.key == target }) else { return }
        speakers.removeAll { $0.key == source }
        var merged: [Utterance] = []
        var lastWasSource = false
        for var utterance in utterances {
            let wasSource = utterance.speaker == source
            if wasSource { utterance.speaker = target }
            // Only joins across the old boundary; lines that were already separate stay separate.
            if var last = merged.last, utterance.speaker == target, last.speaker == target, wasSource || lastWasSource {
                last.end = max(last.end, utterance.end)
                last.text = [last.text, utterance.text].filter { !$0.isEmpty }.joined(separator: " ")
                merged[merged.count - 1] = last
            } else {
                merged.append(utterance)
            }
            lastWasSource = wasSource
        }
        utterances = merged
    }
}
