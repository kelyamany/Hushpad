@preconcurrency import AVFoundation
import Foundation
import Observation
import os
import Speech

/// One caption line while recording.
public struct LiveLine: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        /// The room microphone: you (and anyone in the room).
        case microphone
        /// Call audio (Mac): the other side.
        case call
    }

    public var source: Source
    /// Seconds on the recording's timeline.
    public var start: Double
    public var end: Double
    public var text: String
    /// False while the recogniser may still revise it.
    public var isFinal: Bool

    public var id: String { "\(source.rawValue)-\(start)" }

    public init(source: Source, start: Double, end: Double, text: String, isFinal: Bool) {
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
    }
}

/// Captions for the recording in progress, for the UI. Updated on the main actor.
@MainActor @Observable
public final class LiveTranscript {
    public enum Status: Equatable, Sendable {
        case preparing
        /// Apple's speech model for this language is being downloaded (once; no audio is sent).
        case downloading
        case listening
        case unavailable(String)
    }

    public private(set) var status: Status = .preparing
    /// Settled lines in time order.
    public private(set) var finals: [LiveLine] = []
    /// The line still being recognised, per source.
    public private(set) var pending: [LiveLine.Source: LiveLine] = [:]
    /// When speech was last recognised, to tell a quiet room from a meeting in progress.
    @ObservationIgnored public private(set) var lastHeard: Date?

    public init() {}

    /// The last `count` words heard, for checking how the meeting ended.
    public func lastWords(_ count: Int) -> String {
        lines.suffix(count).map(\.text).joined(separator: " ")
            .split(separator: " ").suffix(count).joined(separator: " ")
    }

    /// Everything so far in time order, settled lines first and the lines still forming at the end.
    public var lines: [LiveLine] {
        finals + pending.values.sorted { $0.start < $1.start }
    }

    /// The latest line, for the caption bubble.
    public var latest: LiveLine? {
        lines.max { $0.end < $1.end }
    }

    func setStatus(_ status: Status) { self.status = status }

    func apply(_ line: LiveLine) {
        if !line.text.isEmpty { lastHeard = Date() }
        if line.isFinal {
            pending[line.source] = nil
            guard !line.text.isEmpty else { return }
            // Keep `finals` sorted; lines almost always arrive in order, so this is usually an append.
            let index = finals.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
            finals.insert(line, at: index)
        } else {
            pending[line.source] = line.text.isEmpty ? nil : line
        }
    }

    func finish() { pending = [:] }

    /// The captions as a transcript, so notes and questions work before the full transcript is ready.
    public func transcript(language: TranscriptLanguage) -> Transcript? {
        guard !finals.isEmpty else { return nil }
        let speakers = Set(finals.map(\.source))
        return Transcript(
            language: language,
            speakers: LiveLine.Source.allCases.filter(speakers.contains).map { Speaker(key: $0.rawValue, name: $0.speakerName) },
            utterances: finals.map { Utterance(speaker: $0.source.rawValue, start: $0.start, end: $0.end, text: $0.text) },
            engine: LiveTranscriber.engineID)
    }
}

extension LiveLine.Source {
    /// How captions label each side: "You" for the microphone, "Them" for the call.
    public var speakerName: String {
        switch self {
        case .microphone: "You"
        case .call: "Them"
        }
    }
}

extension Transcript {
    /// True for the quick transcript saved from live captions (replaced by the full one when it's ready).
    public var isLive: Bool { engine == LiveTranscriber.engineID }
}

/// Live captions with Apple's on-device speech recogniser (SpeechAnalyzer). Audio never leaves the device: the only
/// network use is downloading Apple's speech model for a language the first time.
///
/// Each recorded track gets its own analyzer, fed from `TrackWriter.onAudio` through a small, bounded queue, so a slow
/// recogniser can never hold up the recording. The final transcript is still made by the full pipeline after stopping.
public final class LiveTranscriber: Sendable {
    public static let engineID = "apple:live"

    @MainActor public let transcript = LiveTranscript()
    private let language: TranscriptLanguage
    private let feeds: [LiveLine.Source: Feed]
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
    private let analyzers = OSAllocatedUnfairLock<[SpeechAnalyzer]>(initialState: [])

    @MainActor
    public init(language: TranscriptLanguage, sources: [LiveLine.Source]) {
        self.language = language
        feeds = Dictionary(uniqueKeysWithValues: sources.map { ($0, Feed()) })
    }

    /// The function to install as a track's `onAudio`. Drops audio until the recogniser is ready.
    public func sink(for source: LiveLine.Source) -> @Sendable (AVAudioPCMBuffer, Double) -> Void {
        guard let feed = feeds[source] else { return { _, _ in } }
        return { buffer, start in feed.push(buffer, start: start) }
    }

    /// Prepares the recogniser (downloading the language once if needed) and starts captioning.
    public func start() {
        let task = Task.detached(priority: .utility) { [self] in await run() }
        tasks.withLock { $0.append(task) }
    }

