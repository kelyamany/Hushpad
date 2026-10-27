import CoreGraphics
import Foundation
import Testing
@testable import LocalScribeKit
import LocalScribeUI

/// A 1440×900 screen with the menu bar cut off the top, in AppKit's bottom-left coordinates.
private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
private let compact = CGSize(width: 54, height: 84)
private let card = CGSize(width: 147, height: 184)

@Suite struct NubGeometryTests {
    @Test func defaultFrameIsFlushRightAndOnScreen() {
        let frame = NubGeometry.defaultFrame(size: compact, in: screen)
        #expect(frame.size == compact)
        #expect(frame.maxX == screen.maxX)
        #expect(screen.contains(frame))
    }

    @Test func snapsToLeadingWhenLeftOfCentre() {
        let frame = CGRect(x: 300, y: 400, width: compact.width, height: compact.height)
        let result = NubGeometry.snapped(frame, in: screen)
        #expect(result.side == .leading)
        #expect(result.frame.minX == screen.minX)
        #expect(result.frame.minY == frame.minY)
        #expect(screen.contains(result.frame))
    }

    @Test func snapsToTrailingWhenRightOfCentre() {
        let frame = CGRect(x: 1000, y: 400, width: compact.width, height: compact.height)
        let result = NubGeometry.snapped(frame, in: screen)
        #expect(result.side == .trailing)
        #expect(result.frame.maxX == screen.maxX)
        #expect(result.frame.minY == frame.minY)
        #expect(screen.contains(result.frame))
    }

    @Test func clampedKeepsInsideFrameUnchanged() {
        let frame = CGRect(x: 500, y: 300, width: 200, height: 100)
        #expect(NubGeometry.clamped(frame, in: screen) == frame)
    }

    @Test func clampedPullsOverflowingFrameInside() {
        let frame = CGRect(x: -50, y: 1000, width: 54, height: 84)
        let result = NubGeometry.clamped(frame, in: screen)
        #expect(screen.contains(result))
        #expect(result.minX == screen.minX)
        #expect(result.maxY == screen.maxY)
    }

    @Test func resizedKeepsTopEdgeAndTrailingSide() {
        let frame = CGRect(x: screen.maxX - compact.width, y: 400, width: compact.width, height: compact.height)
        let result = NubGeometry.resized(frame, to: card, side: .trailing, in: screen)
        #expect(result.size == card)
        #expect(result.maxY == frame.maxY)
        #expect(result.maxX == screen.maxX)
        #expect(screen.contains(result))
    }

    @Test func resizedKeepsTopEdgeAndLeadingSide() {
        let frame = CGRect(x: screen.minX, y: 400, width: compact.width, height: compact.height)
        let result = NubGeometry.resized(frame, to: card, side: .leading, in: screen)
        #expect(result.size == card)
        #expect(result.maxY == frame.maxY)
        #expect(result.minX == screen.minX)
        #expect(screen.contains(result))
    }

    @Test func fractionRoundTripsThroughFrame() {
        for side in [NubGeometry.Side.leading, .trailing] {
            for fraction in [0.0, 0.25, 0.5, 0.7, 1.0] {
                let frame = NubGeometry.frame(size: compact, side: side, fraction: fraction, in: screen)
                #expect(screen.contains(frame))
                #expect(abs(NubGeometry.fraction(of: frame, in: screen) - fraction) < 0.001)
            }
        }
    }

    @Test func fractionIsZeroAtTopAndOneAtBottom() {
        let top = NubGeometry.frame(size: compact, side: .trailing, fraction: 0, in: screen)
        let bottom = NubGeometry.frame(size: compact, side: .trailing, fraction: 1, in: screen)
        #expect(top.maxY == screen.maxY)
        #expect(bottom.minY == screen.minY)
    }

    @Test func restingBarShowsOnlyTheDotInSilence() {
        for sensitivity in [1.0, 2.0] {
            for jitter in [0.0, 0.5, 1.0] {
                #expect(DancingBars.visibleHalf(gain: 0, sensitivity: sensitivity, jitter: jitter) == DancingBars.restingVisible)
            }
        }
        #expect(DancingBars.restingVisible == 1)
    }

    @Test func visibleHalfIsCappedByMaxAndHalfHeight() {
        for gain in stride(from: 0.0, through: 3.0, by: 0.1) {
            for sensitivity in [1.0, 2.0] {
                for jitter in [0.0, 0.5, 1.0] {
                    let visible = DancingBars.visibleHalf(gain: gain, sensitivity: sensitivity, jitter: jitter)
                    #expect(visible <= 7)
                    #expect(visible <= DancingBars.halfHeight)
                    #expect(visible >= DancingBars.restingVisible)
                }
            }
        }
    }

    @Test func middleBarIsAtLeastAsTallAsOuterBars() {
        for gain in [0.1, 0.3, 0.5, 0.8, 1.0] {
            for jitter in [0.0, 0.5, 1.0] {
                let middle = DancingBars.visibleHalf(gain: gain, sensitivity: 1, jitter: jitter)
                let outer = DancingBars.visibleHalf(gain: gain, sensitivity: 2, jitter: jitter)
                #expect(middle >= outer, "gain \(gain), jitter \(jitter)")
            }
        }
    }

    @Test func gainIsZeroAtOrBelowQuarterMeter() {
        #expect(DancingBars.gain(meter: 0) == 0)
        #expect(DancingBars.gain(meter: 0.1) == 0)
        #expect(DancingBars.gain(meter: 0.25) == 0)
    }

    @Test func gainIncreasesAboveQuarterMeter() {
        let quiet = DancingBars.gain(meter: 0.3)
        let loud = DancingBars.gain(meter: 0.6)
        let loudest = DancingBars.gain(meter: 1.0)
        #expect(quiet > 0)
        #expect(loud > quiet)
        #expect(loudest > loud)
    }
}
