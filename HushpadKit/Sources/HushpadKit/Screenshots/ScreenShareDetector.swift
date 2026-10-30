#if os(macOS)
import AppKit
import ApplicationServices
import HushpadCore

/// A share by someone else, found in a running meeting app.
public struct DetectedShare: Sendable, Equatable {
    public var pid: pid_t
    /// The shared content only, in global screen points (top-left origin).
    public var surface: CGRect
    /// The meeting window that shows it.
    public var window: CGRect
}

/// Reads the meeting apps' accessibility trees (needs the Accessibility permission) to tell whether someone else is
/// sharing their screen, and where. Read-only, except that Chromium browsers are asked to expose their web content to
/// accessibility while a Google Meet window is open; `restore()` undoes that.
public struct ScreenShareDetector {
    /// Keeps one slow or hung app from stalling the screenshot loop.
    static let messagingTimeout: Float = 0.25
    static let maxDepth = 40
    static let maxNodes = 4000
    static let maxTextLength = 200

    static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let enhancedUI = "AXEnhancedUserInterface"

    /// Browsers we switched AXEnhancedUserInterface on for (it was off), to switch back off.
    private var enhanced: Set<pid_t> = []

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Someone else's share, when exactly one is clear-cut. Nil otherwise, including without the permission.
    public mutating func currentShare() -> DetectedShare? {
        guard Self.isTrusted else { return nil }
        var found: [(state: ScreenShareState, pid: pid_t)] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bundle = app.bundleIdentifier, ScreenShareAnalyzer.mightHostMeeting(bundleID: bundle) else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            let windows = Self.windows(of: element)
            // The provider comes from the app, or for a browser from a window title; only those windows are read.
            let meetingWindows = windows.compactMap { window -> (MeetingProvider, AXUIElement, String)? in
                let title = Self.string(window, kAXTitleAttribute) ?? ""
                return ScreenShareAnalyzer.provider(bundleID: bundle, windowTitle: title).map { ($0, window, title) }
            }
            guard let provider = meetingWindows.first?.0 else { continue }
            if provider == .meet { exposeWebContent(app.processIdentifier, element: element, bundleID: bundle) }
            let snapshots = meetingWindows.compactMap { Self.snapshot($0.1, title: $0.2) }
            found.append((ScreenShareAnalyzer.state(provider: provider, windows: snapshots), app.processIdentifier))
        }
        guard case let .someoneElse(surface, window) = ScreenShareAnalyzer.combine(found.map(\.state)),
              let pid = found.first(where: { $0.state == .someoneElse(surface: surface, window: window) })?.pid else { return nil }
        return DetectedShare(pid: pid, surface: surface, window: window)
    }

    /// Puts browsers' accessibility back the way they were. Call when the recording stops.
    public mutating func restore() {
        for pid in enhanced {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), Self.enhancedUI as CFString, kCFBooleanFalse)
        }
        enhanced = []
    }

    /// Chromium only builds its web accessibility tree for assistive apps; this flag asks for it, like VoiceOver does.
    private mutating func exposeWebContent(_ pid: pid_t, element: AXUIElement, bundleID: String) {
        guard Self.chromiumBundles.contains(bundleID), !enhanced.contains(pid) else { return }
        var value: CFTypeRef?
        let alreadyOn = AXUIElementCopyAttributeValue(element, Self.enhancedUI as CFString, &value) == .success && (value as? Bool) == true
        guard !alreadyOn, AXUIElementSetAttributeValue(element, Self.enhancedUI as CFString, kCFBooleanTrue) == .success else { return }
        enhanced.insert(pid)
    }

    /// What the detector sees, for tuning the share rules: for each meeting window, the verdict and an outline of
    /// its elements. Text is reduced to its length and the share keywords it contains, so names and meeting content
    /// never appear. Does not change browsers' accessibility settings.
    public static func redactedReport() -> String {
        guard isTrusted else { return "Accessibility isn't allowed for this process (System Settings › Privacy & Security › Accessibility)." }
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bundle = app.bundleIdentifier, ScreenShareAnalyzer.mightHostMeeting(bundleID: bundle) else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            for window in windows(of: element) {
                let title = string(window, kAXTitleAttribute) ?? ""
                guard let provider = ScreenShareAnalyzer.provider(bundleID: bundle, windowTitle: title),
                      let snapshot = snapshot(window, title: title) else { continue }
                let state = ScreenShareAnalyzer.state(provider: provider, windows: [snapshot])
                lines.append("== \(bundle) [\(provider.rawValue)] window \(describe(snapshot.frame)): \(state)")
                for node in snapshot.nodes {
                    let found = ScreenShareAnalyzer.keywords.filter { node.text.contains($0) || node.identifier.lowercased().contains($0) }
                    let text = "‹\(node.text.count) chars›" + (found.isEmpty ? "" : " matches \(found)")
                    lines.append("  \(node.role) id=\(node.identifier.prefix(80)) \(node.frame.map(describe) ?? "-") \(text)")
                }
            }
        }
        return lines.isEmpty ? "No Zoom, Teams or Google Meet window found." : lines.joined(separator: "\n")
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }

    // MARK: - Reading the tree

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// The window and its elements, breadth first (so the top-level layout is read before deep web content), capped.
    static func snapshot(_ window: AXUIElement, title: String) -> AXWindowSnapshot? {
        guard let frame = frame(of: window) else { return nil }
        var nodes: [AXNodeSnapshot] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, nodes.count < maxNodes {
            let (element, depth) = queue[index]
            index += 1
            let values = attributes(of: element)
            nodes.append(AXNodeSnapshot(role: values.role, identifier: values.identifier, text: values.text, frame: values.frame))
            if depth < maxDepth { queue.append(contentsOf: values.children.map { ($0, depth + 1) }) }
        }
        return AXWindowSnapshot(title: title, frame: frame, nodes: nodes)
    }

    private static let names = [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute]

    /// One round trip per element.
    static func attributes(of element: AXUIElement) -> (role: String, identifier: String, text: String, frame: CGRect?, children: [AXUIElement]) {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let values = raw as? [AnyObject], values.count == 8 else { return ("", "", "", nil, []) }
        let text = values[2...4].compactMap { $0 as? String }.map { String($0.prefix(maxTextLength)) }.joined(separator: " ")
        var frame: CGRect?
        if let position = point(values[5]), let size = size(values[6]) { frame = CGRect(origin: position, size: size) }
        return (values[0] as? String ?? "", values[1] as? String ?? "", text, frame, values[7] as? [AXUIElement] ?? [])
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let origin = point(position), let extent = self.size(size) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
#endif
