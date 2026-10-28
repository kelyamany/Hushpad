import SwiftUI

/// Measurements of the floating recording "nub":
/// a 34 pt dark pill docked to the side of the screen, the app mark on top and three "dancing bars" below.
public enum NubMetrics {
    /// The pill in its normal (recording) state.
    public static let pillWidth: CGFloat = 34
    public static let cell = CGSize(width: 32, height: 30)
    public static let pillRadius: CGFloat = 17
    /// Gap between the pill and the screen edge it is docked to.
    public static let edgeInset: CGFloat = 4
    /// The panel is a little larger than the pill so it can grow on hover without resizing the window.
    public static let compactWindow = CGSize(width: 54, height: 84)
    /// "Meeting detected" card: narrow without a title, wider with one.
    public static let promptWindow = CGSize(width: 123, height: 152)
    public static let promptWindowWithTitle = CGSize(width: 147, height: 184)
    public static let promptRadius: CGFloat = 16
    /// A new nub sits 70% of the way down the screen.
    static let defaultHeightFraction: CGFloat = 0.7
    static let defaultHeightOffset: CGFloat = 37
}

/// Where the nub sits. Pure geometry in AppKit's bottom-left screen coordinates, so it can be tested.
public enum NubGeometry {
    /// The side of the screen the nub is docked to.
    public enum Side: String, Codable, Sendable { case leading, trailing }

    /// A new nub: flush with the right edge, 70% of the way down.
    public static func defaultFrame(size: CGSize, in visible: CGRect) -> CGRect {
        let fromTop = ((visible.height - NubMetrics.defaultHeightOffset) * NubMetrics.defaultHeightFraction).rounded()
        return clamped(CGRect(x: visible.maxX - size.width, y: visible.maxY - fromTop - size.height,
                              width: size.width, height: size.height), in: visible)
    }

    /// After a drag: snaps to whichever side edge the nub's centre is closer to, keeping its height on screen.
    public static func snapped(_ frame: CGRect, in visible: CGRect) -> (frame: CGRect, side: Side) {
        let side: Side = frame.midX < visible.midX ? .leading : .trailing
        return (docked(frame, side: side, in: visible), side)
    }

    /// Puts a frame of any size against `side`, clamped to the screen.
    public static func docked(_ frame: CGRect, side: Side, in visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = side == .leading ? visible.minX : visible.maxX - frame.width
        return clamped(result, in: visible)
    }

    /// Resizes while keeping the docked side and the top edge where they are (the card grows down and inward).
    public static func resized(_ frame: CGRect, to size: CGSize, side: Side, in visible: CGRect) -> CGRect {
        let resized = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        return docked(resized, side: side, in: visible)
    }

    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    /// Saved position: the side plus how far down the screen the top edge is (0 top … 1 bottom),
    /// so it survives resolution changes.
    public static func fraction(of frame: CGRect, in visible: CGRect) -> Double {
        guard visible.height > frame.height else { return 0 }
        return Double((visible.maxY - frame.maxY) / (visible.height - frame.height)).clamped(to: 0...1)
    }

    public static func frame(size: CGSize, side: Side, fraction: Double, in visible: CGRect) -> CGRect {
        let top = visible.maxY - CGFloat(fraction) * (visible.height - size.height)
        return docked(CGRect(x: 0, y: top - size.height, width: size.width, height: size.height), side: side, in: visible)
    }
}

/// The "dancing bars": three 2 pt bars, mirrored around a centre line, each half clipped to 10 pt.
/// Louder audio shows more of each bar; the middle bar is twice as sensitive as the outer two.
public enum DancingBars {
    public static let barWidth: CGFloat = 2
    public static let gap: CGFloat = 3
    public static let halfHeight: CGFloat = 10
    /// Tallest visible half of a bar.
    static let maxVisible: CGFloat = 7
    /// What shows during silence: a dot.
    public static let restingVisible: CGFloat = 1
    /// After this much silence the bars turn red: "we're not hearing anything".
    public static let silenceWarning: Duration = .seconds(3)

    /// Visible height of one half of a bar. `gain` is roughly 0 (silence) … 1 (loud speech);
    /// `sensitivity` is 1 for the middle bar and 2 for the outer ones (higher = less movement);
    /// `jitter` in 0…1 keeps the bars from moving in lockstep.
    public static func visibleHalf(gain: Double, sensitivity: Double, jitter: Double) -> CGFloat {
        guard gain > 0 else { return restingVisible }
        let scale = (jitter.clamped(to: 0...1) * 0.4 + 0.6) * sensitivity
        let shown = min((Double(maxVisible) * gain / scale).rounded(.down) + 1.5, Double(maxVisible))
        return CGFloat(halfHeight - (Double(halfHeight) - shown).rounded())
    }

    /// Maps the recorder's 0…1 meter (−50…0 dBFS) to the bars' gain: room noise stays still, speech moves them.
    public static func gain(meter: Float) -> Double {
        max(0, Double(meter) - 0.25) * 2.4
    }

    /// The meter value below which there is effectively no signal (about −49 dBFS: a dead or muted input, not a pause
    /// in conversation). Only this turns the bars red.
    public static let silenceMeter: Float = 0.02
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
