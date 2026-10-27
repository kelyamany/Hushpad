import Foundation
import os

/// A notes layout. The body is instructions for the model; users can edit templates in Settings.
public struct NoteTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var instructions: String

    public init(id: String, name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
    }

    public static let builtIn: [NoteTemplate] = [
        NoteTemplate(id: "general", name: "General meeting", instructions: """
        ## Summary
        Two to four sentences: what the meeting was about and where it landed.
        ## Key points
        Bullets grouped under short ### topic headings when there are several topics.
        ## Decisions
        Bullets. Write "None recorded." if there were none.
        ## Action items
        Task list: `- [ ] Task — **Owner**` (add the due date if one was said).
        ## Open questions
        Bullets, only if there are any.
        """),
        NoteTemplate(id: "one-on-one", name: "1:1", instructions: """
        ## Summary
        ## Updates
        What each person shared, as bullets under their name.
        ## Feedback & concerns
        ## Decisions
        ## Action items
        Task list: `- [ ] Task — **Owner**`.
        ## For next time
        """),
        NoteTemplate(id: "interview", name: "Interview", instructions: """
        ## Candidate
        Role and background in one or two lines.
        ## Highlights
        Strongest answers and the evidence behind them, in your own words.
        ## Concerns
        ## Questions asked
        Question → summary of the answer.
        ## Next steps
        Task list.
        """),
        NoteTemplate(id: "standup", name: "Standup", instructions: """
        ## By person
        ### <Name>
        - Yesterday:
        - Today:
        - Blockers:
        ## Blockers to follow up
        Task list: `- [ ] Blocker — **Owner**`.
        """),
    ]
}

/// What goes into the notes.
public struct NotesInput: Sendable {
    public var recording: Recording
    public var transcript: Transcript?
    public var myNotes: String
    public var screenshots: [Screenshot]

    public init(recording: Recording, transcript: Transcript?, myNotes: String, screenshots: [Screenshot] = []) {
        self.recording = recording
        self.transcript = transcript
        self.myNotes = myNotes
        self.screenshots = screenshots
    }
}

/// Notes: your own notes are the backbone, the transcript fills in the detail.
/// Produces Obsidian-ready Markdown: YAML frontmatter, the notes, your raw notes, and the transcript folded away.
/// Finished notes, plus a title the model suggested when the meeting still had its automatic name.
public struct GeneratedNotes: Sendable {
    public var document: String
    public var title: String?
}

public struct NotesGenerator: Sendable {
    public var client: LLMClient
    public var template: NoteTemplate
    /// The editable part of the system prompt (app-wide or per folder). The output-format rules are added after it.
    public var instructions: String
    /// The language to write the notes in; `.auto` follows the meeting.
    public var notesLanguage: TranscriptLanguage
    public var includeTranscript: Bool
    /// Replace people's names with placeholders in what's sent (for cloud models), and restore them in the answer.
    public var maskNames: Bool
    /// Transcripts longer than this (characters) are condensed in sections first, so they fit small local models.
    public var maxTranscriptCharacters: Int
    /// Ask for a short title too when the meeting still has its automatic name ("Meeting at 10:16").
    public var suggestTitle: Bool

    public init(client: LLMClient, template: NoteTemplate, instructions: String = NotesGenerator.defaultInstructions,
                notesLanguage: TranscriptLanguage = .auto, includeTranscript: Bool = false, maskNames: Bool = false,
                maxTranscriptCharacters: Int = 40_000, suggestTitle: Bool = true) {
        self.maskNames = maskNames
        self.suggestTitle = suggestTitle
        self.client = client
        self.template = template
        self.instructions = instructions
        self.notesLanguage = notesLanguage
        self.includeTranscript = includeTranscript
        self.maxTranscriptCharacters = maxTranscriptCharacters
    }

    public enum Progress: Sendable {
        case condensing(part: Int, of: Int)
        case thinking
        case writing(String)
    }

    /// How much transcript fits in one request for a model with this context (tokens). Leaves room for the
    /// instructions, the user's notes and the answer (reasoning models also spend tokens thinking).
    /// ~3 characters per token is conservative for English, German and Arabic.
    public static func transcriptBudget(contextTokens: Int, notesCharacters: Int = 0) -> Int {
        let reserved = 1_200 + 3_000 + notesCharacters / 3
        return max(4_000, (contextTokens - reserved) * 3)
    }

