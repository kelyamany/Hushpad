import Foundation
import HushpadKit
import HushpadUI

/// Generated meeting notes (the work happens in `NotesService`).
extension AppModel {
    var notesJobs: [UUID: NotesJob] { notes.jobs }
    var notesDrafts: [UUID: String] { notes.drafts }

    func activeTranscript(for recording: Recording) -> Transcript? {
        let all = transcripts(for: recording)
        return all.first { $0.engine == recording.activeEngine } ?? all.last
    }

    func generateNotes(for recording: Recording, template: NoteTemplate? = nil) {
        guard let client = settings.notesClient() else {
            errorMessage = settings.notesUnavailableReason
            return
        }
        let folder = recording.folderID.flatMap { id in folders.first { $0.id == id } }
        let id = recording.id
        let input = NotesInput(recording: recording, transcript: activeTranscript(for: recording),
                               myNotes: myNotes(for: recording), screenshots: screenshots(for: recording))
        let generator = NotesGenerator(client: client, template: template ?? settings.template,
                                       instructions: settings.notesInstructions(folder: folder).text,
                                       notesLanguage: recording.notesLanguage,
                                       includeTranscript: settings.notesIncludeTranscript,
                                       maskNames: settings.notesProvider.isCloud && settings.cloudMaskNames)
        let store = self.store
        notes.generate(id: id, title: recording.title, generator: generator, input: input,
                       save: { generated in
                           try store.saveNotes(generated.document, for: id, .enhanced)
                           // Re-read first: if the meeting was renamed while the notes were being written, keep that name.
                           if let title = generated.title, var current = store.recording(id: id), current.hasDefaultTitle {
                               current.title = title
                               try store.save(current)
                           }
                       },
                       finished: { [weak self] in
                           self?.refresh(id)
                           self?.protectFinished(id)
                       })
    }

    func cancelNotes(for recording: Recording) {
        notes.cancel(recording.id)
    }

    func saveEnhancedNotes(_ text: String, for recording: Recording) {
        do { try store.saveNotes(text, for: recording.id, .enhanced) } catch { errorMessage = "Couldn't save the notes: \(error.localizedDescription)" }
    }

    /// Writes `<Title>.md` plus a `<Title> assets` folder with the screenshots, ready to drop into an Obsidian vault.
    func exportNotes(_ recording: Recording, to directory: URL) throws -> URL {
        guard var text = enhancedNotes(for: recording) else { throw HushpadError.noNotes }
        let name = RecordingStore.sanitize(recording.title)
        let shots = screenshots(for: recording)
        if !shots.isEmpty {
            let assets = directory.appendingPathComponent("\(name) assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            for shot in shots {
                let destination = assets.appendingPathComponent(shot.url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: shot.url, to: destination)
            }
            let encoded = "\(name) assets".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "assets"
            text = text.replacingOccurrences(of: "](screens/", with: "](\(encoded)/")
        }
        let url = directory.appendingPathComponent("\(name).md")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
