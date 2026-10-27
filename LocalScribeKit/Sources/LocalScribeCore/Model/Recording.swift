import Foundation

/// Where a recording came from. Shown as a small glyph in the list, and decides what can be done with it
/// (e.g. Granola imports have no audio to re-transcribe).
public enum RecordingSource: String, Codable, Sendable, CaseIterable {
    case mac, iPhone, watch, granola

    public static var current: RecordingSource {
        #if os(macOS)
        .mac
        #elseif os(watchOS)
        .watch
        #else
        .iPhone
        #endif
    }

    public var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .watch: "applewatch"
        case .granola: "square.and.arrow.down"
        }
    }

    public var displayName: String {
        switch self {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .watch: "Apple Watch"
        case .granola: "Imported from Granola"
        }
    }
}

/// Metadata for one recording. Everything else lives next to it in the recording's folder:
///   <id>/recording.json, mic.wav, system.wav, transcripts/<engine>.json, screens/<ms>.jpg, notes/*.md
public struct Recording: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: Double
    public var hasMic: Bool
    public var hasSystemAudio: Bool
    public var systemOffset: Double
    /// The language spoken (what transcription is asked for); `.auto` detects it and allows several.
    public var language: TranscriptLanguage
    /// The language the notes are written in; `.auto` follows the meeting.
    public var notesLanguage: TranscriptLanguage
    /// Engine id of the transcript shown by default.
    public var activeEngine: String?
    public var source: RecordingSource
    /// Known participants (from Granola, or typed by the user). Used in note frontmatter.
    public var attendees: [String]
    /// The folder this meeting is filed in (see `Folder`); nil = unfiled.
    public var folderID: UUID?
    /// Optional "how many people" hints for speaker separation, remembered so retries use them.
    public var roomSpeakers: Int?
    public var remoteSpeakers: Int?
    /// When the audio was deleted to save space or for privacy (transcripts and notes are kept).
    public var audioRemovedAt: Date?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), duration: Double = 0,
                hasMic: Bool = true, hasSystemAudio: Bool = false, systemOffset: Double = 0,
                language: TranscriptLanguage = .auto, notesLanguage: TranscriptLanguage = .auto, activeEngine: String? = nil,
                source: RecordingSource = .current, attendees: [String] = [], folderID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.hasMic = hasMic
        self.hasSystemAudio = hasSystemAudio
        self.systemOffset = systemOffset
        self.language = language
        self.notesLanguage = notesLanguage
        self.activeEngine = activeEngine
        self.source = source
        self.attendees = attendees
        self.folderID = folderID
    }

    /// True when there's audio that can be (re-)transcribed.
    public var hasAudio: Bool { hasMic || hasSystemAudio }

    /// Still the automatic name new recordings get on the Mac, iPhone and Watch ("Meeting at 10:16", "Meeting at
    /// 9:05 AM"): nobody has named it, so generated notes may suggest a title.
    public var hasDefaultTitle: Bool {
        title.wholeMatch(of: /Meeting at \d{1,2}[:.]\d{2}(\s?[\p{L}.]{1,6})?/) != nil
    }

    // Lenient decoding: fields added in later versions get defaults, so older recordings keep loading
    // and devices running different versions can still sync.
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, hasMic, hasSystemAudio, systemOffset, language, notesLanguage, activeEngine, source, attendees
        case folderID, roomSpeakers, remoteSpeakers, audioRemovedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasMic = try c.decodeIfPresent(Bool.self, forKey: .hasMic) ?? false
        hasSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .hasSystemAudio) ?? false
        systemOffset = try c.decodeIfPresent(Double.self, forKey: .systemOffset) ?? 0
        language = (try? c.decodeIfPresent(TranscriptLanguage.self, forKey: .language)) ?? .auto
        notesLanguage = (try? c.decodeIfPresent(TranscriptLanguage.self, forKey: .notesLanguage)) ?? .auto
        activeEngine = try c.decodeIfPresent(String.self, forKey: .activeEngine)
        source = (try? c.decodeIfPresent(RecordingSource.self, forKey: .source)) ?? .mac
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        folderID = try? c.decodeIfPresent(UUID.self, forKey: .folderID)
        roomSpeakers = try? c.decodeIfPresent(Int.self, forKey: .roomSpeakers)
        remoteSpeakers = try? c.decodeIfPresent(Int.self, forKey: .remoteSpeakers)
        audioRemovedAt = try? c.decodeIfPresent(Date.self, forKey: .audioRemovedAt)
    }
}
