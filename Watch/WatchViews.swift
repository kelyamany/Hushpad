import LocalScribeCore
import LocalScribeUI
import SwiftUI

struct WatchRootView: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        TabView {
            RecordPage()
            RecordingsPage()
        }
        .tabViewStyle(.verticalPage)
        .alert("Hushpad", isPresented: Binding(get: { recorder.errorMessage != nil },
                                                   set: { if !$0 { recorder.errorMessage = nil } })) {
            Button("OK") { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }
}

/// The main page: one big button, the timer, and a live waveform.
struct RecordPage: View {
    @Environment(WatchRecorder.self) private var recorder
    /// Always-On: wrist down. Keep the timer, drop the animation.
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Group {
                if let start = recorder.startedAt {
                    ElapsedTime(since: start)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(dimmed ? .secondary : .primary)
                    if dimmed {
                        Label("Recording", systemImage: "waveform").font(.footnote).foregroundStyle(Theme.record)
                    } else {
                        LiveWaveform(bars: 22, color: Theme.record) { recorder.level }
                            .frame(height: 24)
                            .padding(.horizontal, 8)
                    }
                } else {
                    Text("Ready").font(.system(.title3, design: .rounded, weight: .semibold))
                    Text("Tap to record a meeting").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))

            RecordButton(isRecording: recorder.isRecording, diameter: dimmed ? 76 : 88) {
                Task { await recorder.toggle() }
            }
            .disabled(recorder.isStarting)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .animation(.smooth, value: recorder.isRecording)
        .containerBackground((recorder.isRecording ? Theme.record : Theme.accent).opacity(dimmed ? 0.1 : recorder.isRecording ? 0.35 : 0.2),
                             for: .tabView)
    }
}

/// Recordings made on the Watch and whether they've reached the iPhone yet.
struct RecordingsPage: View {
    @Environment(WatchRecorder.self) private var recorder
    @State private var pendingDelete: Recording?

    var body: some View {
        NavigationStack {
            List {
                if recorder.recordings.isEmpty {
                    Text("Recordings you make here are sent to your iPhone to transcribe.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(recorder.recordings) { recording in
                    WatchRecordingRow(recording: recording, state: recorder.syncStates[recording.id] ?? .recordedOnly) {
                        recorder.retry(recording)
                    }
                        .swipeActions {
                            Button(role: .destructive) {
                                if recorder.syncStates[recording.id] == .onPhone {
                                    recorder.delete(recording)
                                } else {
                                    pendingDelete = recording
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .navigationTitle("Recordings")
            .confirmationDialog("Not on your iPhone yet. Delete anyway?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let pendingDelete { recorder.delete(pendingDelete) }
                    pendingDelete = nil
                }
                Button("Keep", role: .cancel) { pendingDelete = nil }
            }
        }
    }
}

struct WatchRecordingRow: View {
    let recording: Recording
    let state: WatchRecorder.SyncState
    var onRetry: () -> Void = {}

    var body: some View {
        if case .failed = state {
            Button(action: onRetry) { content }
                .buttonStyle(.plain)
                .accessibilityHint("Tries sending again")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).font(.headline).lineLimit(2)
            Text([recording.createdAt.formatted(.relative(presentation: .named)), recording.durationText]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Label(statusText, systemImage: statusIcon)
                .font(.footnote)
                .foregroundStyle(statusColor)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: String {
        switch state {
        case .onPhone: "checkmark.circle.fill"
        case .sending: "arrow.up.circle"
        case .recordedOnly: "iphone.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state {
        case .onPhone: Theme.success
        case .sending: Theme.accent
        case .recordedOnly: .secondary
        case .failed: Theme.danger
        }
    }

    private var statusText: String {
        switch state {
        case .onPhone: "On iPhone"
        case .sending: "Sending\u{2026}"
        case .recordedOnly: "Waiting for iPhone"
        case .failed: "Couldn\u{2019}t send \u{2013} tap to retry"
        }
    }
}
