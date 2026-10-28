import AVFoundation

/// Records the microphone: the people in the room, including you.
/// Survives device switches (AirPods connecting, USB mic unplugged) and, on iOS, phone-call interruptions;
/// gaps are padded by the `TrackWriter` so timing stays correct.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer: TrackWriter
    private var observers: [NSObjectProtocol] = []
    private var running = false

    public init(writer: TrackWriter) {
        self.writer = writer
    }

    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers keeps other audio playing; the built-in mic picks up the whole room.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        try session.setActive(true)
        #elseif os(watchOS)
        // The `audio` background mode plus an active record session keeps recording when the wrist drops.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif
        try installTap()
        engine.prepare()
        try engine.start()
        running = true
        observe()
    }

    public func stop() {
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw HushpadError.audioUnavailable("No microphone available")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [writer] buffer, time in
            writer.append(buffer, hostTime: time.isHostTimeValid ? time.hostTime : mach_absolute_time())
        }
    }

    private func restart() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            // Try again shortly; a new device can take a moment to become available.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart() }
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
        #if os(iOS) || os(watchOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.restart()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.restart()
        })
        #endif
    }
}
