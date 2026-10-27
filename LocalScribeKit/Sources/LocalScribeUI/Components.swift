import LocalScribeCore
import SwiftUI

/// Live-updating "12:34" / "1:02:03" since a start date. Uses the system timer style, so it keeps
/// ticking in Always-On, on the Lock Screen and in Live Activities without the app doing any work.
public struct ElapsedTime: View {
    public var since: Date
    public init(since: Date) { self.since = since }

    public var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

/// Small tinted capsule with a speaker's name.
public struct SpeakerChip: View {
    public var name: String
    public var colorIndex: Int

    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }

    public var body: some View {
        let color = Theme.speakerColor(colorIndex)
        HStack(spacing: Space.xs + 1) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
        }
        .font(.small.weight(.medium))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Space.s + 1)
        .padding(.vertical, Space.xs)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// The one status a row or header shows, only when something needs attention. Always text + symbol.
public struct StatusPill: View {
    public enum Kind: Equatable {
        case recording
        case queued
        case transcribing(Double?)
        case downloading(Double?)
        case paused(Double?)
        case writingNotes
        case failed(String)
        case cloud

        var label: String {
            switch self {
            case .recording: "Recording"
            case .queued: "Waiting"
            case .transcribing(let fraction?): "Transcribing \(Int((fraction * 100).rounded()))%"
            case .transcribing: "Transcribing"
            case .downloading(let fraction?): "Downloading \(Int((fraction * 100).rounded()))%"
            case .downloading: "Downloading"
            case .paused(let fraction?) where fraction > 0: "Paused at \(Int((fraction * 100).rounded()))%"
            case .paused: "Paused"
            case .writingNotes: "Writing notes"
            case .failed(let text): text
            case .cloud: "Uses cloud"
            }
        }

        var symbol: String {
            switch self {
            case .recording: "record.circle"
            case .queued: "clock"
            case .transcribing: "waveform"
            case .downloading: "arrow.down.circle"
            case .paused: "pause.circle"
            case .writingNotes: "sparkles"
            case .failed: "exclamationmark.triangle.fill"
            case .cloud: "cloud"
            }
        }

        var tint: Color {
            switch self {
            case .recording: Theme.record
            case .queued, .paused: Theme.inkSecondary
            case .transcribing, .downloading, .writingNotes: Theme.accent
            case .failed: Theme.danger
            case .cloud: Theme.cloud
            }
        }
    }

    public var kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .labelStyle(PillLabelStyle())
            .font(.label.weight(.medium))
            .foregroundStyle(kind.tint)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .background(kind.tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    private struct PillLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: Space.xs) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

/// "Tue 9 Oct · 10:30 · 42 min · Anna, Ben": quiet metadata joined with middots. Empty parts are skipped.
public struct MetaLine: View {
    public var parts: [String]
    public init(_ parts: [String?]) { self.parts = parts.compactMap { $0?.isEmpty == false ? $0 : nil } }

    public var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.meta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
    }
}

/// Where a recording came from, as a quiet glyph (with its name for VoiceOver).
public struct SourceBadge: View {
    public var source: RecordingSource
    public init(source: RecordingSource) { self.source = source }

    public var body: some View {
        Image(systemName: source.symbol)
            .imageScale(.small)
            .foregroundStyle(Theme.inkTertiary)
            .accessibilityLabel(source.displayName)
    }
}

/// Empty states: an illustration, one sentence, at most one action.
public struct EmptyState<Action: View>: View {
    public var art: Vignette.Kind
    public var title: String
    public var message: String?
    @ViewBuilder public var action: () -> Action

    public init(_ art: Vignette.Kind, title: String, message: String? = nil, @ViewBuilder action: @escaping () -> Action) {
        self.art = art
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Space.l) {
            Vignette(art)
            VStack(spacing: Space.xs) {
                Text(title).font(.heading).foregroundStyle(Theme.ink)
                if let message {
                    Text(message).font(.small).foregroundStyle(Theme.inkSecondary)
                }
            }
            .multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: 360)
        .padding(Space.xl)
    }
}

public extension EmptyState where Action == EmptyView {
    init(_ art: Vignette.Kind, title: String, message: String? = nil) {
        self.init(art, title: title, message: message) { EmptyView() }
    }
}

/// Something went wrong: one plain sentence, Retry, and the technical text only behind "Details".
public struct InlineBanner: View {
    public var title: String
    public var detail: String?
    public var retryTitle: String
    public var retry: (() -> Void)?
    @State private var showsDetail = false

    public init(_ title: String, detail: String? = nil, retryTitle: String = "Try Again", retry: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.retryTitle = retryTitle
        self.retry = retry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(title).font(.small.weight(.medium)).foregroundStyle(Theme.ink)
                Spacer(minLength: Space.s)
                if let retry {
                    Button(retryTitle, action: retry).font(.small.weight(.semibold))
                }
            }
            #if !os(watchOS)
            if let detail, !detail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showsDetail) {
                    Text(detail)
                        .font(.label)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.label)
                .tint(Theme.inkSecondary)
            }
            #endif
        }
        .padding(Space.m)
        .background(Theme.danger.opacity(0.07), in: Radius.shape(Radius.m))
        .overlay(Radius.shape(Radius.m).strokeBorder(Theme.danger.opacity(0.18)))
    }
}

/// The single place the privacy promise is spelled out.
#if !os(watchOS)
/// A small ⓘ that shows the longer explanation of a setting on demand, so Settings itself stays short.
public struct InfoButton: View {
    let text: String
    @State private var showing = false

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(Theme.inkTertiary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More information")
        .popover(isPresented: $showing) {
            Text(text)
                .font(.small)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(Space.m)
                .presentationCompactAdaptation(.popover)
        }
    }
}
#endif

public struct PrivacyFooter: View {
    public init() {}
    public var body: some View {
        Label("Recordings, transcripts and notes stay on your devices. Only features marked “Uses cloud” send data out.",
              systemImage: "lock")
            .font(.label)
            .foregroundStyle(Theme.inkSecondary)
    }
}

/// A coloured folder glyph with its name.
public struct FolderLabel: View {
    public var folder: Folder
    public init(_ folder: Folder) { self.folder = folder }
    public var body: some View {
        Label {
            Text(folder.name)
        } icon: {
            Image(systemName: folder.symbol).foregroundStyle(Theme.folderColor(folder.colorIndex))
        }
    }
}

public extension Recording {
    /// "12 min", "1 h 05 min", or "Under a minute".
    var durationText: String {
        let minutes = Int((duration / 60).rounded())
        if duration < 60 { return duration > 0 ? "Under a minute" : "" }
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
    }
}
