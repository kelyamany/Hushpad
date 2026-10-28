import Foundation

/// The audio files captured for one recording.
/// `mic` is the room (in-person speakers, including you). `system` is call audio from Zoom/Meet/Teams (macOS only).
public struct AudioTracks: Sendable {
    public var mic: URL?
    public var system: URL?
    /// Seconds the system track started after the mic track; used to put both on one timeline.
    public var systemOffset: Double

    public init(mic: URL?, system: URL?, systemOffset: Double = 0) {
        self.mic = mic
        self.system = system
        self.systemOffset = systemOffset
    }
}
