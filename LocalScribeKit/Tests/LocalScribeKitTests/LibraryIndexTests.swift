import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeSilence(_ url: URL, seconds: Double) throws {
    let file = try WAVFile(url: url, sampleRate: 16_000)
    try file.append([Int16](repeating: 0, count: Int(seconds * 16_000)))
    try file.close()
}

// Nested in `CryptoGlobalState`: the encryption tests change LibraryCrypto's process-wide key,
// which would make plain-library reads in a parallel suite look locked.
extension CryptoGlobalState {
@Suite struct LibraryIndexTests {
    @Test func recordingByID() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let saved = Recording(title: "Budget sync")
        try store.save(saved)

        #expect(store.recording(id: saved.id)?.title == "Budget sync")
        #expect(store.recording(id: UUID()) == nil)
    }

    @Test func scanSortsNewestFirstAndIsUnlocked() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let older = Recording(title: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Recording(title: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
        // Saved out of order so the sort is what puts them right.
        try store.save(older)
        try store.save(newer)

        let scan = store.scan()
        #expect(scan.recordings.map(\.id) == [newer.id, older.id])
        #expect(scan.locked == false)
    }

    @Test func summariesDescribeTranscriptAndNotes() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Planning", hasMic: true, activeEngine: "engine:a")
        try store.save(recording)
        try store.save(Transcript(language: .english,
                                  speakers: [Speaker(key: "R1", name: "Me"), Speaker(key: "S1", name: "Sara")],
                                  utterances: [Utterance(speaker: "R1", start: 0, end: 2, text: "Quarterly Budget review")],
                                  engine: "engine:a"), for: recording.id)
        try store.saveNotes("Remember the Lisbon offsite", for: recording.id, .mine)

        let snapshot = LibraryIndex.read(store)
        let summary = try #require(snapshot.summaries[recording.id])
        #expect(summary.speakerCount == 2)
        #expect(summary.hasTranscript)
        #expect(summary.searchText.contains("budget"))
        #expect(summary.searchText.contains("lisbon"))
        #expect(summary.searchText == summary.searchText.lowercased())
    }

    @Test func unchangedRecordingsReuseCachedSummary() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Cache", activeEngine: "engine:a")
        try store.save(recording)
        try store.save(Transcript(language: .english, speakers: [Speaker(key: "R1", name: "Me")],
                                  utterances: [Utterance(speaker: "R1", start: 0, end: 1, text: "First words")],
                                  engine: "engine:a"), for: recording.id)

        var first = LibraryIndex.read(store)
        // Plant a marker in the cached summary: a second read with an unchanged stamp must hand it back.
        first.summaries[recording.id] = RecordingSummary(speakerCount: 99, hasTranscript: true, searchText: "marker")
        let reused = LibraryIndex.read(store, previous: first)
        #expect(reused.summaries[recording.id]?.speakerCount == 99)

        // Rewrite the transcript after the folder's modification date can move, then read again.
        Thread.sleep(forTimeInterval: 1.1)
        try store.save(Transcript(language: .english,
                                  speakers: [Speaker(key: "R1", name: "Me"), Speaker(key: "S1", name: "Sara"),
                                             Speaker(key: "S2", name: "Omar")],
                                  utterances: [Utterance(speaker: "R1", start: 0, end: 1, text: "Changed wording")],
                                  engine: "engine:a"), for: recording.id)
        let updated = LibraryIndex.read(store, previous: reused)
        #expect(updated.stamps[recording.id] != reused.stamps[recording.id])
        #expect(updated.summaries[recording.id]?.speakerCount == 3)
        #expect(updated.summaries[recording.id]?.searchText.contains("changed") == true)
    }

    @Test func trackWriterFinishReportsNoFailure() throws {
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mic.wav")
        let writer = try TrackWriter(url: url, startHostTime: 0)

        let summary = writer.finish()
        #expect(summary.failure == nil)
        #expect(writer.writeFailure == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
}

// MARK: Encrypted library (touches LibraryCrypto global state; always reset)

extension CryptoGlobalState.LibraryIndexTests {
    private func resetCrypto() {
        LibraryCrypto.key = nil
        LibraryCrypto.encryptNewFiles = false
        LibraryCrypto.clearCache()
    }

    @Test func lockedLibraryReportsLockedUntilKeyReturns() throws {
        let root = try tempRoot()
        let key = LibraryCrypto.newKey()
        defer { resetCrypto(); try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)

        LibraryCrypto.key = key
        LibraryCrypto.encryptNewFiles = true
        let recording = Recording(title: "Sealed meeting")
        try store.save(recording)
        let json = store.folder(for: recording.id).appendingPathComponent("recording.json")
        #expect(LibraryCrypto.isSealed(file: json))

        // Same files on disk, but this device no longer has the key.
        LibraryCrypto.key = nil
        let locked = store.scan()
        #expect(locked.locked == true)
        #expect(locked.recordings.isEmpty)

        LibraryCrypto.key = key
        let unlocked = store.scan()
        #expect(unlocked.locked == false)
        #expect(unlocked.recordings.map(\.id) == [recording.id])
    }

    @Test func mergeInEncryptedLibraryKeepsAudioDuration() throws {
        let root = try tempRoot()
        defer { resetCrypto(); try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)

        let one = Recording(title: "Standup", duration: 1, hasMic: true)
        let two = Recording(title: "Retro", createdAt: Date().addingTimeInterval(600), duration: 1, hasMic: true)
        try store.save(one)
        try store.save(two)
        try writeSilence(store.micURL(for: one.id), seconds: 1)
        try writeSilence(store.micURL(for: two.id), seconds: 1)

        // Seal both meetings' files, as the app does once encryption is on.
        LibraryCrypto.key = LibraryCrypto.newKey()
        LibraryCrypto.encryptNewFiles = true
        let converter = LibraryConverter(store: store)
        try converter.seal(one.id)
        try converter.seal(two.id)
        #expect(LibraryCrypto.isSealed(file: store.micURL(for: one.id)))

        let merged = try RecordingMerger.merge(.init(first: one, second: two), in: store)
        #expect(abs(merged.duration - 2) < 0.01)
        let mic = try #require(store.tracks(for: merged).mic)
        #expect(abs(AudioInfo.duration(of: mic) - 2) < 0.01)
    }
}
