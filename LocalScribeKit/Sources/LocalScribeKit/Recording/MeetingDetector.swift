import Foundation

/// A call app that can trigger "Meeting detected".
public struct MeetingApp: Hashable, Sendable {
    public var name: String
    public var isBrowser: Bool

    public init(name: String, isBrowser: Bool = false) {
        self.name = name
        self.isBrowser = isBrowser
    }

    /// What the prompt calls the meeting, e.g. "Zoom call", "Browser call".
    public var callTitle: String { isBrowser ? "Browser call" : "\(name) call" }

    /// Known call apps by bundle identifier prefix. Helper processes ("com.google.Chrome.helper") match their app.
    static let known: [(prefix: String, app: MeetingApp)] = [
        ("us.zoom.", MeetingApp(name: "Zoom")),
        ("com.microsoft.teams", MeetingApp(name: "Teams")),
        ("com.cisco.webex", MeetingApp(name: "Webex")),
        ("Cisco-Systems.Spark", MeetingApp(name: "Webex")),
        ("com.tinyspeck.slackmacgap", MeetingApp(name: "Slack")),
        ("com.apple.FaceTime", MeetingApp(name: "FaceTime")),
        ("com.apple.avconferenced", MeetingApp(name: "FaceTime")),
        ("com.hnc.Discord", MeetingApp(name: "Discord")),
        ("com.google.Chrome", MeetingApp(name: "Chrome", isBrowser: true)),
        ("com.apple.Safari", MeetingApp(name: "Safari", isBrowser: true)),
        ("com.apple.WebKit.GPU", MeetingApp(name: "Safari", isBrowser: true)),
        ("company.thebrowser.", MeetingApp(name: "Arc", isBrowser: true)),
        ("com.microsoft.edgemac", MeetingApp(name: "Edge", isBrowser: true)),
        ("com.brave.Browser", MeetingApp(name: "Brave", isBrowser: true)),
        ("org.mozilla.firefox", MeetingApp(name: "Firefox", isBrowser: true)),
    ]

    public static func identify(bundleID: String) -> MeetingApp? {
        known.first { bundleID.hasPrefix($0.prefix) }?.app
    }

    /// Every app name the detector knows, for the "ignored apps" setting.
    public static var allNames: [String] {
        var seen = Set<String>()
        return known.map(\.app.name).filter { seen.insert($0).inserted }
    }
}

/// Decides when to offer "Take notes" and when a call has ended, from which call apps are using the microphone.
/// Pure and clock-driven so it can be tested; `MeetingDetector` feeds it on macOS.
public struct MeetingDetection: Sendable {
    /// How long an app must hold the microphone before it counts as a call (avoids blips such as a voice memo).
    public var debounce: TimeInterval = 3
    /// How long the microphone must be released before the call counts as over.
    public var endGrace: TimeInterval = 10

    /// Apps using the microphone right now, and since when.
    public private(set) var active: [MeetingApp: Date] = [:]
    /// When each app last released the microphone.
    public private(set) var released: [MeetingApp: Date] = [:]
    /// "Not now" for an app lasts until it releases the microphone.
    public private(set) var muted: Set<MeetingApp> = []
    /// Apps the user never wants prompts for, by name.
    public var ignored: Set<String> = []

    public init() {}

    public mutating func update(apps: Set<MeetingApp>, now: Date) {
        for app in active.keys where !apps.contains(app) {
            active[app] = nil
            released[app] = now
            muted.remove(app)
        }
        for app in apps where active[app] == nil {
            active[app] = now
            released[app] = nil
        }
    }

    public mutating func dismiss(_ app: MeetingApp) { muted.insert(app) }

    /// The call to offer "Take notes" for, if any. Native apps win over browsers.
    public func prompt(now: Date) -> MeetingApp? {
        active
            .filter { now.timeIntervalSince($0.value) >= debounce && !muted.contains($0.key) && !ignored.contains($0.key.name) }
            .sorted { ($0.key.isBrowser ? 1 : 0, $0.value) < ($1.key.isBrowser ? 1 : 0, $1.value) }
            .first?.key
    }

    /// When the next decision could change (an app passing the debounce, or a release passing the grace period).
    public func nextChange(after now: Date) -> Date? {
        let starts = active.values.map { $0.addingTimeInterval(debounce) }
        let ends = released.values.map { $0.addingTimeInterval(endGrace) }
        return (starts + ends).filter { $0 > now }.min()
    }