    public func generate(_ original: NotesInput, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> GeneratedNotes {
        let masker = maskNames ? NameMasker(names: Self.participants(original)) : NameMasker(names: [])
        let input = Self.masked(original, with: masker)
        var transcriptText = input.transcript.map(Self.transcriptLines) ?? ""
        var limit = maxTranscriptCharacters
        if let context = await client.loadedContextLength() {
            limit = min(limit, Self.transcriptBudget(contextTokens: context, notesCharacters: input.myNotes.count))
        }
        let chunks = Self.chunks(transcriptText, limit: limit)
        if chunks.count > 1 {
            var condensed: [String] = []
            for (index, chunk) in chunks.enumerated() {
                progress(.condensing(part: index + 1, of: chunks.count))
                condensed.append(Self.cleaned(try await client.complete(Self.condenseMessages(chunk, part: index + 1, of: chunks.count))))
            }
            transcriptText = condensed.enumerated().map { "### Part \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
        }
        let messages = Self.messages(template: template, input: input, transcript: transcriptText, condensed: chunks.count > 1,
                                     instructions: instructions, language: notesLanguage)
        // Streamed text is cleaned and unmasked for the screen only ~10 times a second; the final text is done below.
        let lastUpdate = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let body = try await client.complete(messages, onThinking: { progress(.thinking) }) { text in
            let due = lastUpdate.withLock { last -> Bool in
                let now = Date()
                guard now.timeIntervalSince(last) >= 0.1 else { return false }
                last = now
                return true
            }
            if due { progress(.writing(masker.unmask(Self.cleaned(text)))) }
        }
        var named = original
        var title: String?
        if suggestTitle, original.recording.hasDefaultTitle {
            // A failed or empty title isn't worth failing the notes over: the meeting keeps its automatic name.
            let reply = try? await client.complete(Self.titleMessages(notes: Self.cleaned(body), language: notesLanguage))
            title = reply.flatMap { Self.title(fromReply: masker.unmask(Self.cleaned($0))) }
            if let title { named.recording.title = title }
        }
        let document = Self.document(body: masker.unmask(Self.cleaned(body)), input: named, model: client.model,
                                     includeTranscript: includeTranscript)
        return GeneratedNotes(document: document, title: title)
    }

    // MARK: Title

    static func titleMessages(notes: String, language: TranscriptLanguage) -> [ChatMessage] {
        let languageRule = language == .auto ? "in the language of the notes" : "in \(language.englishName)"
        return [
            ChatMessage(role: "system", content: """
            Write a short title for this meeting from its notes: 2 to 6 words, \(languageRule), naming what it was about \
            (e.g. "Q3 budget review", "Onboarding flow redesign"). Reply with the title only: no quotes, no Markdown, \
            no full stop, no date.
            """),
            ChatMessage(role: "user", content: String(notes.prefix(6_000))),
        ]
    }

    /// The first non-empty line of the reply, without Markdown, quotes or a trailing full stop; nil if unusable.
    static func title(fromReply reply: String) -> String? {
        guard let line = reply.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        var title = line
        if let colon = title.range(of: "title:", options: [.caseInsensitive, .anchored]) { title = String(title[colon.upperBound...]) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`\"'“”‘’ ").union(.whitespaces))
        while title.hasSuffix(".") { title.removeLast() }
        guard !title.isEmpty, title.count <= 80 else { return nil }
        return title
    }

    /// The input as the model sees it when names are masked: title, attendees, speaker names, transcript and notes.
    static func masked(_ input: NotesInput, with masker: NameMasker) -> NotesInput {
        guard !masker.isEmpty else { return input }
        var copy = input
        copy.recording.title = masker.mask(input.recording.title)
        copy.recording.attendees = input.recording.attendees.map(masker.mask)
        copy.myNotes = masker.mask(input.myNotes)
        if var transcript = input.transcript {
            transcript.speakers = transcript.speakers.map { var speaker = $0; speaker.name = masker.mask(speaker.name); return speaker }
            transcript.utterances = transcript.utterances.map { var line = $0; line.text = masker.mask(line.text); return line }
            copy.transcript = transcript
        }
        return copy
    }

    // MARK: Prompt

    /// The default instructions (editable in Settings › Notes and per folder).
    public static let defaultInstructions = """
    You write meeting notes for someone who was in the meeting. Turn what was said into a short, useful record: \
    what was discussed, what was decided, who will do what, and what is still open.

    Rules:
    - Synthesise, don't retell. Never replay the conversation line by line or speaker by speaker, and never \
    paste or rephrase passages of the transcript. The transcript is kept separately; the notes are the summary of it.
    - Do not quote the transcript. At most a few words in quotes when the exact wording matters (a name, a number, a promise).
    - No timestamps.
    - Use only what is in the transcript and the user's notes. Never invent names, numbers, dates or decisions.
    - The user's own notes show what mattered to them: cover every point they wrote, keep their wording where \
    possible, and add the detail from the transcript.
    - Refer to people by the speaker names given. Generic labels like "Speaker 2" or "Remote 1" may be kept as they are.
    - Be concise and specific. Prefer bullets over paragraphs. Leave out small talk.
    """

    /// The system prompt: the user's instructions plus format and language rules that editing can't remove.
    static func systemPrompt(instructions: String, language: TranscriptLanguage) -> String {
        let custom = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageRule = language == .auto
            ? "- Write in the main language of the meeting. If several languages are spoken, use the language of the user's own notes; if there are none, the language most of the meeting was in."
            : "- Write the notes in \(language.englishName), even where the meeting or the user's notes are in other languages: translate everything, including the section headings of the structure. Keep people's names, product names and quoted terms as they are."
        return """
        \(custom.isEmpty ? defaultInstructions : custom)

        Output:
        \(languageRule)
        - GitHub-flavoured Markdown only: no preamble, no closing remarks, no code fences around the whole answer, and no YAML frontmatter.
        - Do not add a top-level # title; start directly with the first ## section.
        """
    }

    static func messages(template: NoteTemplate, input: NotesInput, transcript: String, condensed: Bool,
                         instructions: String = defaultInstructions, language: TranscriptLanguage = .auto) -> [ChatMessage] {
        var prompt = """
        Meeting: \(input.recording.title)
        Date: \(input.recording.createdAt.formatted(date: .complete, time: .shortened))
        """
        let people = participants(input)
        if !people.isEmpty { prompt += "\nParticipants: \(people.joined(separator: ", "))" }
        prompt += "\n\nUse this structure:\n\(template.instructions)\n"
        let mine = input.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt += mine.isEmpty
            ? "\nThe user took no notes of their own.\n"
            : "\n<my_notes>\n\(mine)\n</my_notes>\n"
        if transcript.isEmpty {
            prompt += "\nThere is no transcript; write the notes from the user's notes alone.\n"
        } else {
            prompt += condensed
                ? "\n<transcript_condensed>\n\(transcript)\n</transcript_condensed>\n"
                : "\n<transcript>\n\(transcript)\n</transcript>\n"
        }
        // Repeated last: smaller models follow the language best when it's the final thing they read.
        if language != .auto {
            prompt += "\nWrite the notes in \(language.englishName), including the headings.\n"
        }
        return [.system(systemPrompt(instructions: instructions, language: language)), .user(prompt)]
    }

    static func condenseMessages(_ chunk: String, part: Int, of total: Int) -> [ChatMessage] {
        [.system("You condense part of a meeting transcript for someone who will write the final notes. Keep every fact, number, name, decision, action item (with owner) and open question. Use terse bullets in your own words, in the language that was spoken; don't copy sentences. Output Markdown bullets only."),
         .user("Part \(part) of \(total):\n\n\(chunk)")]
    }

    /// `[12:34] Name: text` lines — compact, and timestamps help the model order things.
    static func transcriptLines(_ transcript: Transcript) -> String {
        transcript.utterances.map {
            (transcript.isTimed ? "[\(Exporter.clock($0.start))] " : "") + "\(transcript.speakerName(for: $0.speaker)): \($0.text)"
        }
            .joined(separator: "\n")
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func participants(_ input: NotesInput) -> [String] {
        var names = input.recording.attendees
        for speaker in input.transcript?.speakers ?? [] where !names.contains(speaker.name) && speaker.key != SpeakerAligner.unknownSpeaker {
            names.append(speaker.name)
        }
        return names
    }

    /// Strips wrappers some models add despite instructions.
    static func cleaned(_ body: String) -> String {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        }
        // Reasoning models (e.g. Qwen, DeepSeek) may emit their thinking first.
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Document

    /// The final Markdown file: frontmatter for Obsidian, the notes, your own notes, the transcript (folded).
    public static func document(body: String, input: NotesInput, model: String?, includeTranscript: Bool) -> String {
        let recording = input.recording
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        var lines = ["---"]
        lines.append("title: \(yamlString(recording.title))")
        lines.append("date: \(dateFormatter.string(from: recording.createdAt))")
        lines.append("time: \(recording.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))")
        if recording.duration > 0 { lines.append("duration: \(Int((recording.duration / 60).rounded())) min") }
        let people = participants(input)
        if !people.isEmpty {
            lines.append("participants:")
            lines += people.map { "  - \(yamlString($0))" }
        }
        lines.append("tags:")
        lines.append("  - meeting")
        lines.append("source: localscribe-\(recording.source.rawValue.lowercased())")
        if let model { lines.append("notes_model: \(yamlString(model))") }
        if let engine = input.transcript?.engine { lines.append("transcript_engine: \(yamlString(engine))") }
        lines.append("---")
        lines.append("")
        lines.append("# \(recording.title)")
        lines.append("")
        lines.append(body)

        let mine = input.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty {
            lines += ["", "## My notes", "", mine]
        }
        if !input.screenshots.isEmpty {
            lines += ["", "## Screens", ""]
            lines += input.screenshots.map { "![Screen at \(Exporter.clock($0.time))](screens/\($0.url.lastPathComponent))" }
        }
        if includeTranscript, let transcript = input.transcript, !transcript.utterances.isEmpty {
            lines += ["", "<details>", "<summary>Transcript</summary>", ""]
            lines += transcript.utterances.map {
                "**\(transcript.speakerName(for: $0.speaker))**" + (transcript.isTimed ? " \(Exporter.clock($0.start))" : "") + " — \($0.text)  "
            }
            lines += ["", "</details>"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func yamlString(_ value: String) -> String {
        let needsQuotes = value.contains(where: { ":#'\"[]{},&*!|>%@`".contains($0) }) || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
