import Foundation

/// The preferences that follow you between devices, stored as `settings.json` in the library folder (next to
/// `folders.json`), so they sync the same way meetings do. Device-specific choices (speech model, capture
/// options, where the library is) stay in each device's own preferences. The API key never goes here: it
/// syncs through iCloud Keychain.
///
/// Every field is optional and decoded leniently, so files written by older or newer versions still load.
public struct SharedSettings: Codable, Equatable, Sendable {
    public var language: TranscriptLanguage?
    public var autoTranscribe: Bool?
    public var cloudEnabled: Bool?
    public var cloudModel: String?
    public var notesProvider: NotesProvider?
    public var notesBaseURL: String?
    public var notesModel: String?
    public var notesTemplateID: String?
    public var templates: [NoteTemplate]?
    public var notesIncludeTranscript: Bool?
    public var notesLanguage: TranscriptLanguage?
    /// Custom notes instructions for the whole app; nil uses the built-in ones.
    public var notesPrompt: String?
    /// Cloud requests only go to providers that keep no data.
    public var cloudPrivateRouting: Bool?
    /// People's names are replaced with placeholders before notes go to a cloud model.
    public var cloudMaskNames: Bool?
    /// The library's files are encrypted (see `LibraryCrypto`), with the key whose fingerprint is `libraryKeyID`.
    public var libraryEncrypted: Bool?
    public var libraryKeyID: String?

    public static let fileName = "settings.json"

    public init(language: TranscriptLanguage? = nil, autoTranscribe: Bool? = nil, cloudEnabled: Bool? = nil,
                cloudModel: String? = nil, notesProvider: NotesProvider? = nil, notesBaseURL: String? = nil,
                notesModel: String? = nil, notesTemplateID: String? = nil, templates: [NoteTemplate]? = nil,
                notesIncludeTranscript: Bool? = nil, notesLanguage: TranscriptLanguage? = nil, notesPrompt: String? = nil,
                cloudPrivateRouting: Bool? = nil, cloudMaskNames: Bool? = nil, libraryEncrypted: Bool? = nil,
                libraryKeyID: String? = nil) {
        self.language = language
        self.autoTranscribe = autoTranscribe
        self.cloudEnabled = cloudEnabled
        self.cloudModel = cloudModel
        self.notesProvider = notesProvider
        self.notesBaseURL = notesBaseURL
        self.notesModel = notesModel
        self.notesTemplateID = notesTemplateID
        self.templates = templates
        self.notesIncludeTranscript = notesIncludeTranscript
        self.notesLanguage = notesLanguage
        self.notesPrompt = notesPrompt
        self.cloudPrivateRouting = cloudPrivateRouting
        self.cloudMaskNames = cloudMaskNames
        self.libraryEncrypted = libraryEncrypted
        self.libraryKeyID = libraryKeyID
    }

    private enum CodingKeys: String, CodingKey {
        case language, autoTranscribe, cloudEnabled, cloudModel, notesProvider, notesBaseURL, notesModel,
             notesTemplateID, templates, notesIncludeTranscript, notesLanguage, notesPrompt, cloudPrivateRouting, cloudMaskNames,
             libraryEncrypted, libraryKeyID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try? c.decodeIfPresent(TranscriptLanguage.self, forKey: .language)
        autoTranscribe = try? c.decodeIfPresent(Bool.self, forKey: .autoTranscribe)
        cloudEnabled = try? c.decodeIfPresent(Bool.self, forKey: .cloudEnabled)
        cloudModel = try? c.decodeIfPresent(String.self, forKey: .cloudModel)
        notesProvider = try? c.decodeIfPresent(NotesProvider.self, forKey: .notesProvider)
        notesBaseURL = try? c.decodeIfPresent(String.self, forKey: .notesBaseURL)
        notesModel = try? c.decodeIfPresent(String.self, forKey: .notesModel)
        notesTemplateID = try? c.decodeIfPresent(String.self, forKey: .notesTemplateID)
        templates = try? c.decodeIfPresent([NoteTemplate].self, forKey: .templates)
        notesIncludeTranscript = try? c.decodeIfPresent(Bool.self, forKey: .notesIncludeTranscript)
        notesLanguage = try? c.decodeIfPresent(TranscriptLanguage.self, forKey: .notesLanguage)
        notesPrompt = try? c.decodeIfPresent(String.self, forKey: .notesPrompt)
        cloudPrivateRouting = try? c.decodeIfPresent(Bool.self, forKey: .cloudPrivateRouting)
        cloudMaskNames = try? c.decodeIfPresent(Bool.self, forKey: .cloudMaskNames)
        libraryEncrypted = try? c.decodeIfPresent(Bool.self, forKey: .libraryEncrypted)
        libraryKeyID = try? c.decodeIfPresent(String.self, forKey: .libraryKeyID)
    }

    public static func url(in root: URL) -> URL { root.appendingPathComponent(fileName) }

    /// nil if the library has no settings file yet (or it can't be read).
    public static func load(from root: URL) -> SharedSettings? {
        guard let data = try? FileCoordination.read(url(in: root)) else { return nil }
        return try? RecordingStore.decode(SharedSettings.self, from: data)
    }

    public func save(to root: URL) throws {
        // Stays readable without the key: it says whether the library is encrypted.
        try FileCoordination.write(RecordingStore.encode(self), to: Self.url(in: root), sealed: false)
    }

    /// The file's modification date, to skip re-reading it when nothing changed.
    public static func stamp(in root: URL) -> Date? {
        try? url(in: root).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
