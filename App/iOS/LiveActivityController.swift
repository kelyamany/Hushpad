#if os(iOS)
import ActivityKit
import Foundation

/// Lock Screen / Dynamic Island presence while recording. The timer is rendered by the system from the
/// start date, so it keeps ticking with the screen off and the app never needs to push updates.
@MainActor
enum LiveActivityController {
    private static var current: Activity<RecordingActivityAttributes>?
    private static var startedAt = Date()
    private static var photoCount = 0

    static func start(title: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        Self.startedAt = startedAt
        let state = RecordingActivityAttributes.ContentState(startedAt: startedAt, title: title)
        do {
            current = try Activity.request(attributes: RecordingActivityAttributes(),
                                           content: .init(state: state, staleDate: nil))
        } catch {
            current = nil
        }
    }

    /// The title is part of the content state, so a rename updates the running activity in place.
    static func update(title: String?) {
        guard let title, current != nil else { return }
        let state = RecordingActivityAttributes.ContentState(startedAt: startedAt, photoCount: photoCount, title: title)
        Task { await push(state) }
    }

    private nonisolated static func push(_ state: RecordingActivityAttributes.ContentState) async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    static func end() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        current = nil
    }
}
#endif
