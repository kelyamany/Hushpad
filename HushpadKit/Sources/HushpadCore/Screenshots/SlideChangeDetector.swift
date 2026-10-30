import CoreGraphics
import Foundation

/// A small grayscale thumbnail of a frame, used to tell "new slide" apart from "same slide" or "still moving".
/// Fine enough (64×36) that typing a few words changes some cells.
public struct FrameSignature: Equatable, Sendable {
    public static let columns = 64, rows = 36
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

    /// Fraction of cells whose brightness differs by more than `threshold` (0–255).
    public func changedFraction(from other: FrameSignature, threshold: Int = 12) -> Double {
        guard lumas.count == other.lumas.count, !lumas.isEmpty else { return 1 }
        return Double(changedCells(from: other, threshold: threshold).filter { $0 }.count) / Double(lumas.count)
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

/// Decides when to keep a screenshot of a shared screen: once the picture has stayed still for `settleSeconds`
/// and is substantially different from the last kept screenshot (a new slide, a new document, a scrolled page).
///
/// The buffer is what skips things in motion: while someone types, scrolls, plays a video or spins a 3D model, the
/// picture keeps changing, so the timer keeps restarting and nothing is kept until it settles.
public struct SlideChangeDetector: Sendable {
    /// How long the picture must stay unchanged before it's kept.
    public var settleSeconds: Double = 6
    /// A cell counts as changed between two checks when its brightness moves by more than this (0–255). Above
    /// video-compression noise and a blinking text cursor, below a typed character.
    public var settleThreshold = 16
    /// At most this many cells may change between checks for the picture to count as still.
    public var settleTolerance = 1
    /// At least this fraction must differ from the last kept screenshot to count as new content.
    public var newContentFraction = 0.12
    /// Never keep two automatic screenshots closer together than this.
    public var minInterval: Double = 4

    private var previous: FrameSignature?
    /// When the picture last changed (the start of the current still stretch).
    private var stillSince: Double?
    private var lastKept: FrameSignature?
    private var lastKeptTime = -Double.infinity

    public init() {}

    public mutating func shouldKeep(_ frame: FrameSignature, at time: Double) -> Bool {
        defer { previous = frame }
        guard let previous, frame.changedCells(from: previous, threshold: settleThreshold).filter({ $0 }).count <= settleTolerance else {
            stillSince = time
            return false
        }
        let since = stillSince ?? time
        stillSince = since
        guard time - since >= settleSeconds, !frame.isBlank, time - lastKeptTime >= minInterval else { return false }
        if let lastKept, frame.changedFraction(from: lastKept) < newContentFraction { return false }
        markKept(frame, at: time)
        return true
    }

    /// Starts the buffer over, for a share that started, ended or moved. The last kept screenshot is remembered,
    /// so a share that blinks off and on doesn't produce a duplicate.
    public mutating func reset() {
        previous = nil
        stillSince = nil
    }

    /// Manual screenshots count as kept, so the automatic mode doesn't duplicate them.
    public mutating func markKept(_ frame: FrameSignature, at time: Double) {
        lastKept = frame
        lastKeptTime = time
    }
}
