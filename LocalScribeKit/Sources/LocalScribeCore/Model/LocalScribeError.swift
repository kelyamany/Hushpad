import Foundation

public enum LocalScribeError: LocalizedError {
    case modelNotLoaded
    case audioUnavailable(String)
    case permissionDenied(String)
    case llm(String)
    case importFailed(String)
    /// The meeting was deleted (maybe on another device) while something was still writing to it.
    case recordingGone
    /// The library is encrypted and this device doesn't have the key.
    case libraryLocked
    /// The key doesn't open this file (a different library's key, or the file was changed).
    case wrongKey
    case damagedFile
    /// Exporting notes before any were generated.
    case noNotes

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The transcription model is not loaded."
        case .audioUnavailable(let detail): "Audio unavailable: \(detail)"
        case .permissionDenied(let what): "Permission needed: \(what)"
        case .llm(let detail): "Notes model error: \(detail)"
        case .importFailed(let detail): "Import failed: \(detail)"
        case .recordingGone: "This meeting was deleted."
        case .libraryLocked: "This library is encrypted. Enter your Recovery Key in Settings › Privacy to open it on this device."
        case .wrongKey: "This file can't be opened with this library's key."
        case .damagedFile: "This file is damaged."
        case .noNotes: "There are no generated notes to export yet."
        }
    }
}
