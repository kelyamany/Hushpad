#if os(iOS)
import BackgroundTasks
import UIKit

/// Lets work the user started (transcription, writing notes) keep running after they lock the phone or switch apps,
/// using iOS 26 continued-processing tasks (the system shows its own progress UI).
/// Falls back to a short background-time grant where continued processing isn't available.
@MainActor
final class BackgroundWork {
    static let shared = BackgroundWork()

    enum Kind: String {
        case transcribe, notes
        var name: String { self == .transcribe ? "Transcription" : "Writing notes" }
    }

    private var tasks: [String: BGContinuedProcessingTask] = [:]
    private var fallbacks: [String: UIBackgroundTaskIdentifier] = [:]
    private var pendingProgress: [String: Double] = [:]

    private func identifier(_ id: UUID, _ kind: Kind) -> String { "dev.hushpad.app.\(kind.rawValue).\(id.uuidString)" }

    func begin(id: UUID, kind: Kind, title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        let identifier = identifier(id, kind)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                task.progress.totalUnitCount = 100
                task.progress.completedUnitCount = Int64((self.pendingProgress[identifier] ?? 0) * 100)
                task.expirationHandler = { Task { @MainActor in onExpire() } }
                self.tasks[identifier] = task
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            guard registered else { throw CocoaError(.featureUnsupported) }
            try BGTaskScheduler.shared.submit(request)
        } catch {
            fallbacks[identifier] = UIApplication.shared.beginBackgroundTask(withName: kind.name) {
                Task { @MainActor in self.endFallback(identifier) }
            }
        }
    }

    func update(id: UUID, kind: Kind, fraction: Double, status: String?) {
        let identifier = identifier(id, kind)
        pendingProgress[identifier] = fraction
        guard let task = tasks[identifier] else { return }
        task.progress.completedUnitCount = Int64(min(1, max(0, fraction)) * 100)
        if let status { task.updateTitle(task.title, subtitle: status) }
    }

    func finish(id: UUID, kind: Kind, success: Bool) {
        let identifier = identifier(id, kind)
        pendingProgress[identifier] = nil
        tasks.removeValue(forKey: identifier)?.setTaskCompleted(success: success)
        endFallback(identifier)
    }

    private func endFallback(_ identifier: String) {
        guard let task = fallbacks.removeValue(forKey: identifier) else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}
#endif
