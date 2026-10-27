import SwiftUI

/// LocalScribe's mark: a sound wave that settles into a handwritten line ("listen → notes").
/// Used in the icon, onboarding and illustrations. Drawn left to right in a unit box.
public struct SoundLine: Shape {
    /// How much of the width is "sound" before it becomes "writing".
    public var waveShare: CGFloat
    public init(waveShare: CGFloat = 0.48) { self.waveShare = waveShare }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 160
        let midY = rect.midY
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = rect.minX + t * rect.width
            let y: CGFloat
            if t < waveShare {
                // Sound: a quick wave whose amplitude swells, then fades as it reaches the "pen".
                let local = t / waveShare
                let envelope = sin(local * .pi) * (1 - local * 0.35)
                y = midY - sin(local * .pi * 7) * envelope * rect.height * 0.5
            } else {
                // Writing: a slow, slightly irregular cursive wobble.
                let local = (t - waveShare) / (1 - waveShare)
                let wobble = sin(local * .pi * 3.2) * 0.10 + sin(local * .pi * 7.5) * 0.045
                y = midY - wobble * rect.height * (1 - local * 0.4)
            }
            step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

/// Line-art illustrations for empty states: a paper card on a soft disc, a glyph in ink, and the sound line
/// in the accent colour. Pure shapes: vector, theme-aware, cheap to draw, no image assets.
public struct Vignette: View {
    public enum Kind {
        case library, folder, search, transcript, notes, screens, watch, done

        var symbol: String {
            switch self {
            case .library: "book.closed"
            case .folder: "folder"
            case .search: "magnifyingglass"
            case .transcript: "text.bubble"
            case .notes: "sparkles"
            case .screens: "rectangle.on.rectangle"
            case .watch: "applewatch"
            case .done: "checkmark"
            }
        }
    }

    public var kind: Kind
    public var size: CGFloat
    public init(_ kind: Kind, size: CGFloat = 120) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(Theme.paperSunken)
            // A card behind, tilted.
            Radius.shape(size * 0.1)
                .fill(Theme.paperRaised)
                .overlay(Radius.shape(size * 0.1).strokeBorder(Theme.hairline))
                .frame(width: size * 0.46, height: size * 0.58)
                .rotationEffect(.degrees(-9))
                .offset(x: -size * 0.09, y: -size * 0.02)
            // The front card, with ruled lines.
            Radius.shape(size * 0.1)
                .fill(Theme.paperRaised)
                .overlay(Radius.shape(size * 0.1).strokeBorder(Theme.hairline))
                .overlay(alignment: .bottom) {
                    VStack(spacing: size * 0.05) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(Theme.hairline)
                                .frame(width: size * (index == 2 ? 0.2 : 0.3), height: max(1.5, size * 0.016))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, size * 0.07)
                    .padding(.bottom, size * 0.08)
                }
                .overlay(alignment: .top) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: size * 0.17, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, size * 0.09)
                }
                .frame(width: size * 0.46, height: size * 0.58)
                .rotationEffect(.degrees(5))
                .offset(x: size * 0.06)
            SoundLine()
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: max(2, size * 0.022), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.84, height: size * 0.16)
                .offset(y: size * 0.31)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        Vignette(.library)
        Vignette(.search)
        Vignette(.notes)
    }
    .padding()
    .background(Theme.paper)
}
