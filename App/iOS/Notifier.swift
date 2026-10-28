#if os(iOS)
import HushpadKit
import UIKit
import UserNotifications

/// "Transcript ready" when a transcription finishes while you're in another app or the phone is locked.
@MainActor
enum Notifier {
    static func transcriptReady(for recording: Recording) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcript ready"
        content.body = recording.title
        content.sound = .default
        content.userInfo = ["recording": recording.id.uuidString]
        let request = UNNotificationRequest(identifier: recording.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
