import AVFoundation
import Foundation

/// Joins two meetings into one, in the order the user chose: audio is appended (call audio padded with silence
/// where one part has none, so tracks stay aligned), transcripts are shifted and speakers with the same name
/// become one person, notes are combined per part, and screenshots keep their place on the new timeline.
/// The originals are left untouched; deleting them is a separate, explicit choice.
public enum RecordingMerger {
    public struct Plan: Sendable {
        public var first: Recording
        public var second: Recording
        public var title: String

        public init(first: Recording, second: Recording, title: String? = nil) {
            self.first = first
            self.second = second
            self.title = title ?? Self.defaultTitle(first, second)
        }

        static func defaultTitle(_ first: Recording, _ second: Recording) -> String {
            first.title == second.title ? first.title : "\(first.title) + \(second.title)"
        }
    }

    /// Creates the merged recording in `store` and returns it.
    @discardableResult
    public static func merge(_ plan: Plan, in store: RecordingStore) throws -> Recording {
        let first = plan.first, second = plan.second
        // Where part two starts on the merged timeline: after part one's audio. Untimed parts (imports) add nothing.
        // Readable copies: in an encrypted library the audio files on disk are sealed.
        let firstTracks = store.tracks(for: first), secondTracks = store.tracks(for: second)
        let offset = first.hasAudio ? max(first.duration, AudioInfo.duration(of: firstTracks.mic ?? store.micURL(for: first.id))) : 0

        var merged = Recording(title: plan.title, createdAt: first.createdAt,
                               hasMic: first.hasMic || second.hasMic,
                               hasSystemAudio: first.hasSystemAudio || second.hasSystemAudio,
                               language: first.language == second.language ? first.language : .auto,
                               source: first.hasAudio || second.hasAudio
                                   ? (first.hasAudio ? first.source : second.source) : .granola,
                               attendees: unique(first.attendees + second.attendees),
                               folderID: first.folderID ?? second.folderID)
        let folder = try store.createFolder(for: merged)
        do {
            // Audio
            var duration = 0.0
            if merged.hasMic {
                duration = try concatenate([part(first, firstTracks.mic ?? store.micURL(for: first.id), audio: first.hasMic, offset: 0),
                                            part(second, secondTracks.mic ?? store.micURL(for: second.id), audio: second.hasMic, offset: offset)],
                                           firstLength: offset, store: store, into: folder.appendingPathComponent("mic.wav"))
            }
            if merged.hasSystemAudio {
                let system = try concatenate([part(first, firstTracks.system ?? store.systemURL(for: first.id), audio: first.hasSystemAudio, offset: 0),
                                              part(second, secondTracks.system ?? store.systemURL(for: second.id), audio: second.hasSystemAudio, offset: offset)],
                                             firstLength: offset, store: store, into: folder.appendingPathComponent("system.wav"))
                duration = max(duration, system)
            }
            merged.duration = merged.hasAudio ? duration : 0

            // Transcript (the one each part currently shows)
            if let transcript = mergeTranscripts(active(first, store), active(second, store), offset: offset) {
                try store.save(transcript, for: merged.id)
                merged.activeEngine = transcript.engine
            }

            // Your notes and the enhanced notes
            if let mine = combine(notes: [store.notes(for: first.id, .mine), store.notes(for: second.id, .mine)],
                                  titles: [first.title, second.title]) {
                try store.saveNotes(mine, for: merged.id, .mine)
            }
            let enhancedParts = [store.notes(for: first.id, .enhanced), store.notes(for: second.id, .enhanced)]
                .map { $0.map(stripDocumentHeader) }
            if let body = combine(notes: enhancedParts, titles: [first.title, second.title], demote: true) {
                let input = NotesInput(recording: merged, transcript: store.transcripts(for: merged.id).first,
                                       myNotes: store.notes(for: merged.id, .mine) ?? "")
                let document = NotesGenerator.document(body: body, input: input, model: "merged", includeTranscript: false)
                try store.saveNotes(document, for: merged.id, .enhanced)
            }

            // Screenshots / photos
            for (recording, shift) in [(first, 0.0), (second, offset)] {
                for shot in ScreenshotStore.list(in: store.folder(for: recording.id)) {
                    try store.ensureLocal(shot.url)
                    try ScreenshotStore.save(jpeg: Data(contentsOf: shot.url), at: shot.time + shift, in: folder)
                }
            }

            try store.save(merged)
            return merged
        } catch {
            try? store.delete(merged.id)
            throw error
        }
    }

    // MARK: Transcripts

