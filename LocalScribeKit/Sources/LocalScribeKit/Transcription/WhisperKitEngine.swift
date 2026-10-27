import Foundation
import WhisperKit

/// Local transcription with WhisperKit (Core ML on the Neural Engine).
/// The model is downloaded once into Application Support; after that it loads with no network access.
public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let model: WhisperModel
    public nonisolated var identifier: String { model.engineIdentifier }

    private let modelsDirectory: URL
    // WhisperKit is not Sendable; the actor serialises every use of it.
    nonisolated(unsafe) private var whisperKit: WhisperKit?

    public init(model: WhisperModel, modelsDirectory: URL? = nil) throws {
        self.model = model
        self.modelsDirectory = try modelsDirectory ?? AppDirectories.models
    }

    /// Folder WhisperKit downloads this model into (`<base>/models/<repo>/<variant>`).
    public nonisolated var localFolder: URL {
        modelsDirectory.appendingPathComponent("models/\(model.repo)/\(model.variant)", isDirectory: true)
    }

    public nonisolated var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if whisperKit != nil { return }
        var folder = localFolder
        if !isDownloaded {
            folder = try await WhisperKit.download(
                variant: model.variant,
                downloadBase: modelsDirectory,
                from: model.repo,
                progressCallback: { progress?($0.fractionCompleted) }
            )
        }
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: modelsDirectory,
            computeOptions: Self.computeOptions,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    /// iOS forbids GPU work in the background, so on iPhone everything runs on the Neural Engine and CPU.
    /// That lets transcription continue after the user locks the phone (the mel stage is tiny on CPU).
    private static var computeOptions: ModelComputeOptions? {
        #if os(iOS)
        ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                            textDecoderCompute: .cpuAndNeuralEngine)
        #else
        nil
        #endif
    }

    public func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    public func transcribe(audioURL: URL, language: TranscriptLanguage, range: Range<Double>?) async throws -> EngineOutput {
        try await prepare()
        guard let whisperKit else { throw LocalScribeError.modelNotLoaded }

        let options = DecodingOptions(
            task: .transcribe,
            language: language.code,
            temperatureFallbackCount: 3,
            usePrefillPrompt: language.code != nil,
            detectLanguage: language.code == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            // VAD chunking skips silence and lets WhisperKit decode chunks in parallel.
            concurrentWorkerCount: ProcessInfo.processInfo.isiOSAppOnMac ? 4 : Self.defaultWorkers,
            chunkingStrategy: .vad
        )
        let results: [TranscriptionResult]
        let offset = range?.lowerBound ?? 0
        if let range {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path, startTime: range.lowerBound,
                                                                   endTime: range.upperBound)
            try Task.checkCancellation()
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        } else {
            results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        }

        var words: [TimedWord] = []
        for result in results {
            for segment in result.segments {
                if let segmentWords = segment.words, !segmentWords.isEmpty {
                    words += segmentWords.map { TimedWord(text: $0.word, start: offset + Double($0.start), end: offset + Double($0.end),
                                                          probability: Double($0.probability)) }
                } else {
                    let text = Self.stripSpecialTokens(segment.text)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        words.append(TimedWord(text: " " + text, start: offset + Double(segment.start), end: offset + Double(segment.end)))
                    }
                }
            }
        }
        // Whisper can emit timestamps past the end of the file when it hallucinates on trailing silence.
        let audioDuration = range?.upperBound ?? AudioInfo.duration(of: audioURL)
        words = words.filter {
            !Self.stripSpecialTokens($0.text).trimmingCharacters(in: .whitespaces).isEmpty
                && (audioDuration == 0 || $0.start < audioDuration)
        }
        return EngineOutput(words: words, detectedLanguage: results.first?.language)
    }

    private static var defaultWorkers: Int {
        // Fewer parallel decoders than the Neural Engine could take: transcription runs while you work, and stays
        // light enough not to slow the Mac down.
        #if os(macOS)
        4
        #else
        2
        #endif
    }

    static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
    }
}
