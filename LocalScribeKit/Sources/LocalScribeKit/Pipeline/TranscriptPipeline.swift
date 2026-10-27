import Foundation

public struct PipelineOptions: Sendable {
    public var language: TranscriptLanguage
    /// Optional hint for how many people are in the room / on the call. nil = detect automatically.
    public var roomSpeakers: Int?
    public var remoteSpeakers: Int?

    public init(language: TranscriptLanguage, roomSpeakers: Int? = nil, remoteSpeakers: Int? = nil) {
        self.language = language
        self.roomSpeakers = roomSpeakers
        self.remoteSpeakers = remoteSpeakers
    }
}

public enum PipelineStage: Sendable, Equatable {
    case preparingModels
    /// How much of the speech is transcribed, 0…1 (resumed parts count as done).
    case transcribing(fraction: Double)
    case separatingSpeakers
    case merging
    case done
}

/// Saves and restores transcription progress so a paused job resumes where it stopped.
public struct TranscriptionCheckpoint: Sendable {
    public var load: @Sendable () -> PartialTranscript?
    public var save: @Sendable (PartialTranscript) -> Void

    public init(load: @escaping @Sendable () -> PartialTranscript?, save: @escaping @Sendable (PartialTranscript) -> Void) {
        self.load = load
        self.save = save
    }
}

/// Record → transcribe each track (in resumable parts) → separate speakers → align words to speakers → one transcript.
public struct TranscriptPipeline: Sendable {
    public let engine: any TranscriptionEngine
    public let diarizer: any Diarizing

    public init(engine: any TranscriptionEngine, diarizer: any Diarizing) {
        self.engine = engine
        self.diarizer = diarizer
    }

    public func run(
        tracks: AudioTracks,
        options: PipelineOptions,
        checkpoint: TranscriptionCheckpoint? = nil,
        progress: @escaping @Sendable (PipelineStage) -> Void = { _ in }
    ) async throws -> Transcript {
        // Transcription first, part by part, saving each part; speaker separation once at the end. One heavy model at
        // a time keeps the device usable, and a pause loses at most the part in progress.
        var partial = checkpoint?.load().flatMap { $0.engine == engine.identifier && $0.language == options.language ? $0 : nil }
            ?? PartialTranscript(engine: engine.identifier, language: options.language)
        let named = [("system", tracks.system), ("mic", tracks.mic)].compactMap { key, url in url.map { (key, $0) } }
        for (key, url) in named where partial.plans[key] == nil {
            partial.plans[key] = try AudioChunks.plan(url: url)
        }
        progress(.transcribing(fraction: partial.fraction))

        var output: [String: EngineOutput] = [:]
        for (key, url) in named {
            let plan = partial.plans[key] ?? []
            for (index, range) in plan.enumerated() where !(partial.parts[key] ?? []).contains(where: { $0.index == index }) {
                try Task.checkCancellation()
                let part = try await engine.transcribe(audioURL: url, language: options.language, range: plan.count == 1 ? nil : range)
                partial.parts[key, default: []].append(.init(index: index, words: part.words, detectedLanguage: part.detectedLanguage))
                checkpoint?.save(partial)
                progress(.transcribing(fraction: partial.fraction))
            }
            let parts = (partial.parts[key] ?? []).sorted { $0.index < $1.index }
            output[key] = EngineOutput(words: parts.flatMap(\.words), detectedLanguage: parts.first { $0.detectedLanguage != nil }?.detectedLanguage)
        }
        try Task.checkCancellation()

        let systemWords = (output["system"]?.words ?? []).map { shifted($0, by: tracks.systemOffset) }
        var micWords = SpeakerAligner.removeEcho(micWords: output["mic"]?.words ?? [], systemWords: systemWords)
        var systemAligned = systemWords
        let detected = output["system"]?.detectedLanguage ?? output["mic"]?.detectedLanguage

        progress(.separatingSpeakers)
        let roomTurns = try await diarizeIfPresent(tracks.mic, speakers: options.roomSpeakers)
        let remoteTurns = try await diarizeIfPresent(tracks.system, speakers: options.remoteSpeakers).map { shifted($0, by: tracks.systemOffset) }

        progress(.merging)
        micWords = SpeakerAligner.dropNonSpeech(words: micWords, turns: roomTurns)
        systemAligned = SpeakerAligner.dropNonSpeech(words: systemAligned, turns: remoteTurns)
        let room = SpeakerAligner.normalizeSpeakerKeys(
            SpeakerAligner.utterances(from: SpeakerAligner.assign(words: micWords, turns: roomTurns)), prefix: "R")
        let remote = SpeakerAligner.normalizeSpeakerKeys(
            SpeakerAligner.utterances(from: SpeakerAligner.assign(words: systemAligned, turns: remoteTurns)), prefix: "S")

        let utterances = SpeakerAligner.merge([room, remote])
        let transcript = Transcript(
            language: options.language,
            detectedLanguage: detected,
            speakers: Self.speakers(room: room, remote: remote),
            utterances: utterances,
            engine: engine.identifier
        )
        progress(.done)
        return transcript
    }

    /// Default names: a lone room voice on a call is almost certainly you.
    static func speakers(room: [Utterance], remote: [Utterance]) -> [Speaker] {
        func keys(_ list: [Utterance]) -> [String] {
            var seen: [String] = []
            for key in list.map(\.speaker) where !seen.contains(key) { seen.append(key) }
            return seen
        }
        let roomKeys = keys(room), remoteKeys = keys(remote)
        var result: [Speaker] = []
        for (index, key) in roomKeys.enumerated() where key != SpeakerAligner.unknownSpeaker {
            let name: String
            if roomKeys.count == 1 && !remoteKeys.isEmpty { name = "Me" }
            else if remoteKeys.isEmpty { name = "Speaker \(index + 1)" }
            else { name = "Room \(index + 1)" }
            result.append(Speaker(key: key, name: name))
        }
        for (index, key) in remoteKeys.enumerated() where key != SpeakerAligner.unknownSpeaker {
            result.append(Speaker(key: key, name: "Remote \(index + 1)"))
        }
        if (roomKeys + remoteKeys).contains(SpeakerAligner.unknownSpeaker) {
            result.append(Speaker(key: SpeakerAligner.unknownSpeaker, name: "Unknown"))
        }
        return result
    }

    private func diarizeIfPresent(_ url: URL?, speakers: Int?) async throws -> [SpeakerTurn] {
        guard let url else { return [] }
        return try await diarizer.diarize(audioURL: url, expectedSpeakers: speakers)
    }

    private func shifted(_ word: TimedWord, by offset: Double) -> TimedWord {
        TimedWord(text: word.text, start: word.start + offset, end: word.end + offset)
    }

    private func shifted(_ turn: SpeakerTurn, by offset: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: turn.speaker, start: turn.start + offset, end: turn.end + offset)
    }
}