    /// The call app a recording belongs to: the one already in a call when it started, if any.
    public func callApp(now: Date) -> MeetingApp? {
        active.sorted { ($0.key.isBrowser ? 1 : 0, $0.value) < ($1.key.isBrowser ? 1 : 0, $1.value) }.first?.key
    }

    /// True once `app` has released the microphone for longer than the grace period.
    public func hasEnded(_ app: MeetingApp, now: Date) -> Bool {
        guard active[app] == nil, let released = released[app] else { return false }
        return now.timeIntervalSince(released) >= endGrace
    }
}

/// When a recording stops by itself. Leaving the call is not enough (you may rejoin in a few
/// minutes): the recording only offers to stop when the last words sound like goodbyes, or after a long quiet stretch
/// with no call ("Are you still there?"). The check runs on the device.
public enum CallEnd {
    /// Recordings shorter than this never stop because a call app let go (a dropped call, a quick rejoin).
    public static let minimumRecording: TimeInterval = 180
    /// Countdown after the call ends with goodbyes.
    public static let goodbyeCountdown: TimeInterval = 15
    /// No call and nothing heard for this long: ask "Are you still there?".
    public static let quietLimit: TimeInterval = 600
    /// How long that question waits before stopping.
    public static let quietCountdown: TimeInterval = 120

    /// True when the end of `captions` (the last 100 words) sounds like people saying goodbye.
    public static func saidGoodbye(_ captions: String) -> Bool {
        let words = captions.lowercased().split { !$0.isLetter && $0 != "'" }.suffix(100).map(String.init)
        guard !words.isEmpty else { return false }
        return farewells.contains { phrase in
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.count <= words.count else { return false }
            return (0...(words.count - parts.count)).contains { Array(words[$0..<($0 + parts.count)]) == parts }
        }
    }

    static let farewells = [
        "bye", "goodbye", "byebye", "see you", "see ya", "talk soon", "talk to you later", "speak soon", "take care",
        "have a good one", "have a good day", "have a great day", "have a nice day", "have a good weekend",
        "have a great weekend", "thanks everyone", "thank you everyone", "thanks all", "thanks everybody",
        "catch you later",
        "tschüss", "tschau", "bis bald", "bis dann", "ciao", "au revoir", "à bientôt", "adiós", "hasta luego",
        "tot ziens", "doei", "arrivederci", "hej då", "مع السلامة", "باي",
    ]
}

#if os(macOS)
import CoreAudio

/// Watches which call apps are using the microphone, through Core Audio's per-process state
/// (`kAudioProcessPropertyIsRunningInput`). Needs no permission, reads no audio, and touches nothing in the
/// call app, so nothing about it is visible to anyone in the meeting. Event-driven: no polling.
public final class MeetingDetector: @unchecked Sendable {
    public typealias Handler = @Sendable (Set<MeetingApp>) -> Void

    private let queue = DispatchQueue(label: "LocalScribe.MeetingDetector", qos: .utility)
    private let handler: Handler
    // Everything below is only touched on `queue`.
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var apps: [AudioObjectID: MeetingApp] = [:]
    private var last: Set<MeetingApp>?
    private let ownPID = getpid()

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stopLocked() }

    public func start() {
        queue.async { [self] in
            guard listListener == nil else { return }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            listListener = listener
            refresh()
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        if let listListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listListener)
        }
        listListener = nil
        for (process, listener) in processListeners {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(process, &address, queue, listener)
        }
        processListeners = [:]
        apps = [:]
        last = nil
    }

    /// Re-reads the process list: listens to call apps that appeared, forgets ones that quit, then reports.
    private func refresh() {
        let processes = Set(Self.processObjects())
        for (process, listener) in processListeners where !processes.contains(process) {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(process, &address, queue, listener)
            processListeners[process] = nil
            apps[process] = nil
        }
        for process in processes where processListeners[process] == nil {
            // Only call apps are watched; everything else is skipped without being recorded anywhere.
            guard Self.pid(of: process) != ownPID, let bundleID = Self.bundleID(of: process),
                  let app = MeetingApp.identify(bundleID: bundleID) else { continue }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(process, &address, queue, listener)
            processListeners[process] = listener
            apps[process] = app
        }
        report()
    }

    private func report() {
        let current = Set(apps.filter { Self.isRunningInput($0.key) }.values)
        guard current != last else { return }
        last = current
        handler(current)
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let id = value.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}
#endif
