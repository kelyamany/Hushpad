import Foundation
import Testing
@testable import HushpadCore
@testable import HushpadKit

// MARK: - Helpers

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a 16 kHz mono WAV: a steady tone, except zeros inside `silentRange` (seconds).
private func writeWAV(_ url: URL, seconds: Double, silentRange: Range<Double>? = nil) throws {
    let rate = 16_000
    let samples: [Int16] = (0..<Int(seconds * Double(rate))).map { index in
        let time = Double(index) / Double(rate)
        if let silentRange, silentRange.contains(time) { return 0 }
        return Int16(sin(Double(index) * 0.05) * 8000)
    }
    let file = try WAVFile(url: url, sampleRate: rate)
    try file.append(samples)
    try file.close()
}

/// Thread-safe collector for checkpoint saves.
private final class PartialSink: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [PartialTranscript] = []

    func add(_ partial: PartialTranscript) {
        lock.withLock { saved.append(partial) }
    }

    var all: [PartialTranscript] {
        lock.withLock { saved }
    }
}

/// Transcription engine that records the ranges it was asked for and returns one word per range.
/// Optionally throws `CancellationError` on the given (1-based) call.
private actor ScriptedEngine: TranscriptionEngine {
    nonisolated let identifier: String
    private let throwOnCall: Int?
    private(set) var requested: [Range<Double>?] = []

    init(identifier: String = "scripted", throwOnCall: Int? = nil) {
        self.identifier = identifier
        self.throwOnCall = throwOnCall
    }

    func transcribe(audioURL: URL, language: TranscriptLanguage, range: Range<Double>?) async throws -> EngineOutput {
        requested.append(range)
        if requested.count == throwOnCall { throw CancellationError() }
        let start = range?.lowerBound ?? 0
        let word = TimedWord(text: " at\(Int(start))", start: start, end: start + 0.5)
        return EngineOutput(words: [word], detectedLanguage: "en")
    }
}

/// Diarizer that finds no speakers, so every word is kept by the pipeline as-is.
private struct NoTurnsDiarizer: Diarizing {
    func diarize(audioURL: URL, expectedSpeakers: Int?) async throws -> [SpeakerTurn] { [] }
}

// MARK: - AudioChunks

@Suite struct AudioChunksTests {
    @Test func rangesAreContiguousFromZeroToDuration() {
        let ranges = AudioChunks.ranges(cuts: [3, 6], duration: 10)
        #expect(ranges == [0..<3, 3..<6, 6..<10])
    }

    @Test func rangesWithNoCutsIsOneRange() {
        #expect(AudioChunks.ranges(cuts: [], duration: 5) == [0..<5])
    }

    @Test func rangesIgnoreCutsAtOrOutsideTheEdges() {
        // 0, negative, equal to duration, and beyond duration are all dropped.
        let ranges = AudioChunks.ranges(cuts: [0, -1, 10, 12], duration: 10)
        #expect(ranges == [0..<10])
    }

    @Test func rangesSortUnsortedCuts() {
        #expect(AudioChunks.ranges(cuts: [6, 3], duration: 10) == [0..<3, 3..<6, 6..<10])
    }

    @Test func quietestPicksTheMinimum() {
        #expect(AudioChunks.quietest([3, 1, 2]) == 1)
        #expect(AudioChunks.quietest([0.5, 0.2, 0.9, 0.7]) == 1)
    }

    @Test func quietestTieGoesToIndexNearestMiddle() {
        // Count 5, middle index 2. Zeros at 1, 2, 3: index 2 is nearest the middle.
        #expect(AudioChunks.quietest([1, 0, 0, 0, 1]) == 2)
        // Count 4, middle index 2. Zeros at 0 and 2: index 2 is nearest the middle.
        #expect(AudioChunks.quietest([0, 1, 0, 1]) == 2)
    }

    @Test func quietestOfEmptyIsZero() {
        #expect(AudioChunks.quietest([]) == 0)
    }

    @Test func planOfShortFileIsOneRangeCoveringIt() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("short.wav")
        try writeWAV(url, seconds: 10)

        let ranges = try AudioChunks.plan(url: url)
        #expect(ranges == [0..<10])
    }

    @Test func planCutsAtTheSilentGapNearTheMark() throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("gap.wav")
        // Tone everywhere except 2.8 s to 3.2 s, which is silent.
        try writeWAV(url, seconds: 10, silentRange: 2.8..<3.2)

        let ranges = try AudioChunks.plan(url: url, target: 3, search: 1)

        #expect(ranges.count >= 2)
        // The first cut lands inside the silent gap.
        let firstCut = try #require(ranges.first?.upperBound)
        #expect((2.8...3.2).contains(firstCut))
        // Contiguous, and covering the whole file.
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == 10)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
    }
}

// MARK: - PartialTranscript

