import ImageIO
import HushpadKit
import HushpadUI
import SwiftUI

/// A transcript prepared for display once (sorted, speakers indexed), so scrolling and playback never redo it.
nonisolated struct TranscriptDisplay {
    nonisolated enum Item: Identifiable {
        case utterance(Utterance, Speaker, colorIndex: Int)
        case screenshot(Screenshot)

        /// Computed on every access, but only the list diffing reads it, once per row.
        var id: String {
            switch self {
            case .utterance(let u, _, _): "u-\(u.id)"
            case .screenshot(let s): "s-\(s.url.lastPathComponent)"
            }
        }
        var time: Double {
            switch self {
            case .utterance(let u, _, _): u.start
            case .screenshot(let s): s.time
            }
        }
    }

    let transcript: Transcript
    let items: [Item]
    let rightToLeft: Bool

    init(_ transcript: Transcript, screenshots: [Screenshot]) {
        self.transcript = transcript
        var index: [String: (Speaker, Int)] = [:]
        for (i, speaker) in transcript.speakers.enumerated() { index[speaker.key] = (speaker, i) }
        let utterances = transcript.utterances.map { utterance -> Item in
            let (speaker, color) = index[utterance.speaker] ?? (Speaker(key: utterance.speaker, name: utterance.speaker), 0)
            return .utterance(utterance, speaker, colorIndex: color)
        }
        items = (utterances + screenshots.map(Item.screenshot)).sorted { $0.time < $1.time }
        rightToLeft = transcript.language.isRightToLeft || (transcript.language == .auto && TranscriptLanguage.isRightToLeft(code: transcript.detectedLanguage))
    }
}

/// The transcript: speaker, time, words. Screenshots / photos appear inline at the moment they were taken.
/// Click the time (or avatar) to play from there; the text itself stays selectable.
struct TranscriptContent: View {
    let display: TranscriptDisplay
    var player: PlaybackController?
    var onRename: (Speaker) -> Void = { _ in }
    var onSeek: (Double) -> Void = { _ in }
    var onOpen: (Screenshot) -> Void = { _ in }
    var onDelete: (Screenshot) -> Void = { _ in }

    var body: some View {
        if display.transcript.utterances.isEmpty {
            EmptyState(.transcript, title: "No speech found",
                       message: "The recording seems to be silent. Check the microphone in Settings.")
                .frame(maxWidth: .infinity)
        }
        LazyVStack(alignment: .leading, spacing: Space.xs) {
            ForEach(display.items) { item in
                switch item {
                case .utterance(let utterance, let speaker, let colorIndex):
                    UtteranceCell(utterance: utterance, speaker: speaker, colorIndex: colorIndex,
                                  rightToLeft: display.rightToLeft, showsTime: display.transcript.isTimed, player: player,
                                  onRename: { onRename(speaker) }, onSeek: { onSeek(utterance.start) })
                case .screenshot(let shot):
                    ScreenshotCell(screenshot: shot, onOpen: { onOpen(shot) }, onDelete: { onDelete(shot) })
                }
            }
        }
    }
}

struct UtteranceCell: View {
    let utterance: Utterance
    let speaker: Speaker
    let colorIndex: Int
    let rightToLeft: Bool
    var showsTime = true
    var player: PlaybackController?
    let onRename: () -> Void
    let onSeek: () -> Void

