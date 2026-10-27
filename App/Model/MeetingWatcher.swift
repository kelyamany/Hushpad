#if os(macOS)
import Foundation
import LocalScribeKit
import Observation

/// "Meeting detected": when a call app starts using the microphone, the nub offers "Take notes".
/// Nothing records until you click. Leaving the call doesn't stop the recording (you may rejoin): it only
/// offers to stop when the call ended with goodbyes, or when there's been no call and nothing heard for a while.
@MainActor @Observable
final class MeetingWatcher {
    /// The call to offer "Take notes" for.
    private(set) var prompt: MeetingApp?
    enum StopReason: Equatable {
        /// The call app let go and the last words were goodbyes.
        case callEnded
        /// No call and nothing heard for a while: "Are you still there?".
        case quiet
    }

    /// While set, the recording stops at this moment unless you keep it.
    private(set) var stopsAt: Date?
    private(set) var stopReason: StopReason?

    static let promptTimeout: TimeInterval = 60

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var detector: MeetingDetector?
    @ObservationIgnored private var detection = MeetingDetection()
    @ObservationIgnored private var promptShownAt: Date?
    /// The call the current recording belongs to, once one is seen.
    @ObservationIgnored private var callApp: MeetingApp?
    /// The call release already judged, so leaving once is only checked once.
    @ObservationIgnored private var judgedRelease: Date?
    /// "Keep recording" / "I'm still here" counts as activity.
    @ObservationIgnored private var keptAt: Date?
    @ObservationIgnored private var wakeUp: Task<Void, Never>?

    func attach(_ model: AppModel) {
        self.model = model
        updateEnabled()
    }

    /// Starts or stops listening, following the two settings that need it.
    func updateEnabled() {
        guard let settings = model?.settings else { return }
        let needed = settings.detectMeetings || settings.stopWhenCallEnds
        if needed, detector == nil {
            let detector = MeetingDetector { [weak self] apps in
                Task { @MainActor in self?.receive(apps) }
            }
            detector.start()
            self.detector = detector
        } else if !needed, let detector {
            detector.stop()
            self.detector = nil
            detection = MeetingDetection()
        }
        evaluate()
    }

    // MARK: Actions from the nub

    func takeNotes() {
        guard let app = prompt, let model else { return }
        prompt = nil
        Task { await model.startRecording(title: app.callTitle) }
    }

    func notNow() {
        if let prompt { detection.dismiss(prompt) }
        prompt = nil
        promptShownAt = nil
        evaluate()
    }

    func keepRecordingAfterCall() {
        keptAt = Date()
        cancelStop()
        evaluate()
    }

    // MARK: Recording lifecycle (called by AppModel)

    func recordingStarted() {
        prompt = nil
        promptShownAt = nil
        keptAt = nil
        judgedRelease = nil
        callApp = detection.callApp(now: Date())
        evaluate()
    }

    func recordingStopped() {
        callApp = nil
        cancelStop()
        evaluate()
    }

    // MARK: Decisions

    private func receive(_ apps: Set<MeetingApp>) {
        detection.update(apps: apps, now: Date())
        evaluate()
    }

    private func evaluate() {
        guard let model else { return }
        let now = Date()
        let settings = model.settings
        detection.ignored = Set(settings.ignoredMeetingApps)
        if model.isRecording {
            prompt = nil
            promptShownAt = nil
            if callApp == nil { callApp = detection.callApp(now: now) }
            if settings.stopWhenCallEnds { decideStop(model, now: now) } else { cancelStop() }
            if let stopsAt, now >= stopsAt {
                cancelStop()
                Task { await model.stopRecording() }
            }
        } else {
            cancelStop()
            let candidate = settings.detectMeetings ? detection.prompt(now: now) : nil
            if candidate != prompt {
                prompt = candidate
                promptShownAt = candidate == nil ? nil : now
            }
            // An unanswered prompt goes away by itself, like "Not now".
            if let shown = promptShownAt, now.timeIntervalSince(shown) >= Self.promptTimeout { notNow() ; return }
        }
        scheduleWakeUp(now: now)
    }

    private func decideStop(_ model: AppModel, now: Date) {
        let inCall = !detection.active.isEmpty
        let captions = model.session?.live?.transcript
        // Back in the call, or someone spoke: whatever was counting down is off.
        if stopReason == .callEnded, inCall { cancelStop() }
        if stopReason == .quiet, let asked = stopsAt?.addingTimeInterval(-CallEnd.quietCountdown),
           inCall || (captions?.lastHeard ?? .distantPast) > asked { cancelStop() }
        guard stopsAt == nil else { return }

        // Left the call: judged once, at the moment it counts as over.
        if let app = callApp, detection.hasEnded(app, now: now), let released = detection.released[app], judgedRelease != released {
            judgedRelease = released
            let longEnough = now.timeIntervalSince(model.session?.startDate ?? now) >= CallEnd.minimumRecording
            if longEnough, let captions, CallEnd.saidGoodbye(captions.lastWords(100)) {
                return startStop(.callEnded, at: now.addingTimeInterval(CallEnd.goodbyeCountdown))
            }
        }
        // No call and nothing heard for a while. Without captions, only after a call has ended (nothing to listen to).
        if !inCall, !model.isPaused, captions?.status == .listening || judgedRelease != nil,
           now.timeIntervalSince(quietSince(model)) >= CallEnd.quietLimit {
            startStop(.quiet, at: now.addingTimeInterval(CallEnd.quietCountdown))
        }
    }

    /// Since when nothing has happened: the later of the start, the last call, the last words heard, and "keep recording".
    private func quietSince(_ model: AppModel) -> Date {
        let events: [Date?] = [model.session?.startDate, detection.released.values.max(), model.session?.live?.transcript.lastHeard, keptAt]
        return events.compactMap { $0 }.max() ?? Date()
    }

    private func startStop(_ reason: StopReason, at date: Date) {
        stopReason = reason
        stopsAt = date
    }

    private func cancelStop() {
        stopReason = nil
        stopsAt = nil
    }

    /// Re-evaluates when the next deadline passes (debounce, end grace, countdown, prompt timeout, quiet limit).
    /// While a countdown runs, it also checks every few seconds whether anyone spoke.
    private func scheduleWakeUp(now: Date) {
        wakeUp?.cancel()
        var quietCheck: Date?
        if let model, model.isRecording, model.settings.stopWhenCallEnds {
            quietCheck = stopsAt == nil ? max(quietSince(model).addingTimeInterval(CallEnd.quietLimit), now.addingTimeInterval(30))
                                         : now.addingTimeInterval(2)
        }
        let deadlines = [detection.nextChange(after: now), stopsAt, promptShownAt?.addingTimeInterval(Self.promptTimeout), quietCheck]
        guard let next = deadlines.compactMap({ $0 }).filter({ $0 > now }).min() else { return }
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.05))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}
#endif
