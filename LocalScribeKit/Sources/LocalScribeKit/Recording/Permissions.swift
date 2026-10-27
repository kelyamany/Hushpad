import AVFoundation
import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#else
import UIKit
import UserNotifications
#endif

/// The permissions LocalScribe needs, per device:
/// - Mac: Microphone (the room / you), System Audio Recording (the call), Screen Recording (screenshots, optional).
/// - iPhone: Microphone (the room), Camera (photos of slides / whiteboard, optional).
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case microphone
    #if os(macOS)
    case systemAudio
    case screenRecording
    #else
    case camera
    case notifications
    #endif

    public var id: String { rawValue }

    public static var required: [Permission] { [.microphone] }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        #if os(macOS)
        case .systemAudio: "System audio"
        case .screenRecording: "Screen recording"
        #else
        case .camera: "Camera"
        case .notifications: "Notifications"
        #endif
        }
    }

    public var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        #if os(macOS)
        case .systemAudio: "speaker.wave.2.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        #else
        case .camera: "camera.fill"
        case .notifications: "bell.badge.fill"
        #endif
        }
    }

    public var isRequired: Bool { self == .microphone }

    public var purpose: String {
        switch self {
        case .microphone: "Records the people in the room, including you."
        #if os(macOS)
        case .systemAudio: "Records the other side of Zoom, Teams and Google Meet calls."
        case .screenRecording: "Optional. Takes screenshots when someone shares their screen."
        #else
        case .camera: "Optional. Snap the projector or whiteboard; photos are placed in the transcript."
        case .notifications: "Optional. Tells you when a transcript is ready while you're in another app."
        #endif
        }
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted, denied, notDetermined
    /// Allowed in System Settings, but macOS only applies it after LocalScribe restarts (screen recording).
    case needsRestart
    /// macOS doesn't say (system audio, when the private status check is unavailable); we only know we've asked.
    case unknown
}

@MainActor
public enum Permissions {
    private static let askedSystemAudioKey = "LocalScribe.askedSystemAudio"
    private static let askedScreenKey = "LocalScribe.askedScreenRecording"

    /// The current status, checked live every time (cheap system calls, no caching except notifications).
    public static func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            #if os(macOS)
            // The capture-device status is the one TCC enforces on the Mac; AVAudioApplication can lag behind it.
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
            #else
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .notDetermined
            }
            #endif
        #if os(macOS)
        case .systemAudio:
            return systemAudioStatus(tcc: TCC.preflight("kTCCServiceAudioCapture"),
                                     asked: UserDefaults.standard.bool(forKey: askedSystemAudioKey))
        case .screenRecording:
            return screenStatus(preflight: CGPreflightScreenCaptureAccess(), tcc: TCC.preflight("kTCCServiceScreenCapture"),
                                asked: UserDefaults.standard.bool(forKey: askedScreenKey))
        #else
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .notifications:
            return notificationStatus
        #endif
        }
    }

    static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    /// `tcc` is the system's own answer when available (true = allowed, false = denied, nil = not asked / unknown).
    nonisolated static func systemAudioStatus(tcc: Bool?, asked: Bool) -> PermissionStatus {
        switch tcc {
        case true?: .granted
        case false?: .denied
        case nil: asked ? .unknown : .notDetermined
        }
    }

    /// Screen recording: the process only gets access after a restart, so "allowed in Settings but not yet
    /// in this process" is its own state.
    nonisolated static func screenStatus(preflight: Bool, tcc: Bool?, asked: Bool) -> PermissionStatus {
        if preflight { return .granted }
        switch tcc {
        case true?: return .needsRestart
        case false?: return .denied
        case nil: return asked ? .denied : .notDetermined
        }
    }

    #if os(iOS)
    /// Cached because UNUserNotificationCenter only reports asynchronously; refreshed by `refresh()`.
    private static var notificationStatus: PermissionStatus = .notDetermined
    #endif

    /// Updates statuses that can only be read asynchronously. Call before reading `status`.
    public static func refresh() async {
        #if os(iOS)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
        #endif
    }

    /// Shows the system prompt if macOS / iOS still allows one; otherwise opens the right page of Settings.
    @discardableResult
    public static func request(_ permission: Permission) async -> PermissionStatus {
        let before = status(permission)
        if before == .denied || before == .unknown {
            openSettings(for: permission)
            return before
        }
        if before == .needsRestart { return before }
        switch permission {
        case .microphone:
            #if os(macOS)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            #else
            _ = await AVAudioApplication.requestRecordPermission()
            #endif
        #if os(macOS)
        case .systemAudio:
            UserDefaults.standard.set(true, forKey: askedSystemAudioKey)
            if await TCC.request("kTCCServiceAudioCapture") == nil {
                // No private API: creating a process tap shows the prompt.
                await probeSystemAudio()
            }
        case .screenRecording:
            UserDefaults.standard.set(true, forKey: askedScreenKey)
            if !CGRequestScreenCaptureAccess() {
                // Already denied once: macOS won't prompt again, so go to the setting.
                if status(.screenRecording) == .denied { openSettings(for: .screenRecording) }
            }
        #else
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        #endif
        }
        await refresh()
        return status(permission)
    }

    /// Opens the right pane of System Settings / the app's page in Settings on iPhone.
    public static func openSettings(for permission: Permission) {
        #if os(macOS)
        let anchor = switch permission {
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_AudioCapture"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    #if os(macOS)
    /// Quits and reopens LocalScribe (screen recording access only applies to a fresh process).
    public static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func probeSystemAudio() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("localscribe-probe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let writer = try? TrackWriter(url: url, startHostTime: mach_absolute_time()) else { return }
        let recorder = SystemAudioRecorder(writer: writer)
        do {
            try recorder.start()
            try? await Task.sleep(for: .milliseconds(500))
        } catch {}
        recorder.stop()
        _ = writer.finish()
    }
    #endif
}

#if os(macOS)
/// The privacy database's own status checks. macOS has no public API for the system-audio permission (and the
/// public screen-recording check is stale until relaunch), so this uses the same private TCC calls as Apple's
/// sample code for audio taps. Everything degrades gracefully to nil if they're unavailable.
enum TCC {
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestCallback = @convention(block) (Bool) -> Void
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping RequestCallback) -> Void

    private nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    /// true = allowed, false = denied, nil = not decided yet or unknown.
    static func preflight(_ service: String) -> Bool? {
        guard let preflightFunction else { return nil }
        switch preflightFunction(service as CFString, nil) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// Shows the system prompt. nil if the private API isn't available.
    static func request(_ service: String) async -> Bool? {
        guard let requestFunction else { return nil }
        return await withCheckedContinuation { continuation in
            requestFunction(service as CFString, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
#endif
