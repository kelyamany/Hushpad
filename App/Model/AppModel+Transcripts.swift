import Foundation
import HushpadKit
import HushpadUI

/// A meeting's transcripts and notes on disk, and speaker renames with undo.
extension AppModel {
    /// Renames a meeting; one being recorded is renamed in its session (it isn't in the library yet).
    func rename(_ recording: Recording, to title: String) {
        if session?.recording.id == recording.id {
            renameLiveRecording(title)
        } else {
            var updated = recording
            updated.title = title
            update(updated)
        }
    }

    func transcripts(for recording: Recording) -> [Transcript] { store.transcripts(for: recording.id) }

    func screenshots(for recording: Recording) -> [Screenshot] { ScreenshotStore.list(in: store.folder(for: recording.id)) }

    func myNotes(for recording: Recording) -> String { store.notes(for: recording.id, .mine) ?? "" }

    func enhancedNotes(for recording: Recording) -> String? { store.notes(for: recording.id, .enhanced) }

    func saveMyNotes(_ text: String, for recording: Recording) {
        // While recording, the meeting's folder is still in the staging area: notes go to the session, which saves
        // them with the recording.
        if session?.recording.id == recording.id {
            liveNotes = text
            return
        }
        do { try store.saveNotes(text, for: recording.id, .mine) } catch { errorMessage = "Couldn't save your notes: \(error.localizedDescription)" }
    }

    func save(_ transcript: Transcript, for recording: Recording) {
        do {
            try store.save(transcript, for: recording.id)
            refresh(recording.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Speakers

    struct SpeakerUndo: Identifiable {
        let id = UUID()
        let recordingID: UUID
        let previous: Transcript
        let message: String
        /// The generated notes still use the old speakers.
        let offerNotes: Bool
    }

    func renameSpeaker(_ speaker: Speaker, to name: String, in transcript: Transcript, recording: Recording) {
        var updated = transcript
        updated.renameSpeaker(speaker.key, to: name)
        commitSpeakerChange(updated, previous: transcript, recording: recording, message: nil)
    }

    /// Treats `speaker` as the same person as `target` in this transcript.
    func mergeSpeaker(_ speaker: Speaker, into target: Speaker, in transcript: Transcript, recording: Recording) {
        var updated = transcript
        updated.mergeSpeaker(speaker.key, into: target.key)
        commitSpeakerChange(updated, previous: transcript, recording: recording,
                            message: "Merged \(speaker.name) into \(target.name)")
    }

    func undoSpeakerChange() {
        guard let undo = speakerUndo, let recording = recordings.first(where: { $0.id == undo.recordingID }) else { return }
        speakerUndo = nil
        save(undo.previous, for: recording)
    }

    private func commitSpeakerChange(_ updated: Transcript, previous: Transcript, recording: Recording, message: String?) {
        save(updated, for: recording)
        guard let message else { return }
        speakerUndo = SpeakerUndo(recordingID: recording.id, previous: previous, message: message,
                                  offerNotes: enhancedNotes(for: recording) != nil && settings.notesUnavailableReason == nil)
    }
}
