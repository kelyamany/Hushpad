#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// Live Activity shown on the Lock Screen and in the Dynamic Island while recording.
/// Compiled into both the app and the widget extension.
nonisolated struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The timer is rendered by the system from this date, so it ticks with the screen off
        /// without the app sending updates.
        var startedAt: Date
        var photoCount: Int = 0
        /// Lives in the state (not the fixed attributes) so a rename updates the activity in place.
        var title: String = ""
    }
}

/// Bridges intents (which can run while the app is in the background or not running) to the app's model.
/// The app sets these at launch; in the widget extension they stay nil and the system runs the intent in the app.
@MainActor
enum RecordingIntentBridge {
    static var start: (@MainActor () async -> Void)?
    static var stop: (@MainActor () async -> Void)?
}

/// Stop button on the Lock Screen / Dynamic Island. Runs in the app process without opening it.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the current Hushpad recording.")

    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.stop?()
        return .result()
    }
}

/// Start recording from Control Center, the Lock Screen, the Action button or Siri, without unlocking.
/// `AudioRecordingIntent` lets the app start the microphone from the background; it must start a Live Activity.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record Meeting"
    static let description = IntentDescription("Starts recording a meeting with Hushpad.")

    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.start?()
        return .result()
    }
}

#endif
