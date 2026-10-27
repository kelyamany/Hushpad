import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case text = "txt"
    case markdown = "md"
    case subtitles = "srt"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .text: "Plain text"
        case .markdown: "Markdown"
        case .subtitles: "Subtitles (SRT)"
        }
    }
}

public enum Exporter {
    /// `screenshots` are only used by Markdown, which links them (relative to the recording folder) at their point in time.
    public static func render(_ transcript: Transcript, title: String, as format: ExportFormat, screenshots: [Screenshot] = []) -> String {
        switch format {
        case .text:
            return transcript.utterances.map {
                (transcript.isTimed ? "[\(clock($0.start))] " : "") + "\(transcript.speakerName(for: $0.speaker)): \($0.text)"
            }.joined(separator: "\n") + "\n"
        case .markdown:
            var lines = ["# \(title)", ""]
            var pending = screenshots.sorted { $0.time < $1.time }[...]
            func insertScreenshots(before time: Double) {
                while let shot = pending.first, shot.time < time {
                    lines.append("![Screen at \(clock(shot.time))](screens/\(shot.url.lastPathComponent))")
                    lines.append("")
                    pending = pending.dropFirst()
                }
            }
            for utterance in transcript.utterances {
                insertScreenshots(before: utterance.start)
                lines.append("**\(transcript.speakerName(for: utterance.speaker))**" + (transcript.isTimed ? " _\(clock(utterance.start))_" : "") + "  ")
                lines.append(utterance.text)
                lines.append("")
            }
            insertScreenshots(before: .infinity)
            return lines.joined(separator: "\n")
        case .subtitles:
            return transcript.utterances.enumerated().map { index, utterance in
                "\(index + 1)\n\(srtTime(utterance.start)) --> \(srtTime(utterance.end))\n"
                    + "\(transcript.speakerName(for: utterance.speaker)): \(utterance.text)\n"
            }.joined(separator: "\n")
        }
    }

    /// "1:02:03" or "02:03".
    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func srtTime(_ seconds: Double) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, (millis / 60_000) % 60, (millis / 1000) % 60, millis % 1000)
    }
}
