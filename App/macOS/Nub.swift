#if os(macOS)
import AppKit
import LocalScribeKit
import LocalScribeUI
import Observation
import SwiftUI

/// The floating "nub": a small dark pill docked to the side of the screen
/// while recording (the app mark over three dancing bars), which turns into a "Take notes" card when a call starts.
///
/// It lives in a non-activating panel, so clicking it never takes focus away from Zoom, Teams or Meet, it floats over
/// full-screen apps and every Space, and it is excluded from screen sharing and screen recording.
@MainActor @Observable
final class NubController {
    enum Content: Equatable {
        case hidden, recording, prompt(MeetingApp), callEnded(Date), stillThere(Date)
    }

    private(set) var side: NubGeometry.Side = .trailing
    private(set) var hovering = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var panel: NubPanel?
    @ObservationIgnored private var captionsPanel: NubPanel?
    /// The live captions bubble beside the nub. Off until you turn it on; remembered.
    var captionsOn = UserDefaults.standard.bool(forKey: "nubCaptions") {
        didSet { UserDefaults.standard.set(captionsOn, forKey: "nubCaptions") }
    }
    var captionsExpanded = false
    @ObservationIgnored private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @ObservationIgnored private var dragging = false
    /// With more than one display, the nub follows the pointer to the display you're using.
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var pendingScreen: (key: String, since: Date)?

    init(model: AppModel) {
        self.model = model
        track()
    }

    var content: Content {
        #if DEBUG
        // Layout review without a call: LOCALSCRIBE_NUB=recording | prompt | ended | quiet
        switch ProcessInfo.processInfo.environment["LOCALSCRIBE_NUB"] {
        case "recording": return .recording
        case "prompt": return .prompt(MeetingApp(name: "Zoom"))
        case "ended": return .callEnded(Date().addingTimeInterval(15))
        case "quiet": return .stillThere(Date().addingTimeInterval(120))
        default: break
        }
        #endif
        if model.isRecording {
            if let stopsAt = model.meetings.stopsAt {
                return model.meetings.stopReason == .quiet ? .stillThere(stopsAt) : .callEnded(stopsAt)
            }
            return .recording
        }
        if let prompt = model.meetings.prompt { return .prompt(prompt) }
        return .hidden
    }

    /// Re-syncs the panel whenever what it shows changes.
    private func track() {
        let (content, _, _) = withObservationTracking { (self.content, self.captionsOn, self.captionsExpanded) } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        sync(content)
        syncCaptions()
    }

    /// Moves the nub to the display the pointer has rested on for 1.5 s, at the spot it last had there. The call may be
    /// on another monitor; the nub (and the "Take notes" card) should be where you are looking.
    private func followPointer() {
        guard NSScreen.screens.count > 1, !dragging, let panel, panel.isVisible,
              let current = panel.screen, let target = Self.screen(at: NSEvent.mouseLocation) else {
            pendingScreen = nil
            return
        }
        guard target != current else {
            pendingScreen = nil
            return
        }
        let key = Self.key(for: target)
        guard let pending = pendingScreen, pending.key == key else {
            pendingScreen = (key, Date())
            return
        }
        guard Date().timeIntervalSince(pending.since) >= 1.5 else { return }
        pendingScreen = nil
        panel.setFrame(restoredFrame(size: panel.frame.size), display: true)
        syncCaptions()
    }

    /// Places the captions bubble beside the nub, on the side away from the screen edge.
    private func syncCaptions() {
        guard content == .recording, captionsOn, let nub = panel, nub.isVisible, let visible = nub.screen?.visibleFrame else {
            captionsPanel?.orderOut(nil)
            return
        }
        let bubble = captionsPanel ?? {
            let bubble = NubPanel()
            let host = NubHostingView(rootView: CaptionsBubble(nub: self).environment(model).font(.base))
            host.sizingOptions = []
            bubble.contentView = host
            captionsPanel = bubble
            return bubble
        }()
        let size = captionsExpanded ? CGSize(width: 470, height: 420) : CGSize(width: 352, height: 124)
        let x = side == .trailing ? nub.frame.minX - size.width : nub.frame.maxX
        let frame = NubGeometry.clamped(CGRect(x: x, y: nub.frame.midY - size.height / 2, width: size.width, height: size.height), in: visible)
        bubble.setFrame(frame, display: true)
        bubble.orderFrontRegardless()
    }

