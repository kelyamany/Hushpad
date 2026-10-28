#if os(macOS)
import AppKit
import HushpadKit
import HushpadUI
import SwiftUI

struct NubView: View {
    /// Hushpad's navy pill.
    fileprivate static let navy = Color(red: 0x1C / 255, green: 0x21 / 255, blue: 0x40 / 255)
    private static let navyEdge = Color(red: 0x3A / 255, green: 0x41 / 255, blue: 0x70 / 255)

    let nub: NubController
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch nub.content {
            case .hidden: Color.clear
            case .recording: pill
            case .prompt(let app): PromptCard(title: app.callTitle, nudge: !reduceMotion) {
                    Button("Take notes") { model.meetings.takeNotes() }.buttonStyle(NubButtonStyle(primary: true))
                    Button("Not now") { model.meetings.notNow() }.buttonStyle(NubButtonStyle(primary: false))
                }
            case .callEnded(let stopsAt): PromptCard(title: "Call ended", nudge: false) {
                    Countdown(until: stopsAt)
                    Button("Keep recording") { model.meetings.keepRecordingAfterCall() }.buttonStyle(NubButtonStyle(primary: true))
                    Button("Stop now") { Task { await model.stopRecording() } }.buttonStyle(NubButtonStyle(primary: false))
                }
            // No call and nothing heard for a while.
            case .stillThere(let stopsAt): PromptCard(title: "Are you still there?", nudge: !reduceMotion) {
                    Countdown(until: stopsAt)
                    Button("I'm still here") { model.meetings.keepRecordingAfterCall() }.buttonStyle(NubButtonStyle(primary: true))
                    Button("Stop") { Task { await model.stopRecording() } }.buttonStyle(NubButtonStyle(primary: false))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: nub.side == .trailing ? .trailing : .leading)
        .padding(nub.side == .trailing ? .trailing : .leading, NubMetrics.edgeInset)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: nub.content)
    }

    // MARK: Recording pill

    private var pill: some View {
        VStack(spacing: 0) {
            SoundLine()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 10)
                .opacity(0.8)
                .frame(width: NubMetrics.cell.width, height: NubMetrics.cell.height)
            NubBars(paused: model.isPaused, reduceMotion: reduceMotion) {
                guard let session = model.session else { return 0 }
                return max(session.micLevel, session.systemLevel ?? 0)
            }
            .frame(width: NubMetrics.cell.width, height: NubMetrics.cell.height)
            if model.settings.screenshotMode != .off {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: NubMetrics.cell.width, height: NubMetrics.cell.height)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: NubMetrics.pillWidth)
        .background(Self.navy.opacity(0.95), in: RoundedRectangle(cornerRadius: NubMetrics.pillRadius))
        .overlay {
            RoundedRectangle(cornerRadius: NubMetrics.pillRadius)
                .strokeBorder(Self.navyEdge.opacity(0.95), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NubMetrics.pillRadius + 0.75)
                .stroke(.black.opacity(0.8), lineWidth: 0.75)
                .padding(-0.75)
        }
        .overlay(alignment: .topTrailing) {
            if model.isPaused {
                Circle().fill(.orange).frame(width: 6, height: 6).offset(x: -3, y: 3)
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 2, y: 2)
        .scaleEffect(nub.hovering ? 1.08 : 1)
        .contentShape(RoundedRectangle(cornerRadius: NubMetrics.pillRadius))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in nub.dragChanged() }
            .onEnded { _ in if nub.dragEnded(reduceMotion: reduceMotion) { nub.openMeeting() } })
        .contextMenu { menu }
        .help(model.isPaused ? "Paused. Click to open the meeting, right-click to resume or stop." : "Recording. Click to open the meeting, right-click to pause or stop.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.isPaused ? "Recording paused" : "Recording")
        .accessibilityHint("Opens the meeting")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { nub.openMeeting() }
        .accessibilityAction(named: model.isPaused ? "Resume" : "Pause") { model.togglePause() }
        .accessibilityAction(named: "Stop recording") { Task { await model.stopRecording() } }
    }

    @ViewBuilder private var menu: some View {
        Button(model.isPaused ? "Resume Recording" : "Pause Recording", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
            model.togglePause()
        }
        Button("Stop Recording", systemImage: "stop.fill") { Task { await model.stopRecording() } }
        if model.settings.screenshotMode != .off {
            Button("Take Screenshot", systemImage: "camera") { Task { await model.captureScreenshot() } }
        }
        Toggle("Live Captions", isOn: Binding(get: { nub.captionsOn }, set: { nub.captionsOn = $0 }))
        Divider()
        Button("Open Hushpad") { nub.openMeeting() }
    }
}

/// Three bars mirrored around a centre line, driven by the recording level ("dancing bars").
/// Green while it hears you; red after a few seconds of silence ("we're not hearing anything"); still dots when paused.
private struct NubBars: View {
    let paused: Bool
    let reduceMotion: Bool
    let level: () -> Float

