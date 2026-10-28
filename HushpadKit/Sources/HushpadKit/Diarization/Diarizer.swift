import Foundation
import SpeakerKit
import WhisperKit

public protocol Diarizing: Sendable {
    func diarize(audioURL: URL, expectedSpeakers: Int?) async throws -> [SpeakerTurn]
}

/// Local speaker diarization with Argmax SpeakerKit (pyannote community-1 on Core ML).
public actor SpeakerKitDiarizer: Diarizing {
    private let modelsDirectory: URL
    private var speakerKit: SpeakerKit?

    public init(modelsDirectory: URL? = nil) throws {
        self.modelsDirectory = try modelsDirectory ?? AppDirectories.models
    }

    private var localFolder: URL {
        modelsDirectory.appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
    }

    public nonisolated var isDownloaded: Bool {
        let folder = modelsDirectory.appendingPathComponent("models/argmaxinc/speakerkit-coreml")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !contents.filter { !$0.hasPrefix(".") }.isEmpty
    }

    public func prepare() async throws {
        if speakerKit != nil { return }
        let downloaded = isDownloaded
        let config = PyannoteConfig(
            downloadBase: modelsDirectory.path,
            modelFolder: downloaded ? localFolder.path : nil,
            download: !downloaded,
            load: true,
            verbose: false,
            logLevel: .error
        )
        speakerKit = try await SpeakerKit(config)
    }

    public func diarize(audioURL: URL, expectedSpeakers: Int?) async throws -> [SpeakerTurn] {
        try await prepare()
        guard let speakerKit else { throw HushpadError.modelNotLoaded }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        let options = PyannoteDiarizationOptions(numberOfSpeakers: expectedSpeakers)
        let result = try await speakerKit.diarize(audioArray: audio, options: options)
        return result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return SpeakerTurn(speaker: String(id), start: Double(segment.startTime), end: Double(segment.endTime))
        }
    }
}
