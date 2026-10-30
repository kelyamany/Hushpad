import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import os
@testable import HushpadCore
@testable import HushpadKit

struct SlideChangeDetectorTests {
    private static let cells = FrameSignature.columns * FrameSignature.rows

    /// A non-uniform frame (text-like stripes) so it isn't treated as blank; `slide` shifts the stripes.
    private func frame(_ slide: Int = 0) -> FrameSignature {
        FrameSignature(lumas: (0..<Self.cells).map { i in (i / FrameSignature.columns + slide) % 3 == 0 ? 20 : 200 })
    }

    /// Feeds one frame every 2 s (the capture loop's pace) from `start`, returning the times something was kept.
    private func run(_ detector: inout SlideChangeDetector, from start: Double = 0, _ frames: [FrameSignature]) -> [Double] {
        frames.enumerated().compactMap { step, frame in
            let time = start + Double(step) * 2
            return detector.shouldKeep(frame, at: time) ? time : nil
        }
    }

    @Test func keepsASlideOnceStillForSixSeconds() {
        var detector = SlideChangeDetector()
        #expect(run(&detector, Array(repeating: frame(), count: 6)) == [6])
    }

    @Test func waitsOutTheBuffer() {
        var detector = SlideChangeDetector()
        #expect(run(&detector, Array(repeating: frame(), count: 3)).isEmpty)  // still for only 4 s
    }

    @Test func keepsEachNewSlideOnceButNotRepeats() {
        var detector = SlideChangeDetector()
        let slides = Array(repeating: frame(0), count: 6) + Array(repeating: frame(1), count: 6) + Array(repeating: frame(0), count: 2)
        #expect(run(&detector, slides) == [6, 18])
    }

    @Test func waitsUntilTypingStops() {
        var detector = SlideChangeDetector()
        var lumas = frame().lumas
        var frames = Array(repeating: FrameSignature(lumas: lumas), count: 4)  // the document, still: kept at 6 s
        // Then someone types for 20 s (t = 8…26): a line of text appears every 2 s, a third of a row at a time.
        for step in 0..<10 {
            let row = 1 + step * 3
            for column in 0..<FrameSignature.columns { lumas[row * FrameSignature.columns + column] = 90 }
            frames.append(FrameSignature(lumas: lumas))
        }
        frames += Array(repeating: FrameSignature(lumas: lumas), count: 5)  // t = 28…36, still again
        #expect(run(&detector, frames) == [6, 32])  // nothing while typing; kept 6 s after the last keystroke
    }

    @Test func toleratesABlinkingCursor() {
        var detector = SlideChangeDetector()
        let frames = (0..<6).map { step -> FrameSignature in
            var lumas = frame().lumas
            if step.isMultiple(of: 2) { lumas[FrameSignature.columns * 10 + 10] = 120 }  // one cell flickers
            return FrameSignature(lumas: lumas)
        }
        #expect(run(&detector, frames) == [6])
    }

    @Test func neverKeepsAPlayingVideo() {
        var detector = SlideChangeDetector()
        // A video or a spinning 3D model in the share: a large region differs on every check.
        let frames = (0..<20).map { step in
            FrameSignature(lumas: (0..<Self.cells).map { i in
                i % FrameSignature.columns < 40 ? UInt8((i * 37 + step * 91) % 256) : ((i / FrameSignature.columns) % 3 == 0 ? 20 : 200)
            })
        }
        #expect(run(&detector, frames).isEmpty)
    }

    @Test func resetStartsTheBufferOverWithoutDuplicating() {
        var detector = SlideChangeDetector()
        #expect(run(&detector, Array(repeating: frame(0), count: 4)) == [6])
        detector.reset()  // the share blinked off and on
        #expect(run(&detector, from: 20, Array(repeating: frame(0), count: 4)).isEmpty)
        detector.reset()  // a new share
        #expect(run(&detector, from: 40, Array(repeating: frame(1), count: 4)) == [46])
    }

    @Test func ignoresBlankScreens() {
        var detector = SlideChangeDetector()
        let black = FrameSignature(lumas: Array(repeating: 0, count: Self.cells))
        #expect(run(&detector, Array(repeating: black, count: 6)).isEmpty)
    }

    @Test func storeParsesTimestampsFromFileNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ScreenshotStore.save(jpeg: Data([0xFF, 0xD8]), at: 12.345, in: folder)
        try ScreenshotStore.save(jpeg: Data([0xFF, 0xD8]), at: 3, in: folder)
        #expect(ScreenshotStore.list(in: folder).map(\.time) == [3, 12.345])
    }

    @Test func removedScreenshotsCanBeRestored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ScreenshotStore.save(jpeg: Data([0xFF, 0xD8, 0x01]), at: 2, in: folder)
        try ScreenshotStore.save(jpeg: Data([0xFF, 0xD8, 0x02]), at: 7.5, in: folder)
        let shots = ScreenshotStore.list(in: folder)

        let (removed, failed) = ScreenshotStore.remove(shots)
        #expect(failed == 0 && removed.count == 2)
        #expect(ScreenshotStore.list(in: folder).isEmpty)

        try ScreenshotStore.restore(removed)
        let back = ScreenshotStore.list(in: folder)
        #expect(back.map(\.time) == [2, 7.5])
        #expect(try back.map { try Data(contentsOf: $0.url) } == [Data([0xFF, 0xD8, 0x01]), Data([0xFF, 0xD8, 0x02])])
    }

    @Test func addsImageFilesInOrderAndSkipsOthers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for url in [folder, inbox] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        func png(_ name: String) throws -> URL {
            let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let url = inbox.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
        let text = inbox.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: text)

        let added = ScreenshotStore.add(imageFiles: [try png("a.png"), text, try png("b.png")], at: 0, in: folder)

        #expect(added.count == 2)
        #expect(ScreenshotStore.list(in: folder).map(\.time) == [0, 0.001])
    }
}

struct TrackWriterTests {
    @Test func convertsToSixteenKilohertzMonoAndPadsGaps() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let start = mach_absolute_time()
        let writer = try TrackWriter(url: url, startHostTime: start)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for i in 0..<48_000 { buffer.floatChannelData![channel][i] = sin(Float(i) * 0.05) * 0.5 }
        }
        // First second of audio arrives 1 s late (e.g. system audio started late): expect 1 s of padding.
        writer.append(buffer, hostTime: start + AVAudioTime.hostTime(forSeconds: 1))
        let summary = writer.finish()

        #expect(abs(summary.duration - 2) < 0.05, "duration \(summary.duration)")
        #expect(summary.peak > 0.4)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / 16_000 - summary.duration) < 0.01)
    }

    /// Regression: the live-captions callback was re-wrapped on every buffer, so after a couple of minutes of audio
    /// calling it recursed through thousands of thunks and overflowed the writer queue's stack.
    @Test func audioSinkCallDepthStaysFlat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = mach_absolute_time()
        let writer = try TrackWriter(url: url, startHostTime: start)
        let depths = OSAllocatedUnfairLock<[Int]>(initialState: [])
        writer.onAudio = { _, _ in
            let depth = Thread.callStackSymbols.count
            depths.withLock { $0.append(depth) }
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        for index in 0..<2_000 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            writer.append(buffer, hostTime: start + AVAudioTime.hostTime(forSeconds: Double(index) * 0.01))
        }
        _ = writer.finish()
        let seen = depths.withLock { $0 }
        #expect(seen.count > 1_900)
        #expect((seen.max() ?? 0) - (seen.min() ?? 0) < 5, "call depth grew from \(seen.min() ?? 0) to \(seen.max() ?? 0)")
    }
}