    @State private var halves: [CGFloat] = [DancingBars.restingVisible, DancingBars.restingVisible, DancingBars.restingVisible]
    @State private var silentSince: Date?

    private static let listening = Theme.listening
    private static let red = Color(red: 0.93, green: 0.46, blue: 0.35)

    private var silent: Bool {
        guard !paused, let silentSince else { return false }
        return Date().timeIntervalSince(silentSince) > 3
    }

    var body: some View {
        VStack(spacing: 0) {
            half.scaleEffect(x: 1, y: 1)
            half.scaleEffect(x: 1, y: -1)
        }
        .foregroundStyle(paused ? Color.white.opacity(0.45) : silent ? Self.red : Self.listening)
        .accessibilityHidden(true)
        .task(id: paused) {
            guard !paused else {
                withAnimation(.easeInOut(duration: 0.3)) { halves = halves.map { _ in DancingBars.restingVisible } }
                return
            }
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// One 12×10 half: bars anchored to the centre line, showing `halves[i]` points.
    private var half: some View {
        HStack(alignment: .bottom, spacing: DancingBars.gap) {
            ForEach(0..<3, id: \.self) { index in
                Capsule().frame(width: DancingBars.barWidth, height: halves[index])
            }
        }
        .frame(width: 12, height: DancingBars.halfHeight, alignment: .bottom)
        .clipped()
    }

    private func tick() {
        let meter = level()
        if meter < DancingBars.silenceMeter {
            if silentSince == nil { silentSince = Date() }
        } else {
            silentSince = nil
        }
        let gain = DancingBars.gain(meter: meter)
        let next = [2.0, 1.0, 2.0].map { DancingBars.visibleHalf(gain: gain, sensitivity: $0, jitter: reduceMotion ? 0.5 : .random(in: 0...1)) }
        guard next != halves else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { halves = next }
    }
}

/// The "Meeting detected" card: light green, the app mark, a title and two small buttons.
/// "Stopping in 0:42" under a stop prompt.
private struct Countdown: View {
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
            Text("Stopping in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .font(.micro).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct PromptCard<Buttons: View>: View {
    let title: String
    let nudge: Bool
    @ViewBuilder let buttons: () -> Buttons
    @State private var nudged = false

    var body: some View {
        VStack(spacing: 0) {
            SoundLine()
                .stroke(Color(white: 0.1), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 10)
                .opacity(0.8)
                .frame(height: NubMetrics.cell.height)
            Text(title)
                .font(.label.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .foregroundStyle(Color(white: 0.1))
                .padding(.horizontal, 3)
                .padding(.bottom, 8)
            VStack(spacing: 4) { buttons() }
        }
        .padding(4)
        .padding(.bottom, 2)
        .frame(width: 120)
        .background(Theme.highlight, in: RoundedRectangle(cornerRadius: NubMetrics.promptRadius))
        .overlay { RoundedRectangle(cornerRadius: NubMetrics.promptRadius).strokeBorder(.black.opacity(0.1), lineWidth: 1) }
        .shadow(color: .black.opacity(0.1), radius: 7, y: 5)
        .environment(\.colorScheme, .light)
        .rotationEffect(.degrees(nudged ? 0 : -3), anchor: .center)
        .onAppear {
            guard nudge else { nudged = true; return }
            withAnimation(.spring(duration: 0.5, bounce: 0.6).delay(0.1)) { nudged = true }
        }
    }
}

private struct NubButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 26)
            .foregroundStyle(primary ? Color.white : Color(white: 0.1))
            .background(primary ? NubView.navy : Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Rectangle())
    }
}

/// The live captions bubble: the line being spoken, large, with who's speaking; expand for the whole transcript.
struct CaptionsBubble: View {
    let nub: NubController
    @Environment(AppModel.self) private var model

    private var transcript: LiveTranscript? { model.session?.live?.transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Text("Live captions").font(.label.weight(.medium)).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Button(nub.captionsExpanded ? "Collapse live transcript" : "Expand live transcript",
                       systemImage: nub.captionsExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    nub.captionsExpanded.toggle()
                }
                Button("Close live captions", systemImage: "xmark") { nub.captionsOn = false }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Space.m)
            .padding(.top, Space.s)
            if nub.captionsExpanded {
                LiveTranscriptView(transcript: transcript, paused: model.isPaused)
            } else {
                latest.padding(.horizontal, Space.m).padding(.bottom, Space.m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paperRaised.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline) }
        .padding(6)
    }

    @ViewBuilder private var latest: some View {
        if model.isPaused {
            Text("Captions are paused").font(.base).foregroundStyle(Theme.inkSecondary)
        } else if let line = transcript?.latest {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.source.speakerName).font(.label.weight(.medium)).foregroundStyle(Theme.inkTertiary)
                Text(line.text)
                    .font(.heading.weight(.regular))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .truncationMode(.head)
            }
        } else {
            Text(transcript == nil ? "Live captions are off in Settings" : "Listening for speech…")
                .font(.base).foregroundStyle(Theme.inkSecondary)
        }
    }
}
#endif
