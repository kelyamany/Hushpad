import HushpadKit
import HushpadUI
import SwiftUI

/// Play / pause, scrubber, skip and speed. Floats over the bottom of the transcript.
struct PlaybackBar: View {
    @Bindable var player: PlaybackController
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .accessibilityLabel("Back 15 seconds")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.heading)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .accessibilityLabel("Forward 15 seconds")

            VStack(spacing: 2) {
                Slider(value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }),
                       in: 0...max(player.duration, 1)) { editing in
                    if !editing, let scrubbing {
                        player.seek(to: scrubbing)
                        self.scrubbing = nil
                    }
                }
                .controlSize(.mini)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Exporter.clock(scrubbing ?? player.currentTime)) of \(Exporter.clock(player.duration))")
                HStack {
                    Text(Exporter.clock(scrubbing ?? player.currentTime))
                    Spacer()
                    if player.loadFailed {
                        Label("Some audio can't be played", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                        Spacer()
                    }
                    Text(Exporter.clock(player.duration))
                }
                .font(.micro.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Menu {
                Picker("Speed", selection: $player.rate) {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
            } label: {
                Text("\(player.rate.formatted())×").font(.label.monospacedDigit().weight(.semibold)).frame(minWidth: 34)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Playback speed")
            .accessibilityValue("\(player.rate.formatted()) times")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
    }
}
