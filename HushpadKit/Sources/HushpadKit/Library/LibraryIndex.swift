import Foundation

/// What the meeting list knows about a recording without opening it.
public struct RecordingSummary: Equatable, Sendable {
    public var speakerCount: Int
    public var hasTranscript: Bool
    /// Has audio but only live captions (or nothing) so far: the full transcript hasn't been made.
    public var needsFullTranscript: Bool
    /// Lower-cased transcript and notes text for search, built once per change.
    public var searchText: String

    public init(speakerCount: Int = 0, hasTranscript: Bool = false, needsFullTranscript: Bool = false, searchText: String = "") {
        self.speakerCount = speakerCount
        self.hasTranscript = hasTranscript
        self.needsFullTranscript = needsFullTranscript
        self.searchText = searchText
    }
}

/// Everything the app shows about the library, read in one pass.
public struct LibrarySnapshot: Sendable {
    public var recordings: [Recording] = []
    public var folders: [Folder] = []
    /// Some meetings couldn't be opened because this device doesn't have the library key.
    public var locked = false
    public var summaries: [UUID: RecordingSummary] = [:]
    /// When each recording's files last changed; a recording is summarised again only when this moves.
    public var stamps: [UUID: Date] = [:]

    public init() {}
}

/// Reads the library without touching the main thread: the recordings, the folders and a summary of each recording.
/// Only recordings whose files changed since `previous` are summarised again (a few stats per meeting instead of
/// decoding every transcript), so refreshes stay cheap.
public enum LibraryIndex {
    static let searchTextLimit = 100_000

    public static func read(_ store: RecordingStore, previous: LibrarySnapshot = LibrarySnapshot()) -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        let scan = store.scan()
        snapshot.recordings = scan.recordings
        snapshot.locked = scan.locked
        snapshot.folders = store.folders()
        for recording in snapshot.recordings {
            let stamp = store.contentStamp(for: recording.id)
            snapshot.stamps[recording.id] = stamp
            if previous.stamps[recording.id] == stamp, let cached = previous.summaries[recording.id] {
                snapshot.summaries[recording.id] = cached
            } else {
                snapshot.summaries[recording.id] = summarize(recording, in: store)
            }
        }
        return snapshot
    }

    public static func summarize(_ recording: Recording, in store: RecordingStore) -> RecordingSummary {
        let transcripts = store.transcripts(for: recording.id)
        let transcript = transcripts.first { $0.engine == recording.activeEngine } ?? transcripts.last
        let spoken = transcript?.utterances.lazy.map(\.text).joined(separator: " ") ?? ""
        let notes = [store.notes(for: recording.id, .mine), store.notes(for: recording.id, .enhanced)]
            .compactMap { $0 }.joined(separator: " ")
        return RecordingSummary(speakerCount: transcript?.speakers.count ?? 0,
                                hasTranscript: transcript != nil,
                                needsFullTranscript: recording.hasAudio && !transcripts.contains { !$0.isLive && !$0.isImported },
                                searchText: String((spoken + " " + notes).prefix(searchTextLimit)).lowercased())
    }
}
