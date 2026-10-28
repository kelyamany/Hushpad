import Foundation
import Testing
@testable import HushpadCore

/// The one-time move from the app's old name (throwaway defaults domains and temp folders only).
@Suite struct LegacyInstallTests {
    @Test func settingsAreCopiedOnceWithoutOverwritingOrPermissionFlags() throws {
        let oldDomain = "test.hushpad.legacy.\(UUID().uuidString)", newDomain = "test.hushpad.new.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: newDomain))
        defer {
            defaults.removePersistentDomain(forName: oldDomain)
            defaults.removePersistentDomain(forName: newDomain)
        }
        defaults.setPersistentDomain(["onboarded": true, "notesModel": "old", "LocalScribe.libraryBookmark": Data([1, 2]),
                                      "LocalScribe.askedSystemAudio": true], forName: oldDomain)
        defaults.set("new", forKey: "notesModel")

        LegacyInstall.moveSettings(from: oldDomain, into: defaults, named: newDomain)
        #expect(defaults.bool(forKey: "onboarded"))
        #expect(defaults.string(forKey: "notesModel") == "new")
        #expect(defaults.data(forKey: "Hushpad.libraryBookmark") == Data([1, 2]))
        #expect(defaults.object(forKey: "Hushpad.askedSystemAudio") == nil)
        #expect(defaults.object(forKey: "LocalScribe.askedSystemAudio") == nil)

        defaults.removeObject(forKey: "onboarded")
        LegacyInstall.moveSettings(from: oldDomain, into: defaults, named: newDomain)
        #expect(defaults.object(forKey: "onboarded") == nil)
    }

    @Test func folderMovesOnlyWhenTheNewOneIsMissing() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("LocalScribe"), new = base.appendingPathComponent("Hushpad")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Recordings"), withIntermediateDirectories: true)

        try LegacyInstall.moveFolder(old, to: new)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("Recordings").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))

        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try LegacyInstall.moveFolder(old, to: new)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("Recordings").path))
    }
}
