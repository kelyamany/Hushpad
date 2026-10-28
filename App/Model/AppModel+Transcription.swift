import Foundation
import HushpadKit
import HushpadUI

/// Transcription jobs and speech models (the work happens in `TranscriptionQueue`).
extension AppModel {
    var jobs: [UUID: JobState] { queue.jobs }
    var modelDownloads: [String: Double] { queue.modelDownloads }
    /// Changes when a speech model is downloaded or deleted, so model lists refresh.
    var revision: Int { queue.revision }

    func transcribe(_ recording: Recording, with model: WhisperModel? = nil) { queue.transcribe(recording, with: model) }
    func pauseTranscription(_ recording: Recording) { queue.pause(recording.id) }
    /// How far a paused or interrupted transcription got (nil if there is none).
    func pausedTranscription(_ recording: Recording) -> Double? { queue.pausedFraction(for: recording.id) }

    /// Meetings with audio but no full transcript yet (live captions don't count), oldest first.
    var waitingForTranscript: [Recording] {
        recordings.filter { recording in
            summaries[recording.id]?.needsFullTranscript == true && session?.recording.id != recording.id
                && jobs[recording.id]?.isActive != true
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func transcribeAllWaiting() { waitingForTranscript.forEach { transcribe($0) } }
    func isDownloaded(_ model: WhisperModel) -> Bool { queue.isDownloaded(model) }
    var speakerModelDownloaded: Bool { queue.speakerModelDownloaded }
    var modelsReady: Bool { queue.modelsReady }
    func download(_ model: WhisperModel) async { await queue.download(model) }
    func downloadSpeakerModel() async { await queue.downloadSpeakerModel() }
    @discardableResult
    func deleteModel(_ model: WhisperModel) async -> Bool { await queue.deleteModel(model) }
}
