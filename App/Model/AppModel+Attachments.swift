import Foundation
import LocalScribeKit
import LocalScribeUI

/// A meeting's screenshots and added images.
extension AppModel {
    func delete(_ screenshot: Screenshot, in recording: Recording) { delete([screenshot], in: recording) }

    /// Deletes right away and offers Undo in the banner (the images are kept in memory until the next delete).
    func delete(_ screenshots: [Screenshot], in recording: Recording) {
        let (removed, failed) = ScreenshotStore.remove(screenshots)
        touch(recording.id)
        if failed > 0 { errorMessage = "Couldn't delete \(failed) screenshot\(failed == 1 ? "" : "s")." }
        guard !removed.isEmpty else { return }
        removedScreenshots = (recording.id, removed)
        post("Deleted \(removed.count) screenshot\(removed.count == 1 ? "" : "s").", action: .undoScreenshotDelete)
    }

    func undoScreenshotDelete() {
        guard let (id, shots) = removedScreenshots else { return }
        removedScreenshots = nil
        do {
            try ScreenshotStore.restore(shots)
        } catch {
            errorMessage = "Couldn't put the screenshots back: \(error.localizedDescription)"
        }
        touch(id)
        sealNewFiles(id)
    }

    /// Copies screenshots (decrypted) into a new "<title> screenshots" folder inside `directory`, numbered in order.
    func saveScreenshots(_ screenshots: [Screenshot], of recording: Recording, to directory: URL) throws -> URL {
        let name = RecordingStore.sanitize(recording.title)
        var folder = directory.appendingPathComponent("\(name) screenshots", isDirectory: true)
        var copy = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = directory.appendingPathComponent("\(name) screenshots \(copy)", isDirectory: true)
            copy += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(screenshots.count).count
        for (index, shot) in screenshots.enumerated() {
            let number = String(repeating: "0", count: max(0, digits - String(index + 1).count)) + String(index + 1)
            try FileManager.default.copyItem(at: shot.url, to: folder.appendingPathComponent("\(name) \(number).jpg"))
        }
        return folder
    }

    /// Adds image files to a meeting as screenshots (e.g. ones saved from another app), after the audio so they sort last.
    func addImages(_ urls: [URL], to recording: Recording) async {
        let folder = store.folder(for: recording.id), time = recording.hasAudio ? recording.duration : 0
        let added = await Task.detached(priority: .userInitiated) {
            // Files from the open panel are security-scoped; dropped ones aren't, and this is a no-op for them.
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            return ScreenshotStore.add(imageFiles: urls, at: time, in: folder).count
        }.value
        guard added > 0 else {
            errorMessage = "Couldn't read \(urls.count == 1 ? "that file" : "those files") as an image."
            return
        }
        touch(recording.id)
        sealNewFiles(recording.id)
        post("Added \(added) screenshot\(added == 1 ? "" : "s")")
    }
}
