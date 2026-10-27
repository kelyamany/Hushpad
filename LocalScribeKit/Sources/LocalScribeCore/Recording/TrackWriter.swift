@preconcurrency import AVFoundation
import os

/// Takes audio buffers in any format, converts them to 16 kHz mono (what Whisper and the diarizer expect)
/// and appends them to a WAV file.
///
/// Every buffer is placed on a timeline shared by all tracks of a recording, measured from `startHostTime`.
/// Gaps (device switch, phone call interruption, late start) are filled with silence,
/// so the mic and system tracks always line up sample-for-sample.
public final class TrackWriter: @unchecked Sendable {
    public static let sampleRate = 16_000

    public struct Summary: Sendable {
        public var duration: Double
        /// Loudest sample seen. 0 means the track was pure silence (e.g. system audio permission denied).
        public var peak: Float
        /// Set when writing stopped early (disk full, file removed). Everything after that point is missing.
        public var failure: String?
    }

    private let queue: DispatchQueue
    private let file: WAVFile
    private let startSeconds: Double
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                             channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var framesWritten: Int64 = 0
    private var failed: Error? { didSet { failure.withLock { $0 = failed?.localizedDescription } } }
    private let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let meter = OSAllocatedUnfairLock(initialState: (level: Float(0), peak: Float(0)))

    public init(url: URL, startHostTime: UInt64) throws {
        file = try WAVFile(url: url, sampleRate: Self.sampleRate)
        startSeconds = AVAudioTime.seconds(forHostTime: startHostTime)
        queue = DispatchQueue(label: "LocalScribe.TrackWriter.\(url.lastPathComponent)", qos: .userInitiated)
    }

    /// Current input level 0...1 for the UI meter.
    public var level: Float { meter.withLock { $0.level } }

    /// While paused, incoming audio is dropped. The timeline gap is filled with silence on resume,
    /// so the tracks and screenshots stay aligned.
    public var isPaused: Bool {
        get { paused.withLock { $0 } }
        set {
            paused.withLock { $0 = newValue }
            if newValue { meter.withLock { $0.level = 0 } }
        }
    }

    /// Receives every converted 16 kHz mono buffer with its start on the recording's timeline (seconds), on the writer's
    /// queue, right after it is written. Used for live captions. Must return quickly and must not keep the buffer.
    public var onAudio: (@Sendable (AVAudioPCMBuffer, Double) -> Void)? {
        get { audioSink.withLock { $0 }?.handler }
        set { audioSink.withLock { $0 = newValue.map(AudioSink.init) } }
    }
    /// The callback lives in a class box: a closure stored directly in the lock's generic state is re-wrapped in
    /// reabstraction thunks on every access, and after a few thousand buffers calling it overflows the stack.
    private let audioSink = OSAllocatedUnfairLock<AudioSink?>(initialState: nil)
    private final class AudioSink: Sendable {
        let handler: @Sendable (AVAudioPCMBuffer, Double) -> Void
        init(_ handler: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) { self.handler = handler }
    }

    /// Why writing stopped early, while recording is still running. Nil while all is well.
    public var writeFailure: String? { failure.withLock { $0 } }

    /// Safe to call from realtime audio threads: copies the samples and does all work on a private queue.
    public func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard !isPaused, buffer.frameLength > 0, let copied = Self.copy(buffer) else { return }
        // The copy is owned exclusively by the queue from here on.
        nonisolated(unsafe) let copy = copied
        queue.async { self.process(copy, hostTime: hostTime) }
    }

    public func finish() -> Summary {
        queue.sync {
            drain()
            try? file.close()
            return Summary(duration: Double(framesWritten) / Double(Self.sampleRate), peak: meter.withLock { $0.peak },
                           failure: failed?.localizedDescription)
        }
    }

    // MARK: - Private (on `queue`)

    private func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard failed == nil else { return }
        do {
            // Pad silence if this buffer starts noticeably later than what we've written so far.
            let startTime = max(0, AVAudioTime.seconds(forHostTime: hostTime) - startSeconds)
            let expectedFrame = Int64(startTime * Double(Self.sampleRate))
            let gap = expectedFrame - framesWritten
            if gap > Int64(Self.sampleRate / 10) { try writeSilence(frames: gap) }

            guard let converted = convert(buffer) else { return }
            let start = Double(framesWritten) / Double(Self.sampleRate)
            try write(converted)
            audioSink.withLock { $0 }?.handler(converted, start)
        } catch {
            failed = error
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let feed = InputFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in feed.next(outStatus) }
        return status == .error ? nil : output
    }

    /// The resampler holds back a few milliseconds of audio; flush it at the end of the recording.
    private func drain() {
        guard failed == nil, let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Self.sampleRate)) else { return }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if status != .error { try? write(output) }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: count)
        var sumSquares: Float = 0, peak: Float = 0
        for i in 0..<count {
            let value = max(-1, min(1, channel[i]))
            samples[i] = Int16(value * Float(Int16.max))
            sumSquares += value * value
            peak = max(peak, abs(value))
        }
        try file.append(samples)
        framesWritten += Int64(count)
        let rms = count > 0 ? (sumSquares / Float(count)).squareRoot() : 0
        let bufferPeak = peak
        // dB scale (-50…0 dBFS → 0…1): a quiet room voice still moves the meter.
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
        meter.withLock { $0.level = level; $0.peak = max($0.peak, bufferPeak) }
    }

    private func writeSilence(frames: Int64) throws {
        var remaining = frames
        let chunk = [Int16](repeating: 0, count: Self.sampleRate)
        while remaining > 0 {
            let n = Int(min(remaining, Int64(chunk.count)))
            try file.append(Array(chunk[0..<n]))
            remaining -= Int64(n)
            framesWritten += Int64(n)
        }
    }

    /// Deep copy, because Core Audio reuses its buffers once the callback returns.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }
}

/// Hands the converter one buffer, then reports "no more data for now".
private final class InputFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
