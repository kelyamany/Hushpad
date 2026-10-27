import Foundation

/// Pure functions that turn timed words + speaker turns into a readable, speaker-attributed transcript.
public enum SpeakerAligner {
    public static let unknownSpeaker = "unknown"

    /// Assigns every word to the speaker whose turn overlaps it the most.
    /// Words that fall in a gap snap to the nearest turn within `snapDistance`, otherwise inherit the previous word's speaker.
    public static func assign(
        words: [TimedWord],
        turns: [SpeakerTurn],
        snapDistance: Double = 1.0
    ) -> [(word: TimedWord, speaker: String)] {
        let sortedTurns = turns.sorted { $0.start < $1.start }
        var previous: String?
        return words.map { word in
            let speaker = bestOverlap(for: word, in: sortedTurns)
                ?? nearest(to: word, in: sortedTurns, within: snapDistance)
                ?? previous
                ?? unknownSpeaker
            previous = speaker
            return (word, speaker)
        }
    }

    /// Drops Whisper hallucinations in silence ("you", "Vielen Dank.", …). A word mostly outside detected speech
    /// survives only if it is confident AND close to speech (the diarizer may have clipped a turn edge).
    public static func dropNonSpeech(
        words: [TimedWord],
        turns: [SpeakerTurn],
        minSpeechFraction: Double = 0.3,
        minConfidence: Double = 0.8,
        maxDistanceFromSpeech: Double = 2.0
    ) -> [TimedWord] {
        // No speech found at all (silence, or a track too quiet to diarize): only trust confident words,
        // since Whisper tends to "hear" short phrases or punctuation in silence.
        guard !turns.isEmpty else { return words.filter { ($0.probability ?? 1) >= minConfidence } }
        let sortedTurns = turns.sorted { $0.start < $1.start }
        return words.filter { word in
            let duration = max(word.end - word.start, 0.01)
            let speech = sortedTurns.reduce(0) { $0 + overlap(word, $1) }
            if speech / duration >= minSpeechFraction { return true }
            let mid = (word.start + word.end) / 2
            let gap = sortedTurns.map { distance(mid, $0) }.min() ?? .infinity
            // Engines without per-word confidence (cloud) only need to be near speech.
            return (word.probability ?? 1) >= minConfidence && gap <= maxDistanceFromSpeech
        }
    }

    /// Groups consecutive words by the same speaker into utterances, splitting on pauses longer than `maxGap`.
    public static func utterances(
        from assigned: [(word: TimedWord, speaker: String)],
        maxGap: Double = 2.0
    ) -> [Utterance] {
        var result: [Utterance] = []
        var current: (speaker: String, words: [TimedWord])?

        func flush() {
            guard let current, let first = current.words.first, let last = current.words.last else { return }
            let text = joinWords(current.words)
            // Punctuation-only fragments ("." or "…") aren't speech.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            result.append(Utterance(speaker: current.speaker, start: first.start, end: last.end, text: text))
        }

        for (word, speaker) in assigned {
            if let open = current, open.speaker == speaker,
               let last = open.words.last, word.start - last.end <= maxGap {
                current?.words.append(word)
            } else {
                flush()
                current = (speaker, [word])
            }
        }
        flush()
        return result
    }

    /// Engines emit words with their own leading whitespace (" Hello", "'s"), so joining is concatenation.
    public static func joinWords(_ words: [TimedWord]) -> String {
        words.map(\.text).joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes words from the mic track that are just the call audio leaking from the laptop speakers.
    /// A mic word counts as echo when the system track has the same word at nearly the same time; we only
    /// drop it when most of its neighbours are echo too, so a lone coincidental match survives.
    public static func removeEcho(
        micWords: [TimedWord],
        systemWords: [TimedWord],
        tolerance: Double = 0.75,
        window: Int = 2,
        threshold: Double = 0.6
    ) -> [TimedWord] {
        guard !micWords.isEmpty, !systemWords.isEmpty else { return micWords }
        let system = systemWords.map { (key: normalize($0.text), start: $0.start) }.sorted { $0.start < $1.start }
        let starts = system.map(\.start)

        let isMatch: [Bool] = micWords.map { word in
            let key = normalize(word.text)
            guard !key.isEmpty else { return false }
            var i = lowerBound(starts, word.start - tolerance)
            while i < system.count, system[i].start <= word.start + tolerance {
                if system[i].key == key { return true }
                i += 1
            }
            return false
        }

        return micWords.indices.compactMap { index in
            guard isMatch[index] else { return micWords[index] }
            let lo = max(0, index - window), hi = min(micWords.count - 1, index + window)
            let matches = (lo...hi).filter { isMatch[$0] }.count
            let fraction = Double(matches) / Double(hi - lo + 1)
            return fraction >= threshold ? nil : micWords[index]
        }
    }

    /// Renames raw diarizer ids ("0", "3", …) to "S1", "S2", … in order of first appearance.
    public static func normalizeSpeakerKeys(_ utterances: [Utterance], prefix: String = "S") -> [Utterance] {
        var mapping: [String: String] = [:]
        return utterances.map { utterance in
            var copy = utterance
            if utterance.speaker != unknownSpeaker {
                if mapping[utterance.speaker] == nil {
                    mapping[utterance.speaker] = "\(prefix)\(mapping.count + 1)"
                }
                copy.speaker = mapping[utterance.speaker]!
            }
            return copy
        }
    }

    /// Interleaves utterances from several tracks by start time.
    public static func merge(_ tracks: [[Utterance]]) -> [Utterance] {
        tracks.flatMap { $0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    // MARK: - Helpers

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func overlap(_ word: TimedWord, _ turn: SpeakerTurn) -> Double {
        max(0, min(word.end, turn.end) - max(word.start, turn.start))
    }

    private static func bestOverlap(for word: TimedWord, in turns: [SpeakerTurn]) -> String? {
        var best: (speaker: String, overlap: Double)?
        for turn in turns {
            if turn.start > word.end { break }
            let amount = overlap(word, turn)
            if amount > 0, amount > (best?.overlap ?? 0) {
                best = (turn.speaker, amount)
            }
        }
        return best?.speaker
    }

    private static func nearest(to word: TimedWord, in turns: [SpeakerTurn], within limit: Double) -> String? {
        let mid = (word.start + word.end) / 2
        let candidate = turns.min { distance(mid, $0) < distance(mid, $1) }
        guard let candidate, distance(mid, candidate) <= limit else { return nil }
        return candidate.speaker
    }

    private static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    private static func lowerBound(_ values: [Double], _ target: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
