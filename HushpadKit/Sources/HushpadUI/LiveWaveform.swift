import SwiftUI

/// Scrolling bar waveform driven by the live input level (0…1). Newest bar on the right.
/// With Reduce Motion it becomes a static level bar.
public struct LiveWaveform: View {
    private let level: () -> Float
    private let bars: Int
    private let color: Color
    @State private var history: History

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(bars: Int = 32, color: Color = Theme.record, level: @escaping () -> Float) {
        self.level = level
        self.bars = bars
        self.color = color
        _history = State(initialValue: History(capacity: bars))
    }

    public var body: some View {
        if reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                GeometryReader { proxy in
                    Capsule().fill(color.opacity(0.2))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: proxy.size.width * CGFloat(level()))
                        }
                }
                .frame(height: 6)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                Canvas { canvas, size in
                    let values = history.push(level(), at: context.date)
                    let slot = size.width / CGFloat(bars)
                    let barWidth = max(2, slot * 0.55)
                    for (index, value) in values.enumerated() {
                        let height = max(barWidth, size.height * CGFloat(value))
                        let x = slot * CGFloat(index) + (slot - barWidth) / 2
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                        // Older bars fade out to the left.
                        let opacity = 0.25 + 0.75 * Double(index) / Double(max(bars - 1, 1))
                        canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(opacity)))
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Fixed-size ring of recent levels. A reference type so the Canvas can append without re-rendering loops.
    final class History {
        private var values: [Float]
        private var lastPush = Date.distantPast
        init(capacity: Int) { values = Array(repeating: 0, count: capacity) }

        func push(_ level: Float, at date: Date) -> [Float] {
            guard date.timeIntervalSince(lastPush) >= 0.045 else { return values }
            lastPush = date
            // Ease the curve so quiet speech is visible and loud speech doesn't clip.
            let shaped = Float(pow(Double(max(0, min(1, level))), 1.6))
            values.removeFirst()
            values.append(shaped)
            return values
        }
    }
}
