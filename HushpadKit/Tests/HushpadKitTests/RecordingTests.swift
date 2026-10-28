import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import os
@testable import HushpadCore
@testable import HushpadKit

struct SlideChangeDetectorTests {
    private func frame(_ value: UInt8, pattern: Int = 0) -> FrameSignature {
        let count = FrameSignature.columns * FrameSignature.rows
        // A non-uniform frame (text-like stripes) so it isn't treated as blank.
        return FrameSignature(lumas: (0..<count).map { i in (i / FrameSignature.columns + pattern) % 3 == 0 ? 20 : value })
    }

    @Test func keepsFirstSettledFrame() {
        var detector = SlideChangeDetector()
        let kept1 = detector.shouldKeep(frame(200), at: 0)   // need two frames to know it's settled
        #expect(!kept1)
        let kept2 = detector.shouldKeep(frame(200), at: 2)
        #expect(kept2)
    }

    @Test func ignoresSameSlide() {
        var detector = SlideChangeDetector()
        _ = detector.shouldKeep(frame(200), at: 0)
        _ = detector.shouldKeep(frame(200), at: 2)
        let kept3 = detector.shouldKeep(frame(200), at: 10)
        #expect(!kept3)
    }

    @Test func keepsNewSlideOnceSettled() {
        var detector = SlideChangeDetector()
        _ = detector.shouldKeep(frame(200), at: 0)
        _ = detector.shouldKeep(frame(200), at: 2)
        let kept4 = detector.shouldKeep(frame(200, pattern: 1), at: 10)  // transition frame
        #expect(!kept4)
        let kept5 = detector.shouldKeep(frame(200, pattern: 1), at: 12)
        #expect(kept5)
    }

    @Test func ignoresConstantlyMovingVideo() {
        var detector = SlideChangeDetector()
        for step in 0..<20 {
            let kept6 = detector.shouldKeep(frame(200, pattern: step), at: Double(step) * 2)
            #expect(!kept6)
        }
    }

    /// A screen share as Zoom and Meet show it: the shared slide, plus a strip of webcam tiles that never stops moving.
    private func sharedSlide(_ slide: Int, video step: Int) -> FrameSignature {
        let columns = FrameSignature.columns
        return FrameSignature(lumas: (0..<columns * FrameSignature.rows).map { i in
            let row = i / columns, column = i % columns
            if row < 4 { return UInt8((column * 37 + step * 91 + row * 13) % 256) }  // webcams: different every frame
            return (row + slide) % 3 == 0 ? 20 : 200                                // the slide
        })
    }

    @Test func keepsSlidesNextToMovingWebcams() {
        var detector = SlideChangeDetector()
        var keptA = 0, keptB = 0
        for step in 0..<6 where detector.shouldKeep(sharedSlide(0, video: step), at: Double(step) * 2) { keptA += 1 }
        for step in 6..<12 where detector.shouldKeep(sharedSlide(1, video: step), at: Double(step) * 2) { keptB += 1 }
        #expect(keptA == 1)
        #expect(keptB == 1)
    }

    @Test func ignoresBlankScreens() {
        var detector = SlideChangeDetector()
        let black = FrameSignature(lumas: Array(repeating: 0, count: FrameSignature.columns * FrameSignature.rows))
        _ = detector.shouldKeep(black, at: 0)
        let kept7 = detector.shouldKeep(black, at: 2)
        #expect(!kept7)
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
