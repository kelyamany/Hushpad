import Foundation
import HushpadKit
import Observation
import os

enum NotesJob: Equatable {
    case condensing(part: Int, of: Int)
    case thinking
    case writing
    case failed(String)

    var isRunning: Bool { if case .failed = self { false } else { true } }
}

/// Writes meeting notes in the background and publishes progress per meeting: one job each, streamed draft,
/// cancel. It knows nothing about settings or the library; `AppModel` builds the generator and decides where the
/// finished notes go.
@Observable
final class NotesService {
    private(set) var jobs: [UUID: NotesJob] = [:]
    /// The notes as they stream in, before they're saved.
    private(set) var drafts: [UUID: String] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    func isRunning(_ id: UUID) -> Bool { jobs[id]?.isRunning == true }

    /// Starts (or restarts) the job for `id`. `save` stores the finished notes (and any suggested title); `finished` runs afterwards.
    func generate(id: UUID, title: String, generator: NotesGenerator, input: NotesInput,
                  save: @escaping (GeneratedNotes) throws -> Void, finished: @escaping () -> Void) {
        tasks[id]?.cancel()
        jobs[id] = .writing
        drafts[id] = ""
        #if os(iOS)
        // Keeps writing if the user locks the phone, with system progress UI.
        BackgroundWork.shared.begin(id: id, kind: .notes, title: "Writing notes", subtitle: title) { [weak self] in
            self?.tasks[id]?.cancel()
            self?.jobs[id] = .failed("Stopped because the app was in the background too long. Open the app and try again.")
        }
        #endif
        tasks[id] = Task {
            var success = false
            defer {
                #if os(iOS)
                BackgroundWork.shared.finish(id: id, kind: .notes, success: success)
                #endif
                tasks[id] = nil
            }
            do {
                let generated = try await generator.generate(input) { [weak self] progress in
                    switch progress {
                    case .condensing(let part, let total):
                        Task { @MainActor in self?.jobs[id] = .condensing(part: part, of: total) }
                    case .thinking:
                        Task { @MainActor in self?.jobs[id] = .thinking }
                    case .writing(let text):
                        Task { @MainActor in
                            self?.jobs[id] = .writing
                            self?.drafts[id] = text
                        }
                    }
                }
                try save(generated)
                jobs[id] = nil
                drafts[id] = nil
                success = true
                finished()
            } catch is CancellationError {
                if jobs[id]?.isRunning == true { jobs[id] = nil }
                drafts[id] = nil
            } catch {
                drafts[id] = nil
                jobs[id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    /// The meeting was deleted: drop its job and draft.
    func forget(_ id: UUID) {
        tasks[id]?.cancel()
        jobs[id] = nil
        drafts[id] = nil
    }
}
