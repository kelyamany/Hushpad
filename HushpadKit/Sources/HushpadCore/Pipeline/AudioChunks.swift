@preconcurrency import AVFoundation

/// Splits a long recording into parts of about five minutes so transcription can be paused and resumed part by part.
/// Each cut is placed at the quietest moment near the mark, so no word is cut in half.
public enum AudioChunks {
    /// Target length of a part.
    public static let target: Double = 300
    /// How far either side of each mark to look for a quiet moment.
    public static let search: Double = 10
    /// Loudness is measured in windows of this length.
    static let window: Double = 0.1

    /// The parts of `url`, in order, covering the whole file. Short files are one part.
    public static func plan(url: URL, target: Double = target, search: Double = search) throws -> [Range<Double>] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        guard duration > target * 1.2 else { return [0..<max(duration, 0.001)] }

        var cuts: [Double] = []
        var mark = target
        while mark < duration - target * 0.2 {
            let low = max(cuts.last ?? 0, mark - search), high = min(duration, mark + search)
            let energies = try loudness(of: file, from: low, to: high, rate: rate)
            let cut = low + Double(quietest(energies)) * window + window / 2
            cuts.append(cut)
            mark = cut + target
        }
        return ranges(cuts: cuts, duration: duration)
    }

    /// Consecutive ranges from 0 to `duration`, split at `cuts`.
    public static func ranges(cuts: [Double], duration: Double) -> [Range<Double>] {
        let bounds = [0] + cuts.filter { $0 > 0 && $0 < duration }.sorted() + [duration]
        return zip(bounds, bounds.dropFirst()).compactMap { $0 < $1 ? $0..<$1 : nil }
    }

    /// Index of the quietest window. Ties go to the one nearest the middle (the mark itself).
    public static func quietest(_ energies: [Float]) -> Int {
        guard !energies.isEmpty else { return 0 }
        let middle = energies.count / 2
        return energies.indices.min { a, b in
            energies[a] != energies[b] ? energies[a] < energies[b] : abs(a - middle) < abs(b - middle)
        } ?? middle
    }

    /// Mean square of each 100 ms window between two times.
    private static func loudness(of file: AVAudioFile, from start: Double, to end: Double, rate: Double) throws -> [Float] {
        let frames = AVAudioFrameCount(max(0, end - start) * rate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        file.framePosition = AVAudioFramePosition(start * rate)
        try file.read(into: buffer, frameCount: frames)
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let size = max(1, Int(window * rate))
        let count = Int(buffer.frameLength)
        return stride(from: 0, to: count, by: size).map { offset in
            let end = min(count, offset + size)
            var sum: Float = 0
            for i in offset..<end { sum += samples[i] * samples[i] }
            return sum / Float(end - offset)
        }
    }
}

/// Transcription saved part by part, so a paused or interrupted job resumes where it stopped.
/// Stored next to the transcripts as a hidden file and removed once the transcript is complete.
public struct PartialTranscript: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        public var index: Int
        public var words: [TimedWord]
        public var detectedLanguage: String?

        public init(index: Int, words: [TimedWord], detectedLanguage: String?) {
            self.index = index
            self.words = words
            self.detectedLanguage = detectedLanguage
        }
    }

    /// Only resumed with the same model and language; otherwise it starts over.
    public var engine: String
    public var language: TranscriptLanguage
    /// The parts of each track ("mic", "system"), planned once so resuming uses the same cuts.
    public var plans: [String: [Range<Double>]] = [:]
    /// Finished parts of each track.
    public var parts: [String: [Part]] = [:]

    public init(engine: String, language: TranscriptLanguage) {
        self.engine = engine
        self.language = language
    }

    /// How much of the planned work is done, 0…1.
    public var fraction: Double {
        let total = plans.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        return Double(parts.values.reduce(0) { $0 + $1.count }) / Double(total)
    }
}
