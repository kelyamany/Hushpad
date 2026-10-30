import CoreGraphics
import Foundation

/// One element of a meeting window's accessibility tree, flattened. Frames are global screen points, top-left origin
/// (the same space as ScreenCaptureKit's window frames).
public struct AXNodeSnapshot: Sendable, Equatable {
    public var role: String
    public var identifier: String
    /// Title, description and value, lowercased and joined, for marker matching.
    public var text: String
    public var frame: CGRect?

    public init(role: String, identifier: String = "", text: String = "", frame: CGRect? = nil) {
        self.role = role
        self.identifier = identifier
        self.text = text.lowercased()
        self.frame = frame
    }
}

public struct AXWindowSnapshot: Sendable, Equatable {
    public var title: String
    public var frame: CGRect
    public var nodes: [AXNodeSnapshot]

    public init(title: String, frame: CGRect, nodes: [AXNodeSnapshot]) {
        self.title = title
        self.frame = frame
        self.nodes = nodes
    }
}

public enum ScreenShareState: Sendable, Equatable {
    /// Nobody is sharing, or the app isn't one we know how to read.
    case none
    /// You are presenting. Hushpad only captures other people's shares.
    case selfSharing
    /// Someone is sharing but the shared content can't be told apart from the rest; nothing is captured.
    case ambiguous
    /// Someone else is sharing; `surface` is the shared content only, inside the meeting window `window`.
    case someoneElse(surface: CGRect, window: CGRect)
}

public enum MeetingProvider: String, Sendable, CaseIterable {
    case zoom, meet, teams
}

/// Tells from a meeting app's accessibility tree whether someone else is sharing, and where the shared content is.
///
/// Modelled on Granola's screen-share monitor: it looks for each app's "you are presenting" and "someone is presenting"
/// labels, then takes the shared content as the largest innermost element of the meeting window, so webcam tiles,
/// toolbars and chat are left out. When that isn't clear-cut it reports `.ambiguous` and nothing is captured.
public enum ScreenShareAnalyzer {
    struct Rules {
        /// Any of these (in an element's text or identifier) means you are the one sharing.
        var selfMarkers: [String]
        /// Any of these means someone else is sharing.
        var otherMarkers: [String]
    }

    static let rules: [MeetingProvider: Rules] = [
        .zoom: Rules(selfMarkers: ["stop share", "pause share", "zmmttoolbarcontentidentifierpauseshare",
                                   "zoom share toolbar", "you are screen sharing", "you're screen sharing"],
                     otherMarkers: ["you are viewing", "you're viewing", "is sharing", "viewing-shared-screen"]),
        .meet: Rules(selfMarkers: ["you are presenting", "you're presenting", "stop presenting"],
                     otherMarkers: ["is presenting", "(presenting)"]),
        .teams: Rules(selfMarkers: ["stop sharing", "stop presenting", "you're sharing", "you are sharing"],
                      otherMarkers: ["is sharing", "is presenting", "shared content"]),
    ]

    /// Every marker, plus words worth seeing when tuning the rules (`hushpad ax-share`).
    public static let keywords: [String] = rules.values.flatMap { $0.selfMarkers + $0.otherMarkers }
        + ["shar", "present", "screen", "view"]

    /// The shared content must be at least this big, in points.
    static let minSurface = CGSize(width: 400, height: 300)
    /// …and cover at least this much of the meeting window.
    static let minWindowCoverage = 0.2
    /// An element covering more than this of the window is the window's own layout, not the shared content.
    /// When the share really fills the window this errs on the side of capturing nothing.
    static let maxWindowCoverage = 0.85
    /// A second, unrelated element at least this large relative to the best one makes the choice ambiguous
    /// (a gallery of equal tiles, or two shares at once).
    static let rivalRatio = 0.6

    static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Apps worth reading at all: Zoom, Teams and browsers (for Google Meet).
    public static func mightHostMeeting(bundleID: String) -> Bool {
        bundleID.hasPrefix("us.zoom.") || bundleID.hasPrefix("com.microsoft.teams") || browserBundles.contains(bundleID)
    }

    /// Which meeting a window belongs to, if any. Browsers only count with a Google Meet tab in front.
    public static func provider(bundleID: String, windowTitle: String) -> MeetingProvider? {
        if bundleID.hasPrefix("us.zoom.") { return .zoom }
        if bundleID.hasPrefix("com.microsoft.teams") { return .teams }
        if browserBundles.contains(bundleID) {
            let title = windowTitle.lowercased()
            if title.hasPrefix("meet") || title.contains("google meet") || title.contains("meet.google.com") { return .meet }
        }
        return nil
    }

    public static func state(provider: MeetingProvider, windows: [AXWindowSnapshot]) -> ScreenShareState {
        guard let rules = rules[provider] else { return .none }
        if windows.contains(where: { matches($0, rules.selfMarkers) }) { return .selfSharing }
        guard let window = windows.first(where: { matches($0, rules.otherMarkers) }) else { return .none }
        guard let surface = sharedSurface(in: window) else { return .ambiguous }
        return .someoneElse(surface: surface, window: window.frame)
    }

    /// Combines the answers from several apps (say Zoom is open and a Meet tab too).
    public static func combine(_ states: [ScreenShareState]) -> ScreenShareState {
        let shares = states.filter { if case .someoneElse = $0 { true } else { false } }
        if shares.count == 1 { return shares[0] }
        if shares.count > 1 { return .ambiguous }
        if states.contains(.selfSharing) { return .selfSharing }
        return states.contains(.ambiguous) ? .ambiguous : .none
    }

    static func matches(_ window: AXWindowSnapshot, _ markers: [String]) -> Bool {
        let title = window.title.lowercased()
        if markers.contains(where: title.contains) { return true }
        return window.nodes.contains { node in
            let identifier = node.identifier.lowercased()
            return markers.contains { node.text.contains($0) || identifier.contains($0) }
        }
    }

    /// The largest innermost element big enough to be shared content, or nil when there isn't exactly one.
    /// Innermost means it contains no other such element, so a view that wraps the shared picture, or a layout that
    /// holds a gallery of tiles, is never taken for the share itself.
    static func sharedSurface(in window: AXWindowSnapshot) -> CGRect? {
        let windowArea = area(window.frame)
        guard windowArea > 0 else { return nil }
        var seen = Set<[Int]>()
        let candidates = window.nodes.compactMap(\.frame).filter { frame in
            let key = [frame.minX, frame.minY, frame.width, frame.height].map { Int($0.rounded()) }
            guard seen.insert(key).inserted else { return false }
            let visible = frame.intersection(window.frame)
            return frame.width >= minSurface.width && frame.height >= minSurface.height
                && !visible.isNull && area(visible) >= 0.95 * area(frame)
                && area(frame) <= maxWindowCoverage * windowArea
        }
        let innermost = candidates.filter { outer in
            !candidates.contains { inner in inner != outer && outer.contains(inner) }
        }.sorted { area($0) > area($1) }
        guard let best = innermost.first, area(best) >= minWindowCoverage * windowArea else { return nil }
        if innermost.dropFirst().contains(where: { !$0.intersects(best) && area($0) >= rivalRatio * area(best) }) { return nil }
        return best
    }

    /// `surface` in the window's own coordinates, clipped to the window: what ScreenCaptureKit's `sourceRect` expects.
    public static func sourceRect(surface: CGRect, window: CGRect) -> CGRect {
        surface.offsetBy(dx: -window.minX, dy: -window.minY)
            .intersection(CGRect(origin: .zero, size: window.size))
    }

    static func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }
}
