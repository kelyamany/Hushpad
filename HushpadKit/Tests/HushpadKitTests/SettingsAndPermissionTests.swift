import Foundation
import Testing
@testable import HushpadCore
@testable import HushpadKit

@Suite struct SharedSettingsTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var full: SharedSettings {
        SharedSettings(language: .german, autoTranscribe: true, cloudEnabled: false, cloudModel: "cloud-1",
                       notesProvider: .ollama, notesBaseURL: "http://localhost:11434", notesModel: "llama",
                       notesTemplateID: "mine",
                       templates: [NoteTemplate(id: "mine", name: "Mine", instructions: "## Summary\nShort.")],
                       notesIncludeTranscript: true)
    }

    @Test func roundTrip() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try full.save(to: root)
        #expect(SharedSettings.load(from: root) == full)
    }

    @Test func loadReturnsNilWithoutFile() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SharedSettings.load(from: root) == nil)
    }

    @Test func lenientDecode() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"language":5,"autoTranscribe":true,"notesModel":"m","futureKey":{"a":1}}"#
        try Data(json.utf8).write(to: SharedSettings.url(in: root))
        let loaded = try #require(SharedSettings.load(from: root))
        #expect(loaded.language == nil)
        #expect(loaded.autoTranscribe == true)
        #expect(loaded.notesModel == "m")
    }

    @Test func stampTracksFile() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SharedSettings.stamp(in: root) == nil)
        try full.save(to: root)
        #expect(SharedSettings.stamp(in: root) != nil)
    }

    @Test func deviceOnlyKeysNeverEncoded() throws {
        let data = try RecordingStore.encode(full)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["apiKey", "modelID", "captureSystemAudio", "screenshotMode", "customModels", "onboarded"] {
            #expect(!text.contains("\"\(key)\""), "\(key) must not sync")
        }
    }
}

#if os(macOS)
@Suite struct PermissionStatusMappingTests {
    @Test func systemAudio() {
        #expect(Permissions.systemAudioStatus(tcc: true, asked: false) == .granted)
        #expect(Permissions.systemAudioStatus(tcc: false, asked: true) == .denied)
        #expect(Permissions.systemAudioStatus(tcc: nil, asked: true) == .unknown)
        #expect(Permissions.systemAudioStatus(tcc: nil, asked: false) == .notDetermined)
    }

    @Test func screen() {
        for tcc in [true, false, nil] as [Bool?] {
            for asked in [true, false] {
                #expect(Permissions.screenStatus(preflight: true, tcc: tcc, asked: asked) == .granted)
            }
        }
        #expect(Permissions.screenStatus(preflight: false, tcc: true, asked: false) == .needsRestart)
        #expect(Permissions.screenStatus(preflight: false, tcc: false, asked: false) == .denied)
        #expect(Permissions.screenStatus(preflight: false, tcc: nil, asked: true) == .denied)
        #expect(Permissions.screenStatus(preflight: false, tcc: nil, asked: false) == .notDetermined)
    }
}
#endif
