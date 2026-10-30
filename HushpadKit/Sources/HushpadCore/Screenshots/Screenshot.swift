import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// Only when you press the screenshot button (⌘⇧S on Mac, camera on iPhone).
    case manual
    /// Also while someone else shares their screen, whenever it settles on new content (new slide, new document).
    case automatic

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .off: "Off"
        case .manual: "Manual only"
        case .automatic: "Automatic (when someone shares)"
        }
    }
}

/// An image taken during a recording: a shared screen on the Mac, or a photo of a whiteboard/projector on iPhone.
/// Stored as `<recording>/screens/<milliseconds since start>.jpg`, so the timestamp is the file name.
public struct Screenshot: Identifiable, Hashable, Sendable {
    /// The image to show or share (a plain copy when the library is encrypted).
    public var url: URL
    /// Seconds from the start of the recording.
    public var time: Double
    /// The file in the library (the same as `url` unless the library is encrypted).
    public var fileURL: URL
    public var id: URL { fileURL }

    public init(url: URL, time: Double, fileURL: URL? = nil) {
        self.url = url
        self.time = time
        self.fileURL = fileURL ?? url
    }
}

public enum ScreenshotStore {
    public static func folder(in recordingFolder: URL) -> URL {
        recordingFolder.appendingPathComponent("screens", isDirectory: true)
    }

    public static func list(in recordingFolder: URL) -> [Screenshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(in: recordingFolder), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "jpg", let millis = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
            return Screenshot(url: LibraryCrypto.readable(url), time: Double(millis) / 1000, fileURL: url)
        }.sorted { $0.time < $1.time }
    }

    @discardableResult
    public static func save(_ image: CGImage, at time: Double, in recordingFolder: URL) throws -> Screenshot {
        let url = try url(for: time, in: recordingFolder)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HushpadError.audioUnavailable("Could not create screenshot file")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HushpadError.audioUnavailable("Could not write screenshot") }
        try protect(url)
        return Screenshot(url: url, time: time)
    }

    /// For photos that are already JPEG (iPhone camera).
    @discardableResult
    public static func save(jpeg: Data, at time: Double, in recordingFolder: URL) throws -> Screenshot {
        let url = try url(for: time, in: recordingFolder)
        try jpeg.write(to: url, options: .atomic)
        try protect(url)
        return Screenshot(url: url, time: time)
    }

    /// Adds image files (PNG, JPEG, HEIC…, e.g. screenshots saved from another app) to a meeting, all timed at `time`;
    /// later ones land a millisecond apart so they keep their order. Files that aren't images are skipped.
    @discardableResult
    public static func add(imageFiles urls: [URL], at time: Double, in recordingFolder: URL) -> [Screenshot] {
        urls.compactMap { url in
            // The thumbnail call with no size limit gives the full image, turned upright per its EXIF orientation.
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return try? save(image, at: time, in: recordingFolder)
        }
    }

    /// A deleted screenshot kept in memory so the delete can be undone.
    public struct Removed: Sendable {
        public let jpeg: Data
        public let time: Double
        public let recordingFolder: URL
    }

    /// Deletes screenshots, keeping their images in memory for `restore`. Returns what was removed and how many
    /// couldn't be (those stay on disk).
    public static func remove(_ screenshots: [Screenshot]) -> (removed: [Removed], failed: Int) {
        var removed: [Removed] = [], failed = 0
        for shot in screenshots {
            do {
                let jpeg = try Data(contentsOf: shot.url)
                try delete(shot)
                // `<recording>/screens/<ms>.jpg`
                removed.append(Removed(jpeg: jpeg, time: shot.time,
                                       recordingFolder: shot.fileURL.deletingLastPathComponent().deletingLastPathComponent()))
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }

    /// Puts removed screenshots back where they were, at the same times.
    public static func restore(_ removed: [Removed]) throws {
        for shot in removed { try save(jpeg: shot.jpeg, at: shot.time, in: shot.recordingFolder) }
    }

    public static func delete(_ screenshot: Screenshot) throws {
        try FileManager.default.removeItem(at: screenshot.fileURL)
        if screenshot.url != screenshot.fileURL { try? FileManager.default.removeItem(at: screenshot.url) }
    }

    private static func url(for time: Double, in recordingFolder: URL) throws -> URL {
        let directory = try AppDirectories.ensure(folder(in: recordingFolder))
        var millis = Int((max(0, time) * 1000).rounded())
        // Two captures in the same millisecond: nudge forward rather than overwrite.
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(millis).jpg").path) { millis += 1 }
        return directory.appendingPathComponent("\(millis).jpg")
    }

    private static func protect(_ url: URL) throws {
        #if !os(macOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
