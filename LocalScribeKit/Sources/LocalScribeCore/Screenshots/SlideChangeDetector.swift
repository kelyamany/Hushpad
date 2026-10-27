import CoreGraphics
import Foundation

/// A tiny grayscale thumbnail of a frame, used to tell "new slide" apart from "same slide" or "people moving on video".
public struct FrameSignature: Equatable, Sendable {
    public static let columns = 32, rows = 18
    public var lumas: [UInt8]

    public init(lumas: [UInt8]) {
        self.lumas = lumas
    }

    public init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: Self.columns, height: Self.rows, bitsPerComponent: 8,
                                          bytesPerRow: Self.columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
            return true
        }
        guard drawn else { return nil }
        lumas = pixels
    }

    /// Fraction of cells whose brightness differs by more than `threshold` (0–255), among the cells in `mask`
    /// (all cells when nil).
    public func changedFraction(from other: FrameSignature, threshold: Int = 12, among mask: [Bool]? = nil) -> Double {
        guard lumas.count == other.lumas.count, !lumas.isEmpty else { return 1 }
        let changed = changedCells(from: other, threshold: threshold)
        let considered = mask.map { $0.filter { $0 }.count } ?? lumas.count
        guard considered > 0 else { return 1 }
        let count = changed.indices.filter { changed[$0] && (mask?[$0] ?? true) }.count
        return Double(count) / Double(considered)
    }

    /// Which cells differ by more than `threshold`.
    public func changedCells(from other: FrameSignature, threshold: Int = 12) -> [Bool] {
        guard lumas.count == other.lumas.count else { return Array(repeating: true, count: lumas.count) }
        return zip(lumas, other.lumas).map { abs(Int($0) - Int($1)) > threshold }
    }

    /// Nearly uniform frames (black screen, loading spinner) are not worth keeping.
    public var isBlank: Bool {
        guard let low = lumas.min(), let high = lumas.max() else { return true }
        return Int(high) - Int(low) < 10
    }
}

/// Decides when to keep a screenshot during screen sharing: once the picture settles on something
/// substantially different from the last kept screenshot (a new slide, a new document, a scrolled page).
///
/// Meeting apps show webcam tiles next to what's being shared, and those never stop moving. Cells that keep changing
/// are treated as video and left out when judging whether the rest has settled or is new. A picture that is mostly
/// video (a gallery of webcams) is never kept.
public struct SlideChangeDetector: Sendable {
    /// At most this fraction of cells may change between consecutive frames for the frame to count as "settled".
    public var stableFraction = 0.03
    /// At least this fraction must differ from the last kept screenshot to count as new content.
    public var newContentFraction = 0.12
    /// Never keep two automatic screenshots closer together than this.
    public var minInterval: Double = 4

    /// A cell counts as video when it changed in at least 2 of the last this-many comparisons.
    public var videoMemory = 3
    /// Keep nothing while more than this fraction of the picture is video.
    public var maxVideoFraction = 0.4

    private var previous: FrameSignature?
    private var lastKept: FrameSignature?
    private var lastKeptTime = -Double.infinity
    /// Which cells changed, for the last few comparisons (oldest first).
    private var recentChanges: [[Bool]] = []

    public init() {}

    public mutating func shouldKeep(_ frame: FrameSignature, at time: Double) -> Bool {
        defer { previous = frame }
        guard let previous else { return false }
        let changed = frame.changedCells(from: previous)
        // Video is judged from earlier comparisons, so a slide change (one big change) isn't mistaken for it.
        let still = stillCells(count: changed.count)
        recentChanges.append(changed)
        if recentChanges.count > videoMemory { recentChanges.removeFirst() }

        let videoFraction = 1 - Double(still.filter { $0 }.count) / Double(max(still.count, 1))
        guard videoFraction <= maxVideoFraction else { return false }
        guard frame.changedFraction(from: previous, among: still) <= stableFraction else { return false }
        guard !frame.isBlank, time - lastKeptTime >= minInterval else { return false }
        if let lastKept, frame.changedFraction(from: lastKept, among: still) < newContentFraction { return false }
        markKept(frame, at: time)
        return true
    }

    /// Cells that are not video: changed in fewer than 2 of the recent comparisons.
    private func stillCells(count: Int) -> [Bool] {
        (0..<count).map { cell in
            recentChanges.reduce(0) { $0 + ($1.indices.contains(cell) && $1[cell] ? 1 : 0) } < 2
        }
    }

    /// Manual screenshots count as kept, so the automatic mode doesn't duplicate them.
    public mutating func markKept(_ frame: FrameSignature, at time: Double) {
        lastKept = frame
        lastKeptTime = time
    }
}