@Suite struct PartialTranscriptFractionTests {
    @Test func fractionIsZeroWithoutPlans() {
        let partial = PartialTranscript(engine: "e", language: .english)
        #expect(partial.fraction == 0)
    }

    @Test func fractionIsDoneOverTotal() {
        var partial = PartialTranscript(engine: "e", language: .english)
        partial.plans["mic"] = [0..<3, 3..<6, 6..<10]
        partial.plans["system"] = [0..<10]
        #expect(partial.fraction == 0)

        // One of three mic parts done.
        partial.parts["mic"] = [.init(index: 0, words: [], detectedLanguage: nil)]
        #expect(partial.fraction == 0.25)

        // Plus the system part: 2 of 4.
        partial.parts["system"] = [.init(index: 0, words: [], detectedLanguage: nil)]
        #expect(partial.fraction == 0.5)
    }
}

// MARK: - Resumable pipeline

@Suite struct ResumableTranscriptionTests {
    private let micPlan: [Range<Double>] = [0..<3, 3..<6, 6..<10]

    /// A partial with the mic plan and part 0 already done, using the given engine id.
    private func seededPartial(engine: String) -> PartialTranscript {
        var partial = PartialTranscript(engine: engine, language: .english)
        partial.plans["mic"] = micPlan
        partial.parts["mic"] = [.init(index: 0, words: [TimedWord(text: " first", start: 0.2, end: 0.6)],
                                      detectedLanguage: "en")]
        return partial
    }

    @Test func resumeSkipsDonePartsAndSavesEachNewPart() async throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.wav")
        try writeWAV(mic, seconds: 10)

        let seeded = seededPartial(engine: "scripted")
        let sink = PartialSink()
        let checkpoint = TranscriptionCheckpoint(load: { seeded }, save: { sink.add($0) })
        let engine = ScriptedEngine()
        let pipeline = TranscriptPipeline(engine: engine, diarizer: NoTurnsDiarizer())

        let transcript = try await pipeline.run(
            tracks: AudioTracks(mic: mic, system: nil),
            options: PipelineOptions(language: .english),
            checkpoint: checkpoint
        )

        // Only the two remaining parts were transcribed.
        #expect(await engine.requested == [3..<6, 6..<10])

        // Saved once after each new part, growing each time.
        let saved = sink.all
        #expect(saved.count == 2)
        #expect(saved.map { $0.parts["mic"]?.count ?? 0 } == [2, 3])
        #expect(saved.map { $0.parts["mic"]?.map(\.index) ?? [] } == [[0, 1], [0, 1, 2]])

        // The final transcript has words from all three parts, in time order.
        let words = transcript.utterances.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(words == ["first", "at3", "at6"])
        #expect(transcript.engine == "scripted")
    }

    @Test func partialFromDifferentEngineIsIgnored() async throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.wav")
        try writeWAV(mic, seconds: 10)

        let seeded = seededPartial(engine: "some-other-engine")
        let sink = PartialSink()
        let checkpoint = TranscriptionCheckpoint(load: { seeded }, save: { sink.add($0) })
        let engine = ScriptedEngine()
        let pipeline = TranscriptPipeline(engine: engine, diarizer: NoTurnsDiarizer())

        let transcript = try await pipeline.run(
            tracks: AudioTracks(mic: mic, system: nil),
            options: PipelineOptions(language: .english),
            checkpoint: checkpoint
        )

        // Nothing is reused: the 10 s file is planned fresh as one part, transcribed in full, and the stale
        // "first" word from the other engine's partial is gone.
        #expect(await engine.requested == [nil])
        let words = transcript.utterances.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(words == ["at0"])
        #expect(sink.all.last?.engine == "scripted")
    }

    @Test func cancellationKeepsFinishedPartsAndThrows() async throws {
        let folder = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.wav")
        try writeWAV(mic, seconds: 10)

        // A fresh partial with the three-part mic plan and nothing done yet.
        let fresh: PartialTranscript = {
            var partial = PartialTranscript(engine: "scripted", language: .english)
            partial.plans["mic"] = micPlan
            return partial
        }()
        let sink = PartialSink()
        let checkpoint = TranscriptionCheckpoint(load: { fresh }, save: { sink.add($0) })
        // The engine throws on the second part it is asked to transcribe.
        let engine = ScriptedEngine(throwOnCall: 2)
        let pipeline = TranscriptPipeline(engine: engine, diarizer: NoTurnsDiarizer())

        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.run(
                tracks: AudioTracks(mic: mic, system: nil),
                options: PipelineOptions(language: .english),
                checkpoint: checkpoint
            )
        }

        // Only the first part was saved, and it is the one that finished.
        let saved = sink.all
        #expect(saved.count == 1)
        #expect(saved.last?.parts["mic"]?.map(\.index) == [0])
        #expect(saved.last?.plans["mic"] == micPlan)
        #expect(await engine.requested.count == 2)
    }
}
