import AVFoundation
import HushpadKit
import Observation

/// Plays a recording with the room and call tracks mixed, so you can check what was really said.
/// Tapping a line in the transcript seeks here; the transcript highlights the line being played.
@Observable
final class PlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// A track that exists couldn't be opened, so part of the meeting won't be heard.
    private(set) var loadFailed = false
    var rate: Float = 1 {
        didSet { players.forEach { $0.rate = rate } }
    }

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    /// The meeting to play. The audio files are only opened on the first Play, so showing a meeting stays instant
    /// (and an encrypted meeting isn't decrypted until you actually listen).
    @ObservationIgnored private var pending: (recording: Recording, store: RecordingStore)?
    @ObservationIgnored private var preparedID: UUID?
    @ObservationIgnored private var ticker: Timer? { didSet { oldValue?.invalidate() } }



    /// Points the player at a meeting without reading any audio.
    func prepare(_ recording: Recording, store: RecordingStore) {
        guard preparedID != recording.id else { return }
        stop()
        pending = (recording, store)
        preparedID = recording.id
        duration = recording.duration
        currentTime = 0
    }

    private func loadPlayers() {
        guard players.isEmpty, let (recording, store) = pending else { return }
        let tracks = store.tracks(for: recording)
        let files = [tracks.mic, tracks.system].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        players = files.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        loadFailed = players.count < files.count
        players.forEach { $0.enableRate = true; $0.prepareToPlay() }
        duration = players.map(\.duration).max() ?? duration
    }

    func toggle() {
        isPlaying ? pause() : play(from: currentTime)
    }

    func play(from time: Double) {
        loadPlayers()
        guard let first = players.first else { return }
        #if os(iOS)
        if !isPlaying {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        let start = max(0, min(time, duration))
        // Start every track on the same device tick so they stay in sync.
        let startAt = first.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(start, player.duration)
            player.rate = rate
            player.play(atTime: startAt)
        }
        currentTime = start
        isPlaying = true
        startTicker()
    }

    func pause() {
        players.forEach { $0.pause() }
        isPlaying = false
        ticker = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func seek(to time: Double) {
        guard isPlaying else {
            currentTime = max(0, min(time, duration))
            return
        }
        // Already playing: move the tracks without restarting the audio session.
        let start = max(0, min(time, duration))
        let startAt = (players.first?.deviceCurrentTime ?? 0) + 0.05
        for player in players {
            player.currentTime = min(start, player.duration)
            player.play(atTime: startAt)
        }
        currentTime = start
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    func stop() {
        players.forEach { $0.stop() }
        players = []
        pending = nil
        preparedID = nil
        isPlaying = false
        loadFailed = false
        ticker = nil
    }

    private func startTicker() {
        // The views stop the player when they disappear, which also ends this timer.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.players.map(\.currentTime).max() ?? 0
                if !self.players.contains(where: \.isPlaying) {
                    self.isPlaying = false
                    self.ticker = nil
                    if self.currentTime >= self.duration - 0.2 { self.currentTime = 0 }
                }
            }
        }
    }
}
