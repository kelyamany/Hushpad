import Foundation

/// Output of transcribing one audio track.
public struct EngineOutput: Sendable {
    public var words: [TimedWord]
    public var detectedLanguage: String?

    public init(words: [TimedWord], detectedLanguage: String?) {
        self.words = words
        self.detectedLanguage = detectedLanguage
    }
}

/// Anything that turns an audio file into timed words. Local engines and the optional cloud engine conform.
public protocol TranscriptionEngine: Sendable {
    /// Stable id stored with each transcript, e.g. "whisperkit:openai_whisper-large-v3".
    var identifier: String { get }
    /// Transcribes `range` of the file (seconds), or all of it when nil. Word times are on the file's timeline.
    func transcribe(audioURL: URL, language: TranscriptLanguage, range: Range<Double>?) async throws -> EngineOutput
}

extension TranscriptionEngine {
    public func transcribe(audioURL: URL, language: TranscriptLanguage) async throws -> EngineOutput {
        try await transcribe(audioURL: audioURL, language: language, range: nil)
    }
}
