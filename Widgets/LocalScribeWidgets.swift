import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LocalScribeWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
    }
}

// MARK: - Live Activity

// The widget target doesn't link LocalScribeUI, so mirror Theme.record's dark value (0xFF6159).
// Live Activities render on a dark system surface in both appearances.
private let recordRed = Color(red: 0xFF / 255, green: 0x61 / 255, blue: 0x59 / 255)

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecordingView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Recording").font(.headline)
                    } icon: {
                        Image(systemName: "waveform").foregroundStyle(recordRed)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 64, maxWidth: 120, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        StopButton()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(recordRed)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .foregroundStyle(recordRed)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(recordRed)
            }
            .keylineTint(recordRed)
        }
    }
}

struct LockScreenRecordingView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(recordRed.opacity(0.18))
                Image(systemName: "waveform").font(.title3.weight(.semibold)).foregroundStyle(recordRed)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording").font(.headline).foregroundStyle(.white)
                Text(context.state.title).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 64, maxWidth: 120, alignment: .trailing)
            StopButton()
        }
        .padding(16)
    }
}

struct StopButton: View {
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(recordRed, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}

// MARK: - Control Center / Lock Screen control

struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.localscribe.app.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record Meeting", systemImage: "waveform.circle.fill")
            }
        }
        .displayName("Record Meeting")
        .description("Start recording a meeting with LocalScribe.")
    }
}