    /// Stops listening and settles the last lines. Safe to call more than once.
    public func stop() async {
        feeds.values.forEach { $0.finish() }
        for analyzer in analyzers.withLock({ $0 }) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let running = tasks.withLock { tasks in defer { tasks = [] }; return tasks }
        for task in running { await task.value }
        await MainActor.run { transcript.finish() }
    }

    // MARK: Private

    private func run() async {
        guard SpeechTranscriber.isAvailable else {
            return await setStatus(.unavailable("Live captions aren't available on this device."))
        }
        // Prefer this Mac's regional variant when it's the same language ("en" → "en_GB" for a UK Mac).
        let current = Locale.current
        let wanted = language.code.map { code in
            current.language.languageCode?.identifier == code ? current : Locale(identifier: code)
        } ?? current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            let name = language == .auto ? Locale.current.localizedString(forLanguageCode: wanted.language.languageCode?.identifier ?? "") ?? "this language"
                                         : language.displayName
            return await setStatus(.unavailable("Live captions aren't available in \(name). The full transcript is made when you stop."))
        }
        do {
            let probe = Self.module(locale)
            if await AssetInventory.status(forModules: [probe]) < .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                await setStatus(.downloading)
                try await request.downloadAndInstall()
            }
            _ = try await AssetInventory.reserve(locale: locale)
            for (source, feed) in feeds {
                let module = Self.module(locale)
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { continue }
                let analyzer = SpeechAnalyzer(modules: [module])
                analyzers.withLock { $0.append(analyzer) }
                let stream = feed.open(format: format)
                let results = Task.detached(priority: .utility) { [self] in await collect(module, source: source) }
                tasks.withLock { $0.append(results) }
                try await analyzer.start(inputSequence: stream)
            }
            await setStatus(.listening)
        } catch {
            await setStatus(.unavailable("Live captions stopped: \(String(describing: error))"))
        }
    }

    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    private func collect(_ module: SpeechTranscriber, source: LiveLine.Source) async {
        do {
            for try await result in module.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let line = LiveLine(source: source, start: result.range.start.seconds,
                                    end: result.range.end.seconds, text: text, isFinal: result.isFinal)
                await MainActor.run { transcript.apply(line) }
            }
        } catch {
            // The analyzer ended (stopped, or failed); the captions so far stay.
        }
    }

    private func setStatus(_ status: LiveTranscript.Status) async {
        await MainActor.run { transcript.setStatus(status) }
    }
}

/// Converts one track's 16 kHz audio to the recogniser's format and hands it over. Bounded (about 100 s): if the
/// recogniser ever falls that far behind, the oldest audio is dropped from the captions (never from the recording).
private final class Feed: @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var converter: AVAudioConverter?
        var format: AVAudioFormat?
        var finished = false
        /// Seconds of audio handed to the recogniser so far; its results are timed from the first of them.
        var fed: Double?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func open(format: AVAudioFormat) -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(1_000))
        state.withLock { state in
            if state.finished {
                continuation.finish()
            } else {
                state.continuation = continuation
                state.format = format
            }
        }
        return stream
    }

    /// Called on the track writer's queue. The recogniser rejects explicit timestamps on a live stream, so it gets one
    /// continuous stream instead: audio from before it was ready, or skipped while paused, becomes silence. That keeps
    /// caption times on the recording's timeline.
    func push(_ buffer: AVAudioPCMBuffer, start: Double) {
        state.withLock { state in
            guard let continuation = state.continuation, let format = state.format else { return }
            let gap = start - (state.fed ?? 0)
            // Long pauses are shortened to 30 s of silence: captions after one are then a little early, which only
            // matters until the full transcript replaces them.
            if gap > 0.05, let silence = Self.silence(seconds: min(gap, 30), format: format) {
                silence.forEach { continuation.yield(AnalyzerInput(buffer: $0)) }
            }
            state.fed = max(state.fed ?? 0, start) + Double(buffer.frameLength) / buffer.format.sampleRate
            let input: AVAudioPCMBuffer
            if buffer.format == format {
                input = buffer
            } else {
                if state.converter == nil { state.converter = AVAudioConverter(from: buffer.format, to: format) }
                guard let converter = state.converter, let converted = Self.convert(buffer, with: converter, to: format) else { return }
                input = converted
            }
            continuation.yield(AnalyzerInput(buffer: input))
        }
    }

    func finish() {
        state.withLock { state in
            state.finished = true
            state.continuation?.finish()
            state.continuation = nil
        }
    }

    /// Silence in one-second buffers (zeroed on creation).
    private static func silence(seconds: Double, format: AVAudioFormat) -> [AVAudioPCMBuffer]? {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        var buffers: [AVAudioPCMBuffer] = []
        let second = AVAudioFrameCount(format.sampleRate)
        while remaining > 0 {
            let count = min(remaining, second)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
            buffer.frameLength = count
            let audio = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for channel in audio where channel.mData != nil { memset(channel.mData, 0, Int(channel.mDataByteSize)) }
            buffers.append(buffer)
            remaining -= count
        }
        return buffers
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