    /// Second part shifted by `offset`; speakers with the same (case-insensitive) name are one person,
    /// other keys are renamed if they'd collide.
    static func mergeTranscripts(_ first: Transcript?, _ second: Transcript?, offset: Double) -> Transcript? {
        guard first != nil || second != nil else { return nil }
        let a = first ?? Transcript(language: second!.language, speakers: [], utterances: [], engine: second!.engine)
        let b = second ?? Transcript(language: a.language, speakers: [], utterances: [], engine: a.engine)

        var speakers = a.speakers
        var keyMap: [String: String] = [:]
        for speaker in b.speakers {
            if !isGenericName(speaker.name),
               let same = speakers.first(where: { $0.name.caseInsensitiveCompare(speaker.name) == .orderedSame }) {
                keyMap[speaker.key] = same.key
            } else {
                var key = speaker.key
                var n = 2
                while speakers.contains(where: { $0.key == key }) { key = "\(speaker.key)·\(n)"; n += 1 }
                keyMap[speaker.key] = key
                // "Speaker A" from part 2 isn't necessarily part 1's "Speaker A": label it so they can be renamed apart.
                let clashes = speakers.contains { $0.name.caseInsensitiveCompare(speaker.name) == .orderedSame }
                speakers.append(Speaker(key: key, name: clashes ? "\(speaker.name) (part 2)" : speaker.name))
            }
        }
        // Untimed parts (imports) only carry an order; keep part two after part one either way.
        let shift = b.isTimed && a.isTimed ? offset : max(offset, (a.utterances.map(\.end).max() ?? 0) + 1)
        let shifted = b.utterances.map {
            Utterance(speaker: keyMap[$0.speaker] ?? $0.speaker, start: $0.start + shift, end: $0.end + shift, text: $0.text)
        }
        return Transcript(language: a.language == b.language ? a.language : .auto,
                          detectedLanguage: a.detectedLanguage ?? b.detectedLanguage,
                          speakers: speakers, utterances: a.utterances + shifted,
                          engine: a.engine == b.engine ? a.engine : "merged",
                          isTimed: a.isTimed && b.isTimed)
    }

    /// Automatic labels ("Speaker A", "Remote 2", "Room 1", "Unknown") don't identify a person across recordings.
    /// Real names and "Me" do.
    static func isGenericName(_ name: String) -> Bool {
        name.wholeMatch(of: /(?i)(speaker|remote|room)\s+\w{1,3}|unknown|transcript/) != nil
    }

    private static func active(_ recording: Recording, _ store: RecordingStore) -> Transcript? {
        let all = store.transcripts(for: recording.id)
        return all.first { $0.engine == recording.activeEngine } ?? all.last
    }

    // MARK: Notes

    /// Each non-empty part under a heading with its meeting title; nil if both are empty.
    /// `demote` pushes the parts' own headings one level down so they sit under the part heading.
    static func combine(notes: [String?], titles: [String], demote: Bool = false) -> String? {
        let parts = zip(notes, titles).compactMap { text, title -> (String, String)? in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return (title, demote ? demoteHeadings(text) : text)
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return parts[0].1 }
        let level = demote ? "##" : "###"
        return parts.map { "\(level) \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
    }

    static func demoteHeadings(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            line.hasPrefix("#") && line.prefix(while: { $0 == "#" }).count < 6 ? "#" + line : line
        }.joined(separator: "\n")
    }

    /// Removes YAML frontmatter, the "# Title" line, and the folded transcript from a generated notes document.
    static func stripDocumentHeader(_ document: String) -> String {
        var lines = document.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        var text = lines.joined(separator: "\n")
        if let details = text.range(of: "<details>") { text = String(text[..<details.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Audio

    /// One part of a track: its audio file, or nil to write silence for `length` seconds.
    private struct Part { var url: URL?; var length: Double }

    private static func part(_ recording: Recording, _ url: URL, audio: Bool, offset: Double) -> Part {
        Part(url: audio ? url : nil, length: recording.hasAudio ? recording.duration : 0)
    }

    /// Writes part one (or silence of its length), then part two, as 16 kHz mono. Returns the duration.
    private static func concatenate(_ parts: [Part], firstLength: Double, store: RecordingStore, into destination: URL) throws -> Double {
        let rate = TrackWriter.sampleRate
        let file = try WAVFile(url: destination, sampleRate: rate)
        var frames = 0
        for (index, part) in parts.enumerated() {
            if let url = part.url {
                try store.ensureLocal(url)
                frames += try copySamples(from: url, to: file)
            } else if index > 0 {
                // This part has no audio on this track (e.g. no call audio): keep the track as long as the others.
                let silence = Int(part.length * Double(rate))
                try appendSilence(silence, to: file)
                frames += silence
            }
            // Keep tracks aligned: pad part one up to where part two starts.
            if index == 0 {
                let target = Int(firstLength * Double(rate))
                if frames < target {
                    try appendSilence(target - frames, to: file)
                    frames = target
                }
            }
        }
        try file.close()
        return Double(frames) / Double(rate)
    }

    private static func copySamples(from url: URL, to file: WAVFile) throws -> Int {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        guard input.processingFormat.sampleRate == Double(TrackWriter.sampleRate), input.processingFormat.channelCount == 1 else {
            throw LocalScribeError.audioUnavailable("Unexpected audio format in \(url.lastPathComponent)")
        }
        let chunk: AVAudioFrameCount = 16_000 * 30
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else { return 0 }
        var total = 0
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            guard let data = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { break }
            try file.append(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            total += Int(buffer.frameLength)
        }
        return total
    }

    private static func appendSilence(_ frames: Int, to file: WAVFile) throws {
        var remaining = frames
        let second = [Int16](repeating: 0, count: TrackWriter.sampleRate)
        while remaining > 0 {
            let n = min(remaining, second.count)
            try file.append(Array(second[0..<n]))
            remaining -= n
        }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}
