import Foundation

/// A Whisper model that WhisperKit can run, either from Argmax's repo or a custom Hugging Face repo.
public struct WhisperModel: Codable, Hashable, Sendable, Identifiable {
    public var variant: String
    public var repo: String
    public var displayName: String
    public var approxSizeMB: Int?
    public var note: String?

    public var id: String { "\(repo)/\(variant)" }
    public var engineIdentifier: String { "whisperkit:\(repo == ModelCatalog.argmaxRepo ? "" : repo + "/")\(variant)" }

    public init(variant: String, repo: String = ModelCatalog.argmaxRepo, displayName: String, approxSizeMB: Int? = nil, note: String? = nil) {
        self.variant = variant
        self.repo = repo
        self.displayName = displayName
        self.approxSizeMB = approxSizeMB
        self.note = note
    }
}

public enum ModelCatalog {
    public static let argmaxRepo = "argmaxinc/whisperkit-coreml"

    /// Curated list. All support English, German and Arabic.
    public static let builtIn: [WhisperModel] = [
        WhisperModel(variant: "openai_whisper-large-v3-v20240930_turbo", displayName: "Large v3 Turbo",
                     approxSizeMB: 1600, note: "Best speed/quality balance on Mac"),
        WhisperModel(variant: "openai_whisper-large-v3", displayName: "Large v3",
                     approxSizeMB: 3100, note: "Most accurate, slower. Best for Arabic"),
        WhisperModel(variant: "openai_whisper-large-v3-v20240930_turbo_632MB", displayName: "Large v3 Turbo (compressed)",
                     approxSizeMB: 632, note: "Recommended on iPhone"),
        WhisperModel(variant: "openai_whisper-large-v3-v20240930_626MB", displayName: "Large v3 Turbo (compressed, GPU)",
                     approxSizeMB: 626),
        WhisperModel(variant: "openai_whisper-small", displayName: "Small",
                     approxSizeMB: 480, note: "Fast, lower accuracy"),
        WhisperModel(variant: "openai_whisper-base", displayName: "Base",
                     approxSizeMB: 145, note: "Fastest, for quick tests"),
    ]

    public static var platformDefault: WhisperModel {
        #if os(macOS)
        builtIn[0]
        #else
        builtIn[2]
        #endif
    }

    public static func model(withID id: String, custom: [WhisperModel] = []) -> WhisperModel? {
        (builtIn + custom).first { $0.id == id }
    }
}