    private func sync(_ content: Content) {
        guard content != .hidden else {
            panel?.orderOut(nil)
            hovering = false
            followTask?.cancel()
            followTask = nil
            return
        }
        if followTask == nil {
            followTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.followPointer()
                }
            }
        }
        let panel = self.panel ?? makePanel()
        let size = size(for: content)
        if panel.isVisible {
            guard let visible = panel.screen?.visibleFrame else { return }
            let frame = NubGeometry.resized(panel.frame, to: size, side: side, in: visible)
            if frame != panel.frame { panel.setFrame(frame, display: true) }
        } else {
            panel.setFrame(restoredFrame(size: size), display: false)
            panel.orderFrontRegardless()
        }
    }

    /// Sizes: the pill, plus a 30 pt cell while taking screenshots; the card when prompting.
    private func size(for content: Content) -> CGSize {
        switch content {
        case .hidden, .recording:
            CGSize(width: NubMetrics.compactWindow.width,
                   height: NubMetrics.compactWindow.height + (model.settings.screenshotMode == .off ? 0 : NubMetrics.cell.height))
        case .prompt, .callEnded, .stillThere: NubMetrics.promptWindowWithTitle
        }
    }

    private func makePanel() -> NubPanel {
        let panel = NubPanel()
        let host = NubHostingView(rootView: NubView(nub: self).environment(model).font(.base))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hovering = inside }
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: Position: docked to a side, remembered per display

    private static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private static func key(for screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "nubPosition.\(number)"
    }

    private func restoredFrame(size: CGSize) -> CGRect {
        guard let screen = Self.screen(at: NSEvent.mouseLocation) else { return CGRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        if let saved = UserDefaults.standard.dictionary(forKey: Self.key(for: screen)),
           let side = (saved["side"] as? String).flatMap(NubGeometry.Side.init(rawValue:)),
           let fraction = saved["fraction"] as? Double {
            self.side = side
            return NubGeometry.frame(size: size, side: side, fraction: fraction, in: visible)
        }
        side = .trailing
        return NubGeometry.defaultFrame(size: size, in: visible)
    }

    private func save(_ frame: CGRect, on screen: NSScreen) {
        let fraction = NubGeometry.fraction(of: frame, in: screen.visibleFrame)
        UserDefaults.standard.set(["side": side.rawValue, "fraction": fraction], forKey: Self.key(for: screen))
    }

    // MARK: Drag and click

    /// Moves the panel with the pointer. Returns nothing; `dragEnded` says whether it was a click.
    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = start
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if !dragging, hypot(dx, dy) < 3 { return }
        dragging = true
        panel.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
        captionsPanel?.orderOut(nil)
    }

    /// Snaps to the nearest side after a drag. Returns true if the press was a click instead.
    @discardableResult
    func dragEnded(reduceMotion: Bool) -> Bool {
        defer { dragStart = nil; dragging = false }
        guard dragging, let panel else { return dragStart != nil }
        guard let screen = Self.screen(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY)) else { return false }
        let (frame, side) = NubGeometry.snapped(panel.frame, in: screen.visibleFrame)
        self.side = side
        if reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)
                panel.animator().setFrame(frame, display: true)
            }
        }
        save(frame, on: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.32)) { [weak self] in self?.syncCaptions() }
        return false
    }

    /// Clicking the nub opens the meeting you're in.
    func openMeeting() {
        if let id = model.session?.recording.id { model.selection = id }
        AppDelegate.showMainWindow()
    }
}

/// A borderless, non-activating, floating panel: never steals focus from the call, shows on every Space and over
/// full-screen apps, and is excluded from screen capture (`sharingType = .none`).
final class NubPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(origin: .zero, size: NubMetrics.compactWindow),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        sharingType = .none
        title = "LocalScribe"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reports hover even though the panel is never key (SwiftUI's own hover tracking needs an active window),
/// and accepts the first click so a single press works.
final class NubHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}
#endif
