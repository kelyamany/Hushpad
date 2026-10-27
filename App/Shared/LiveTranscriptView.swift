import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// Captions while recording: your lines on the right, theirs on the left, newest at the bottom.
struct LiveTranscriptView: View {
    let transcript: LiveTranscript?
    var paused = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s) {
                    if let transcript {
                        ForEach(transcript.lines) { line in
                            Bubble(line: line).id(line.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(Space.m)
            }
            .overlay { placeholder }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("Always get consent before recording others.")
                    .font(.label)
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, Space.s)
            }
            .onChange(of: transcript?.lines.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if paused {
            EmptyState(.transcript, title: "Captions are paused", message: "They carry on when you resume.")
        } else if let transcript, transcript.lines.isEmpty {
            switch transcript.status {
            case .preparing: EmptyState(.transcript, title: "Captions are starting…", message: nil)
            case .downloading: EmptyState(.transcript, title: "Getting the speech model…",
                                          message: "A one-time download from Apple. Your audio stays on this device.")
            case .listening: EmptyState(.transcript, title: "Listening for speech…", message: "The transcript will appear here.")
            case .unavailable(let reason): EmptyState(.transcript, title: "No live captions", message: reason)
            }
        } else if transcript == nil {
            EmptyState(.transcript, title: "Live captions are off", message: "Turn them on in Settings › Recording.")
        }
    }
}

private struct Bubble: View {
    let line: LiveLine

    private var mine: Bool { line.source == .microphone }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            Text(line.text)
                .font(.base)
                .foregroundStyle(line.isFinal ? Theme.ink : Theme.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(mine ? Theme.paperSunken : Theme.paperRaised, in: Radius.shape(Radius.m))
                .overlay { if !mine { Radius.shape(Radius.m).strokeBorder(Theme.hairline) } }
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 40)
        .accessibilityLabel("\(line.source.speakerName): \(line.text)")
    }
}
