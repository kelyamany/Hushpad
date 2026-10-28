import HushpadKit
import HushpadUI
import SwiftUI
import UniformTypeIdentifiers

/// A meeting in a list: title, a quiet meta line, and at most one status (only when something needs attention).
struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    let recording: Recording

    var body: some View {
        let summary = model.summaries[recording.id]
        HStack(spacing: Space.m) {
            // The note tile: a small rounded square with a page glyph.
            Image(systemName: model.session?.recording.id == recording.id ? "waveform" : "doc.text")
                .font(.small)
                .foregroundStyle(model.session?.recording.id == recording.id ? Theme.record : Theme.inkSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.paperSunken, in: Radius.shape(Radius.m))
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.rowTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                MetaLine([recording.durationText, people(summary)])
            }
            Spacer(minLength: Space.xs)
            if let status = model.status(for: recording) { StatusPill(status) }
            Text(recording.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.meta)
                .foregroundStyle(Theme.inkTertiary)
                .monospacedDigit()
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }

    private func people(_ summary: RecordingSummary?) -> String? {
        if !recording.attendees.isEmpty {
            let names = recording.attendees.prefix(2).joined(separator: ", ")
            return recording.attendees.count > 2 ? "\(names) +\(recording.attendees.count - 2)" : names
        }
        guard let count = summary?.speakerCount, count > 1 else { return nil }
        return "\(count) people"
    }
}

/// Transcription progress, or a plain-language failure with Retry.
struct JobCard: View {
    let job: JobState
    /// Try again after a failure, or resume a paused job.
    let retry: () -> Void
    var pause: (() -> Void)? = nil

    #if os(iOS)
    static let reassurance = "On this iPhone. It carries on if you lock the screen."
    #else
    static let reassurance = "On this Mac, in the background. Pause any time; it resumes where it stopped."
    #endif

    var body: some View {
        if case .failed(let message) = job {
            InlineBanner("Couldn't transcribe this recording", detail: message, retry: retry)
        } else {
            HStack(spacing: Space.m) {
                if job.isPaused {
                    Image(systemName: "pause.circle").font(.displaySmall).foregroundStyle(Theme.inkSecondary).frame(width: 26, height: 26)
                } else if let fraction = job.fraction {
                    ProgressRing(fraction: fraction, lineWidth: 3).frame(width: 26, height: 26)
                } else {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(job.title).font(.small.weight(.medium)).foregroundStyle(Theme.ink)
                    Text(job.isPaused ? "The parts already done are kept." : Self.reassurance)
                        .font(.label).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
                if job.isPaused {
                    Button("Resume", systemImage: "play.fill", action: retry).buttonStyle(.borderedProminent)
                } else if let pause {
                    Button("Pause", systemImage: "pause.fill", action: pause)
                }
            }
            .controlSize(.small)
            .card(padding: Space.m, radius: Radius.m)
        }
    }
}

/// Shown over a transcript that only has the live captions: the full one is better, and is made when you ask.
struct LiveTranscriptNotice: View {
    let transcribe: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "captions.bubble").foregroundStyle(Theme.inkSecondary)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Live captions").font(.small.weight(.medium)).foregroundStyle(Theme.ink)
                Text("The full transcript is more accurate and names each speaker.")
                    .font(.label).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
            Button("Transcribe", action: transcribe).buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .card(padding: Space.m, radius: Radius.m)
    }
}

// MARK: - Export

/// A transcript export written only when the user actually shares or saves it (never while a menu is built).
struct TranscriptExport: Transferable {
    let transcript: Transcript
    let title: String
    let format: ExportFormat
    let screenshots: [Screenshot]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .utf8PlainText) { export in
            let text = Exporter.render(export.transcript, title: export.title, as: export.format, screenshots: export.screenshots)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(RecordingStore.sanitize(export.title)).\(export.format.rawValue)")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
