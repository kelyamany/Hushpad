#if os(iOS)
import AppIntents

/// Siri / Spotlight / Action button phrases. Only the app declares these (not the widget extension).
struct HushpadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(), phrases: ["Record a meeting with \(.applicationName)",
                                                               "Start \(.applicationName)"],
                    shortTitle: "Record Meeting", systemImageName: "waveform.circle.fill")
        AppShortcut(intent: StopRecordingIntent(), phrases: ["Stop \(.applicationName)"],
                    shortTitle: "Stop Recording", systemImageName: "stop.circle.fill")
    }
}
#endif
