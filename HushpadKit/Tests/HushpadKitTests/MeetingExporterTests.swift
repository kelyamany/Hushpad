import Foundation
import Testing
@testable import HushpadCore
@testable import HushpadKit

@Suite struct MeetingExporterTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exporter-\(UUID().uuidString)")
    }

    private func exists(_ url: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// 16 kHz mono 16-bit PCM WAV with ~0.5 s of a 440 Hz sine.
    private func writeWAV(to url: URL) throws {
        let rate = 16_000
        let samples = (0..<(rate / 2)).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        for s in samples { u16(UInt16(bitPattern: s)) }
        try data.write(to: url)
    }

    private func transcript(timed: Bool = true) -> Transcript {
        Transcript(language: .english, speakers: [Speaker(key: "A", name: "Alice")],
                   utterances: [Utterance(speaker: "A", start: 0, end: 2, text: "Hello there")],
                   engine: "test:engine", isTimed: timed)
    }

    @Test func fullExportWritesEverything() async throws {
        let root = tempRoot(), out = tempRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = try RecordingStore(root: root)
        let rec = Recording(title: "Weekly sync", duration: 0.5, hasMic: true, activeEngine: "test:engine")
        try store.save(rec)
        try store.save(transcript(), for: rec.id)
        try store.saveNotes("# Enhanced", for: rec.id, .enhanced)
        try store.saveNotes("my notes", for: rec.id, .mine)
        let folder = store.folder(for: rec.id)
        try writeWAV(to: store.micURL(for: rec.id))
        try FileManager.default.createDirectory(at: ScreenshotStore.folder(in: folder), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: ScreenshotStore.folder(in: folder).appendingPathComponent("1500.jpg"))

        let dest = try await MeetingExporter(store: store, audio: .compressed).export(rec, into: out)

        #expect(dest.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
        for file in ["Transcript.md", "Transcript.srt", "Notes.md", "My Notes.md", "screens/1500.jpg",
                     "data/recording.json", "data/transcripts/test_engine.json"] {
            #expect(exists(dest, file), "missing \(file)")
        }
        #expect(exists(dest, "Room audio.m4a") || exists(dest, "Room audio.wav"))
        #expect(!exists(dest, "Call audio.m4a") && !exists(dest, "Call audio.wav"))
    }

    @Test func noAudioAndUntimedTranscript() async throws {
        let root = tempRoot(), out = tempRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = try RecordingStore(root: root)
        let rec = Recording(title: "Imported", hasMic: false, activeEngine: "test:engine")
        try store.save(rec)
        try store.save(transcript(timed: false), for: rec.id)

        let dest = try await MeetingExporter(store: store, audio: .compressed).export(rec, into: out)

        #expect(exists(dest, "Transcript.md"))
        #expect(!exists(dest, "Transcript.srt"))
        #expect(!exists(dest, "Notes.md") && !exists(dest, "My Notes.md"))
        #expect(names(dest).allSatisfy { !$0.hasPrefix("Room audio") && !$0.hasPrefix("Call audio") })
    }

    @Test func libraryExportGroupsByFolder() async throws {
        let root = tempRoot(), out = tempRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = try RecordingStore(root: root)
        let clients = Folder(name: "Clients")
        let a = Recording(title: "Client call", hasMic: false, folderID: clients.id)
        let b = Recording(title: "Solo thoughts", createdAt: Date(timeIntervalSince1970: 1_700_000_000), hasMic: false)
        try store.save(a); try store.save(b)
        try store.saveFolders([clients])

        let result = try await MeetingExporter(store: store, audio: .none)
            .exportLibrary([a, b], folders: [clients], into: out)

        let date = Date().formatted(.iso8601.year().month().day())
        #expect(result.lastPathComponent == "Hushpad Export \(date)")
        #expect(exists(result, "Clients/\(RecordingStore.folderName(for: a))"))
        #expect(exists(result, RecordingStore.folderName(for: b)))
        #expect(exists(result, "folders.json"))
    }

    @Test func exportingTwiceDoesNotOverwrite() async throws {
        let root = tempRoot(), out = tempRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = try RecordingStore(root: root)
        let rec = Recording(title: "Twice", hasMic: false)
        try store.save(rec)
        let exporter = MeetingExporter(store: store, audio: .none)
        let first = try await exporter.export(rec, into: out)
        let second = try await exporter.export(rec, into: out)
        #expect(first.lastPathComponent == RecordingStore.folderName(for: rec))
        #expect(second.lastPathComponent == first.lastPathComponent + " 2")
        #expect(exists(first, "data/recording.json") && exists(second, "data/recording.json"))
    }

    #if os(macOS)
    @Test func zipProducesNonEmptyFile() throws {
        let dir = tempRoot().appendingPathComponent("Zip me")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let zip = try MeetingExporter.zip(dir)
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(zip.pathExtension == "zip")
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        #expect(size > 0)
    }
    #endif
}
