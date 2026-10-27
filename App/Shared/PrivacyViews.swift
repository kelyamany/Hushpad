import LocalScribeKit
import LocalScribeUI
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - App lock

extension View {
    /// Covers the window while the app is locked, and (on iPhone) hides it in the app switcher.
    func appLock() -> some View { modifier(AppLockModifier()) }
}

private struct AppLockModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.privacy.isLocked {
                    LockedCover()
                } else if model.settings.lockEnabled && scenePhase != .active {
                    // The app switcher snapshot shows this instead of your meetings.
                    #if os(iOS)
                    PrivacyCurtain()
                    #endif
                }
            }
            #if os(iOS)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: model.appDidEnterBackground()
                case .active: model.appDidBecomeActive()
                default: break
                }
            }
            #else
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                model.appDidEnterBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.appDidBecomeActive()
            }
            #endif
    }
}

private struct PrivacyCurtain: View {
    var body: some View {
        Rectangle().fill(.regularMaterial).ignoresSafeArea()
            .overlay { Image(systemName: "lock.fill").font(.displayLarge).foregroundStyle(.secondary) }
    }
}

private struct LockedCover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Hushpad is locked").font(.displaySmall)
                if model.isRecording {
                    Text("Recording continues in the background.").foregroundStyle(.secondary)
                }
                Button("Unlock with \(AppModel.biometryName)") { Task { await model.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(32)
        }
        .task { await model.unlock() }
        .accessibilityAddTraits(.isModal)
    }
}