    var body: some View {
        let color = Theme.speakerColor(colorIndex)
        HStack(alignment: .top, spacing: Space.m) {
            SpeakerAvatar(name: speaker.name, color: color)
                .onTapGesture(perform: onSeek)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Button(action: onRename) {
                        Text(speaker.name).font(.small.weight(.semibold)).foregroundStyle(color)
                    }
                    .buttonStyle(.plain)
                    .help("Rename \(speaker.name), or merge with another speaker")
                    if showsTime {
                        Button(action: onSeek) {
                            Text(Exporter.clock(utterance.start)).font(.label.monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Play from here")
                    }
                }
                Text(utterance.text)
                    .font(.base)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                    .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.s + 2)
        .background {
            if let player { PlayingHighlight(player: player, start: utterance.start, end: utterance.end, color: color) }
        }
        .contextMenu {
            Button("Play from Here", systemImage: "play", action: onSeek)
            Button("Rename or Merge \(speaker.name)…", systemImage: "pencil", action: onRename)
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(utterance.text) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play from here", onSeek)
        .accessibilityAction(named: "Rename speaker", onRename)
    }
}

/// Only this small view observes the playback clock, so playing never re-renders the transcript itself.
private struct PlayingHighlight: View {
    let player: PlaybackController
    let start: Double
    let end: Double
    let color: Color

    var body: some View {
        let active = player.isPlaying && player.currentTime >= start && player.currentTime < end + 0.3
        Radius.shape(Radius.m)
            .fill(color.opacity(active ? 0.1 : 0))
            .animation(.easeOut(duration: 0.2), value: active)
    }
}

struct SpeakerAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 32
    /// 1 at the default text size, larger with Dynamic Type, so the initials keep fitting.
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        let size = size * scale
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if let number = words.last.flatMap({ Int($0) }), words.count == 2 { return "\(words[0].prefix(1))\(number)" }
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct ScreenshotCell: View {
    let screenshot: Screenshot
    let onOpen: () -> Void
    let onDelete: () -> Void
    /// Lines up with the text next to the speaker avatar, which grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var avatar = 32.0

    var body: some View {
        Button(action: onOpen) {
            ScreenshotThumbnail(url: screenshot.url)
                .frame(maxHeight: 280)
                .overlay(alignment: .bottomLeading) {
                    Text(Exporter.clock(screenshot.time))
                        .font(.label.monospacedDigit().weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xxs + 1)
                        .background(Theme.paperRaised.opacity(0.9), in: Capsule())
                        .padding(Space.s)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screenshot at \(Exporter.clock(screenshot.time))")
        .accessibilityHint("Opens it full size")
        .padding(.vertical, Space.xs)
        .padding(.leading, avatar + Space.m + Space.s + 2)
        .contextMenu {
            ShareLink(item: screenshot.url)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// A screenshot scaled down to display size off the main thread and cached; full-size images are only
/// decoded in the viewer.
struct ScreenshotThumbnail: View {
    let url: URL
    var maxPixels: CGFloat = 1400
    @State private var image: CGImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable().scaledToFit()
                    .clipShape(Radius.shape(Radius.m))
                    .overlay(Radius.shape(Radius.m).strokeBorder(Theme.hairline))
            } else {
                Radius.shape(Radius.m).fill(Theme.paperSunken).frame(height: 140)
                    .overlay {
                        if missing {
                            Image(systemName: "photo").foregroundStyle(Theme.inkTertiary)
                        }
                    }
            }
        }
        .task(id: url) {
            if let cached = ThumbnailCache.cached(url, maxPixels) { image = cached; return }
            let url = url, maxPixels = maxPixels
            let load = Task.detached(priority: .utility) { ThumbnailCache.load(url, maxPixels) }
            // Scrolling past a row cancels its decode instead of queuing useless work.
            image = await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
            missing = image == nil && !Task.isCancelled
        }
    }
}

nonisolated enum ThumbnailCache {
    private final class Box: @unchecked Sendable { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 200
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    /// Frees memory after meetings are deleted (keys are file paths, so stale entries would only waste space).
    nonisolated static func removeAll() { cache.removeAllObjects() }

    nonisolated static func cached(_ url: URL, _ maxPixels: CGFloat) -> CGImage? {
        cache.object(forKey: "\(url.path)#\(Int(maxPixels))" as NSString)?.image
    }

    nonisolated static func load(_ url: URL, _ maxPixels: CGFloat) -> CGImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(Box(image), forKey: "\(url.path)#\(Int(maxPixels))" as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// One screenshot full size, with previous/next (← → on the Mac) through the meeting's others, share and delete.
struct ScreenshotViewer: View {
    @State private var screenshots: [Screenshot]
    @State private var index: Int
    var showsTime = true
    /// Nil hides Delete (e.g. while the meeting is still recording).
    var delete: ((Screenshot) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(screenshots: [Screenshot], start: Screenshot, showsTime: Bool = true, delete: ((Screenshot) -> Void)? = nil) {
        let all = screenshots.contains(start) ? screenshots : [start]
        _screenshots = State(initialValue: all)
        _index = State(initialValue: all.firstIndex(of: start) ?? 0)
        self.showsTime = showsTime
        self.delete = delete
    }

    private var screenshot: Screenshot { screenshots[min(index, screenshots.count - 1)] }
    private var title: String {
        let position = screenshots.count > 1 ? "\(index + 1) of \(screenshots.count)" : nil
        let time = showsTime ? "At \(Exporter.clock(screenshot.time))" : nil
        let parts = [time, position].compactMap(\.self)
        return parts.isEmpty ? "Screenshot" : parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            // Fitted to the window, not scrolled: a two-way ScrollView offers unlimited space, so the image showed at
            // full size and got cut off.
            Group {
                if let image = PlatformImage.load(screenshot.url) { image.resizable().scaledToFit() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Space.m)
            .id(screenshot.id)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if screenshots.count > 1 {
                    ToolbarItemGroup {
                        Button("Previous", systemImage: "chevron.left") { index -= 1 }
                            .disabled(index == 0)
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Next", systemImage: "chevron.right") { index += 1 }
                            .disabled(index >= screenshots.count - 1)
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                }
                ToolbarItem { ShareLink(item: screenshot.url) }
                if let delete {
                    ToolbarItem {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            let shot = screenshot
                            delete(shot)
                            screenshots.removeAll { $0 == shot }
                            if screenshots.isEmpty { dismiss() } else { index = min(index, screenshots.count - 1) }
                        }
                        .keyboardShortcut(.delete, modifiers: [])
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 550)
        #endif
    }
}

enum PlatformImage {
    static func load(_ url: URL) -> Image? {
        #if os(macOS)
        NSImage(contentsOf: url).map(Image.init(nsImage:))
        #else
        UIImage(contentsOfFile: url.path).map(Image.init(uiImage:))
        #endif
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A thin progress ring, used for transcription status.
struct ProgressRing: View {
    var fraction: Double?
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: max(0.03, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: fraction)
            }
        }
    }
}
