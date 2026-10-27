import Foundation

/// One meeting from a Granola export.
public struct GranolaMeeting: Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// Granola's AI summary (Markdown).
    public var summary: String
    /// What you typed in Granola.
    public var notes: String
    public var transcript: Transcript?
    public var attendees: [String]
}

/// Imports Granola's CSV export (or the .zip it comes in). Columns are matched by header name, so small changes
/// in Granola's format don't break it. Re-importing is safe: Granola's document id becomes the recording id.
public enum GranolaImporter {
    static let aliases: [String: [String]] = [
        "id": ["document_id", "id", "note_id"],
        "title": ["document_title", "title", "name"],
        "created": ["document_created", "created_at", "created", "date", "meeting_date"],
        "summary": ["summary", "enhanced_notes", "ai_notes", "notes_markdown"],
        "notes": ["notes", "my_notes", "user_notes", "personal_notes"],
        "transcript": ["transcript", "transcription"],
        "attendees": ["attendees", "participants", "people"],
    ]

    public static func meetings(fromCSV text: String) throws -> [GranolaMeeting] {
        let records = CSV.records(text)
        guard let first = records.first else { throw LocalScribeError.importFailed("The file has no meetings.") }
        guard field("title", in: first) != nil || field("transcript", in: first) != nil else {
            throw LocalScribeError.importFailed("This doesn't look like a Granola export (no title or transcript column).")
        }
        return records.compactMap(meeting)
    }

    /// Reads a .csv, or every .csv inside a Granola .zip export (macOS).
    public static func meetings(from url: URL) throws -> [GranolaMeeting] {
        if url.pathExtension.lowercased() == "zip" {
            #if os(macOS)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("granola-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, folder.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw LocalScribeError.importFailed("Couldn't open the zip file.") }
            let csvs = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension.lowercased() == "csv" && !$0.path.contains("__MACOSX") }
                .sorted { $0.path < $1.path } ?? []
            guard !csvs.isEmpty else { throw LocalScribeError.importFailed("The zip has no CSV file.") }
            return try csvs.flatMap { try meetings(fromCSV: String(contentsOf: $0, encoding: .utf8)) }
            #else
            throw LocalScribeError.importFailed("Unzip the export first, then pick the .csv file.")
            #endif
        }
        return try meetings(fromCSV: String(contentsOf: url, encoding: .utf8))
    }

    /// Files meetings into the library. Returns how many were new (already-imported ones are skipped).
    @discardableResult
    public static func importMeetings(_ meetings: [GranolaMeeting], into store: RecordingStore,
                                      includeTranscriptInNotes: Bool = true) throws -> Int {
        let existing = Set(store.loadAll().map(\.id))
        var imported = 0
        for meeting in meetings where !existing.contains(meeting.id) {
            var recording = Recording(id: meeting.id, title: meeting.title, createdAt: meeting.createdAt,
                                      hasMic: false, hasSystemAudio: false, source: .granola, attendees: meeting.attendees)
            if let transcript = meeting.transcript {
                recording.activeEngine = transcript.engine
                recording.language = transcript.language
            }
            try store.save(recording)
            if let transcript = meeting.transcript { try store.save(transcript, for: recording.id) }
            let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty { try store.saveNotes(notes, for: recording.id, .mine) }
            let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                let input = NotesInput(recording: recording, transcript: meeting.transcript, myNotes: notes)
                let document = NotesGenerator.document(body: summary, input: input, model: "granola",
                                                       includeTranscript: includeTranscriptInNotes)
                try store.saveNotes(document, for: recording.id, .enhanced)
            }
            imported += 1
        }
        return imported
    }

    // MARK: Parsing

    static func field(_ name: String, in record: [String: String]) -> String? {
        for key in aliases[name] ?? [name] {
            if let value = record[key] { return value }
        }
        return nil
    }

    static func meeting(from record: [String: String]) -> GranolaMeeting? {
        let title = field("title", in: record)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let transcriptText = field("transcript", in: record) ?? ""
        let summary = field("summary", in: record) ?? ""
        let notes = field("notes", in: record) ?? ""
        guard !title.isEmpty || !transcriptText.isEmpty || !summary.isEmpty else { return nil }

        let rawID = field("id", in: record) ?? ""
        let id = UUID(uuidString: rawID) ?? stableUUID(rawID.isEmpty ? title + (field("created", in: record) ?? "") : rawID)
        let created = field("created", in: record).flatMap(parseDate) ?? Date()
        let attendees = (field("attendees", in: record) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return GranolaMeeting(id: id, title: title.isEmpty ? "Granola meeting" : title, createdAt: created,
                              summary: summary, notes: notes, transcript: transcript(from: transcriptText, at: created),
                              attendees: attendees)
    }

    /// Granola transcripts are plain lines, optionally prefixed "Speaker A:" / "Me:" / "Them:". No timestamps.
    static func transcript(from text: String, at date: Date) -> Transcript? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // Granola's own labels ("Speaker A", "Me", "Them") always count. Any other prefix only counts if it's
        // used repeatedly, so a line like "Von 8 bis 15: geöffnet" isn't mistaken for a speaker.
        let pattern = /^([^:]{1,32}):\s+(.+)$/
        let granolaLabel = /Speaker [A-Z0-9]{1,2}|Me|Them|You/
        let prefixes = lines.compactMap { $0.wholeMatch(of: pattern).map { String($0.1) } }
        let counts = Dictionary(prefixes.map { ($0, 1) }, uniquingKeysWith: +)
        let speakers = Set(counts.filter { $0.value >= 3 || $0.key.wholeMatch(of: granolaLabel) != nil }.keys)

        var order: [String] = []
        var utterances: [Utterance] = []
        var index = 0.0
        for line in lines {
            var speaker = SpeakerAligner.unknownSpeaker
            var content = line
            if let match = line.wholeMatch(of: pattern), speakers.contains(String(match.1)) {
                speaker = String(match.1)
                content = String(match.2)
            }
            if !order.contains(speaker) { order.append(speaker) }
            // Join consecutive lines of the same speaker into one paragraph (unlabelled transcripts: every ~5 lines).
            if let last = utterances.last, last.speaker == speaker,
               speaker != SpeakerAligner.unknownSpeaker || last.text.count < 400 {
                utterances[utterances.count - 1].text += " " + content
                utterances[utterances.count - 1].end = index + 1
            } else {
                utterances.append(Utterance(speaker: speaker, start: index, end: index + 1, text: content))
            }
            index += 1
        }

        let labelled = speakers.isEmpty == false
        let speakerList = order.map { key -> Speaker in
            key == SpeakerAligner.unknownSpeaker
                ? Speaker(key: key, name: labelled ? "Unknown" : "Transcript")
                : Speaker(key: key, name: key)
        }
        return Transcript(language: .auto, speakers: speakerList, utterances: utterances,
                          engine: "import:granola", createdAt: date, isTimed: false)
    }

    static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Deterministic UUID from a string, so re-importing a row without a UUID id doesn't duplicate it.
    static func stableUUID(_ string: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in string.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
