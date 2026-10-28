#if os(macOS)
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// Captures what's being shared in the meeting with ScreenCaptureKit (needs "Screen & System Audio Recording").
/// It targets the meeting window (Zoom, Teams, Webex, FaceTime, or a browser tab on Google Meet / Teams web)
/// and falls back to the main display. Images stay in the recording folder and are never uploaded.
///
/// Nobody in the meeting can tell: ScreenCaptureKit reads the window server's own copy of the screen, so the call app
/// is never touched, notified or slowed visibly; captures make no sound; and Hushpad's windows are left out (and
/// hidden from screen sharing anyway). The only sign is the macOS screen-recording indicator, on your Mac alone.
public actor ScreenCapturer {
    private let recordingFolder: URL
    private let startSeconds: Double
    private let mode: ScreenshotMode
    private var detector = SlideChangeDetector()
    private var loop: Task<Void, Never>?
    /// Nothing is captured while the recording is paused, automatic or manual.
    public var isPaused = false
    public private(set) var count = 0
    private static let log = Logger(subsystem: "dev.hushpad.app", category: "screenshots")

    /// Seconds between checks for new content in automatic mode.
    private let pollInterval: Duration = .seconds(2)
    /// Width of the small frame each check grabs; a full-size screenshot is only taken when the content changed.
    private let probeWidth: CGFloat = 320

    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static let browserMeetingTitles = ["Meet", "meet.google.com", "Microsoft Teams", "Zoom", "Webex", "Whereby", "Jitsi"]

    public init(recordingFolder: URL, startHostTime: UInt64, mode: ScreenshotMode) {
        self.recordingFolder = recordingFolder
        self.startSeconds = AVAudioTime.seconds(forHostTime: startHostTime)
        self.mode = mode
    }

    public func start() {
        guard mode == .automatic, loop == nil else { return }
        loop = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                await self?.checkForNewContent()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func setPaused(_ paused: Bool) { isPaused = paused }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Manual capture. Returns the saved screenshot, or nil if nothing could be captured.
    @discardableResult
    public func captureNow() async -> Screenshot? {
        guard mode != .off, !isPaused else { return nil }
        let image: CGImage
        do { image = try await captureTarget() } catch {
            Self.log.error("Manual screenshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let time = elapsed
        if let signature = FrameSignature(image: image) { detector.markKept(signature, at: time) }
        return save(image, at: time)
    }

    private func checkForNewContent() async {
        // Never let the background poll raise the system permission prompt.
        guard !isPaused, CGPreflightScreenCaptureAccess() else { return }
        do {
            // A small probe is enough to spot a new slide and costs a fraction of a full capture every 2 s.
            guard let signature = FrameSignature(image: try await captureTarget(maxWidth: probeWidth)) else { return }
            let time = elapsed
            guard detector.shouldKeep(signature, at: time) else { return }
            save(try await captureTarget(), at: time)
        } catch {
            Self.log.error("Screenshot check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func save(_ image: CGImage, at time: Double) -> Screenshot? {
        guard let shot = try? ScreenshotStore.save(image, at: time, in: recordingFolder) else { return nil }
        count += 1
        return shot
    }

    private var elapsed: Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startSeconds
    }

    // MARK: - Capture

    /// `maxWidth` caps the image width (the change-detection probe); nil captures at Retina resolution.
    private func captureTarget(maxWidth: CGFloat? = nil) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let filter: SCContentFilter
        let size: CGSize
        if let window = Self.meetingWindow(in: content.windows) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        } else {
            // No capturable meeting window (minimised, or a small one): the display the call app is on, which may be
            // another monitor; otherwise the main display.
            let callDisplay = Self.meetingDisplay(windows: content.windows.filter(Self.isMeetingWindow).map(\.frame),
                                                  displays: content.displays.map { ($0.displayID, $0.frame) })
            guard let display = content.displays.first(where: { $0.displayID == callDisplay })
                    ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw HushpadError.audioUnavailable("No display to capture")
            }
            let ownApp = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        }
        // Retina resolution, capped so a 5K display doesn't produce 15 MB screenshots.
        let scale = min(2, (maxWidth ?? 2560) / max(size.width, 1))
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The largest on-screen window of a meeting app, or a browser window whose title looks like a web meeting.
    static func meetingWindow(in windows: [SCWindow]) -> SCWindow? {
        windows.filter { $0.isOnScreen && $0.frame.width >= 400 && $0.frame.height >= 300 && isMeetingWindow($0) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// A window of a meeting app, or a browser window whose title looks like a web meeting.
    static func isMeetingWindow(_ window: SCWindow) -> Bool {
        guard let bundle = window.owningApplication?.bundleIdentifier else { return false }
        if meetingApps.contains(bundle) { return true }
        if browsers.contains(bundle), let title = window.title {
            return browserMeetingTitles.contains { title.localizedCaseInsensitiveContains($0) }
        }
        return false
    }

    /// The display showing most of the largest meeting window, by global screen frames. Nil without one.
    static func meetingDisplay(windows: [CGRect], displays: [(id: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        guard let window = windows.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return displays
            .map { display in (display.id, display.frame.intersection(window)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}
#endif
