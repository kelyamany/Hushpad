import Foundation
import HushpadKit
import HushpadUI

/// Bringing meetings in: merging two recordings, and Granola exports.
extension AppModel {
    // MARK: - Merging

    /// A recording can be merged unless it's being recorded or transcribed right now.
    func canMerge(_ recording: Recording) -> Bool {
        session?.recording.id != recording.id && jobs[recording.id]?.isActive != true && !notes.isRunning(recording.id)
    }

    /// Joins two meetings (in this order) into a new one. Optionally deletes the originals afterwards.
    func merge(first: Recording, second: Recording, title: String, deleteOriginals: Bool) async -> Recording? {
        guard canMerge(first), canMerge(second) else {
            errorMessage = "Wait until recording and transcription have finished before merging."
            return nil
        }
        let store = self.store
        let plan = RecordingMerger.Plan(first: first, second: second, title: title)
        do {
            // Copying audio can take a few seconds for long meetings; keep the UI responsive.
            let merged = try await Task.detached(priority: .userInitiated) { try RecordingMerger.merge(plan, in: store) }.value
            if deleteOriginals {
                delete(first)
                delete(second)
            }
            reload()
            sealNewFiles(merged.id)
            selection = merged.id
            openRequest = merged.id
            return merged
        } catch {
            errorMessage = "Couldn't merge: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Granola import

    /// Imports the chosen meetings; returns how many were new.
    @discardableResult
    func importGranola(_ meetings: [GranolaMeeting]) -> Int {
        do {
            let count = try GranolaImporter.importMeetings(meetings, into: store,
                                                           includeTranscriptInNotes: settings.notesIncludeTranscript)
            reload()
            sealNewFiles()
            if let first = meetings.first { selection = first.id }
            return count
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }
}
