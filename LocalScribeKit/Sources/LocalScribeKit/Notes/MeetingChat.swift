import Foundation

/// A saved question (a recipe): "Write follow-up email", "List my to-dos".
public struct Recipe: Codable, Hashable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// Asked about the meeting you're looking at.
        case meeting
        /// Asked across all your meetings.
        case library
    }

    public var id: String
    public var name: String
    public var prompt: String
    public var scope: Scope

    public init(id: String = UUID().uuidString, name: String, prompt: String, scope: Scope) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.scope = scope
    }

    public static let builtIn: [Recipe] = [
        Recipe(id: "follow-up-email", name: "Write follow-up email",
               prompt: "Write a short follow-up email to the other participants: thank them, recap what was decided, and list the next steps with owners and dates. Plain text, ready to paste.",
               scope: .meeting),
        Recipe(id: "my-todos", name: "List my to-dos",
               prompt: "List every action item that I (the note taker, \"You\" / \"Me\") own, with any due dates. If there are none, say so.",
               scope: .meeting),
        Recipe(id: "what-did-i-miss", name: "What did I miss?",
               prompt: "Summarise the last few minutes of the conversation in 3 to 5 bullets, so I can catch up.",
               scope: .meeting),
        Recipe(id: "decisions", name: "Decisions and owners",
               prompt: "List the decisions made and who owns each follow-up.",
               scope: .meeting),
        Recipe(id: "promises-this-week", name: "What did I promise this week?",
               prompt: "Across this week's meetings, list everything I committed to do, with the meeting each came from.",
               scope: .library),
    ]
}

/// Builds the conversation for "Ask" about one meeting or about all of them. The answer only uses what's in the
/// meetings; long transcripts are trimmed to fit the model.
public enum MeetingChat {
    /// One meeting, as the model sees it.
    public struct Meeting: Sendable {
        public var id: UUID
        public var title: String
        public var date: Date
        public var myNotes: String
        public var enhancedNotes: String?
        public var transcript: Transcript?

        public init(id: UUID, title: String, date: Date, myNotes: String = "", enhancedNotes: String? = nil, transcript: Transcript? = nil) {
            self.id = id
            self.title = title
            self.date = date
            self.myNotes = myNotes
            self.enhancedNotes = enhancedNotes
            self.transcript = transcript
        }
    }

    /// A meeting that might answer a question across the library.
    public struct Candidate: Sendable {
        public var id: UUID
        public var date: Date
        /// Lower-cased title, notes and transcript text.
        public var text: String

        public init(id: UUID, date: Date, text: String) {
            self.id = id
            self.date = date
            self.text = text
        }
    }

    /// Link the model uses to cite a meeting; the app opens it.
    public static func link(_ id: UUID) -> String { "localscribe://meeting/\(id.uuidString)" }

    public static func meetingID(from url: URL) -> UUID? {
        guard url.scheme == "localscribe", url.host() == "meeting" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    public static func systemPrompt(live: Bool, library: Bool, language: TranscriptLanguage) -> String {
        var lines = [
            "You answer questions about the user's meetings, using only the meeting material below.",
            "If the material doesn't contain the answer, say so plainly instead of guessing.",
            "Be brief and concrete. Use Markdown bullets when listing. The user is \"You\" / \"Me\" in transcripts.",
        ]
        if live { lines.append("The meeting is still going on; the transcript ends at the present moment.") }
        if library {
            lines.append("When a point comes from a specific meeting, cite it as a Markdown link with the meeting's title, e.g. [Weekly sync](localscribe://meeting/…), using the exact link given for that meeting.")
        }
        if let code = language.code { lines.append("Answer in \(TranscriptLanguage(rawValue: code).englishName).") }
        return lines.joined(separator: "\n")
    }

    /// The material for one meeting, trimmed to `budget` characters. Notes always fit first; the transcript gets
    /// what's left (the latest part during a live meeting, the start and end otherwise).
    public static func context(_ meeting: Meeting, budget: Int, live: Bool = false) -> String {
        var parts = ["# \(meeting.title)", "Date: \(meeting.date.formatted(date: .complete, time: .shortened))"]
        let notes = meeting.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("## My notes\n\(notes)") }
        if let enhanced = meeting.enhancedNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !enhanced.isEmpty {
            parts.append("## Meeting notes\n\(enhanced)")
        }
        var text = parts.joined(separator: "\n\n")
        if let transcript = meeting.transcript, !transcript.utterances.isEmpty {
            let lines = NotesGenerator.transcriptLines(transcript)
            let room = max(0, budget - text.count - 20)
            text += "\n\n## Transcript\n" + trimmed(lines, to: room, keepEnd: live)
        }
        return String(text.prefix(max(budget, 0)))
    }

    /// Keeps the end (live) or the start and end (finished) of a long transcript, marking what was left out.
    static func trimmed(_ text: String, to limit: Int, keepEnd: Bool) -> String {
        guard text.count > limit else { return text }
        guard limit > 40 else { return "" }
        let marker = "\n[…]\n"
        if keepEnd { return marker + String(text.suffix(limit - marker.count)) }
        let half = (limit - marker.count) / 2
        return String(text.prefix(half)) + marker + String(text.suffix(half))
    }

    /// The meetings most likely to answer `question`: word matches in title, notes and transcript, with a nudge
    /// toward recent meetings. Questions about "this week" / "today" favour those days.
    public static func rank(_ candidates: [Candidate], question: String, limit: Int = 6, now: Date = Date(),
                            calendar: Calendar = .current) -> [UUID] {
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
        let lowered = question.lowercased()
        let window: DateInterval? =
            lowered.contains("today") ? calendar.dateInterval(of: .day, for: now)
            : lowered.contains("this week") ? calendar.dateInterval(of: .weekOfYear, for: now)
            : lowered.contains("yesterday") ? calendar.date(byAdding: .day, value: -1, to: now).flatMap { calendar.dateInterval(of: .day, for: $0) }
            : nil
        let scored = candidates.map { candidate -> (UUID, Double) in
            var score = 0.0
            for word in words where candidate.text.contains(word) { score += 1 }
            let days = max(0, now.timeIntervalSince(candidate.date) / 86_400)
            score += 1 / (1 + days / 7)  // recency: up to +1
            if let window { score += window.contains(candidate.date) ? 5 : -5 }
            return (candidate.id, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The material for several meetings, each with its citation link, sharing `budget` characters.
    public static func libraryContext(_ meetings: [Meeting], budget: Int) -> String {
        guard !meetings.isEmpty else { return "No meetings matched." }
        let each = budget / meetings.count
        return meetings.map { meeting in
            "Meeting link: \(link(meeting.id))\n" + context(meeting, budget: each - 60)
        }.joined(separator: "\n\n---\n\n")
    }

    /// The full conversation: instructions, the material, the earlier turns, and the new question.
    public static func messages(system: String, context: String, history: [ChatMessage], question: String) -> [ChatMessage] {
        [.system(system + "\n\n<meetings>\n" + context + "\n</meetings>")] + history + [.user(question)]
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "what", "who", "how", "did", "does", "was", "were", "are", "with", "about", "this", "that",
        "from", "have", "has", "had", "you", "your", "our", "any", "all", "when", "where", "which", "why", "can",
        "meeting", "meetings", "week", "today", "yesterday", "said", "say", "tell", "list",
    ]
}
