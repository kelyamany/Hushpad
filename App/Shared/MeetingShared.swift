import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// Generated notes or your own: the two views of a meeting's notes (Mac and iPhone).
enum NotesMode: String, CaseIterable, Identifiable {
    case enhanced = "Enhanced", mine = "My Notes"
    var id: String { rawValue }
}

// MARK: - Dialogs

extension View {
    /// "Delete “Title”?" (or "Delete N meetings?") for whatever is in `pending`; `deleted` runs afterwards.
    func deleteMeetingsDialog(_ pending: Binding<[Recording]>, deleted: @escaping () -> Void = {}) -> some View {
        modifier(DeleteMeetingsDialog(pending: pending, deleted: deleted))
    }

    func deleteFolderDialog(_ pending: Binding<Folder?>) -> some View {
        modifier(DeleteFolderDialog(pending: pending))
    }

    /// Shows `AppModel.errorMessage` as an alert.
    func errorAlert() -> some View { modifier(ErrorAlert()) }
}

private struct DeleteMeetingsDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: [Recording]
    let deleted: () -> Void

    private var title: String {
        pending.count == 1 ? "Delete “\(pending[0].title)”?" : "Delete \(pending.count) meetings?"
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }),
                                   titleVisibility: .visible) {
            Button(pending.count == 1 ? "Delete Meeting" : "Delete \(pending.count) Meetings", role: .destructive) {
                pending.forEach { model.delete($0) }
                pending = []
                deleted()
            }
        } message: {
            Text(model.deleteMessage)
        }
    }
}

private struct DeleteFolderDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: Folder?

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete the folder “\(pending?.name ?? "")”?",
                                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                   titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let pending { model.deleteFolder(pending) }
                pending = nil
            }
        } message: {
            Text("The meetings in it are kept and move back to All Meetings.")
        }
    }
}

private struct ErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert("Hushpad", isPresented: Binding(get: { model.errorMessage != nil },
                                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Export progress

/// "Exporting… 40%", shown wherever you started an export from (list or meeting) until it's done.
struct ExportProgressPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = model.exportProgress {
            Label("Exporting… \(Int(progress * 100))%", systemImage: "shippingbox")
                .font(.small)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .glassEffect(.regular, in: Capsule())
                .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - The meeting's "…" menu

/// Everything you can do with an open meeting, in the same order on Mac and iPhone.
struct MeetingActions: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let transcript: Transcript?
    let screenshots: [Screenshot]
    let isLive: Bool
    let transcribeAgain: () -> Void
    let delete: () -> Void
    #if os(iOS)
    let editLanguages: () -> Void
    #endif

    var body: some View {
        if recording.hasAudio {
            Button("Transcribe Again…", systemImage: "waveform.badge.magnifyingglass", action: transcribeAgain)
                .disabled(isLive || model.jobs[recording.id]?.isActive == true)
        }
        #if os(iOS)
        Button("Languages…", systemImage: "globe", action: editLanguages)
            .disabled(isLive)
        #endif
        Divider()
        MoveToFolderMenu(recordings: [recording])
        Button("Merge With…", systemImage: "arrow.triangle.merge") { model.mergeRequest = recording }
            .disabled(!model.canMerge(recording))
        if let transcript {
            Menu("Export Transcript", systemImage: "square.and.arrow.up") {
                ForEach(ExportFormat.allCases) { format in
                    ShareLink(format.displayName, item: TranscriptExport(transcript: transcript, title: recording.title,
                                                                         format: format, screenshots: screenshots),
                              preview: SharePreview(recording.title))
                }
            }
        }
        Button("Export Meeting…", systemImage: "shippingbox") { model.export([recording]) }
            .disabled(isLive || model.exportProgress != nil)
        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.open(model.store.folder(for: recording.id)) }
            .disabled(isLive)
        #endif
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
            .disabled(isLive)
    }
}

// MARK: - Transcript

/// A meeting's transcript with its version bar and speaker chips, or the right empty state.
struct MeetingTranscript: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let detail: MeetingDetailModel
    let isLive: Bool
    let transcribeAgain: () -> Void
    let editSpeaker: (Speaker, Transcript) -> Void
    let open: (Screenshot) -> Void

    var body: some View {
        if let display = detail.display, let transcript = detail.transcript {
            VStack(alignment: .leading, spacing: Space.l) {
                if transcript.isLive, !isLive, model.jobs[recording.id] == nil, model.pausedTranscription(recording) == nil {
                    LiveTranscriptNotice { model.transcribe(recording) }
                }
                VersionBar(detail: detail, recording: recording, transcript: transcript, isLive: isLive, transcribeAgain: transcribeAgain)
                if !transcript.speakers.isEmpty {
                    SpeakerChips(transcript: transcript, recording: recording) { editSpeaker($0, transcript) }
                }
                TranscriptContent(display: display, player: detail.player,
                                  onRename: { editSpeaker($0, transcript) },
                                  onSeek: { detail.player.play(from: $0) },
                                  onOpen: open,
                                  onDelete: { model.delete($0, in: recording) })
                    .padding(.horizontal, -(Space.s + 2))
            }
        } else if isLive {
            EmptyState(.transcript, title: "Recording…", message: "The transcript appears when you stop.")
                .frame(maxWidth: .infinity)
        } else if model.jobs[recording.id] == nil {
            if recording.hasAudio {
                EmptyState(.transcript, title: "Not transcribed yet", message: notTranscribedMessage) {
                    Button("Transcribe") { model.transcribe(recording) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            } else {
                EmptyState(.transcript, title: "No transcript", message: "This meeting was imported without one.")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var notTranscribedMessage: String {
        let whisper = model.settings.model
        #if os(macOS)
        return "Runs on this Mac with \(whisper.displayName)."
        #else
        return model.isDownloaded(whisper) ? "Runs on this iPhone." : "The speech model is downloaded first (once). Then it runs offline."
        #endif
    }
}

/// Speaker chips that wrap onto new lines. Click one to rename it, or merge it with another speaker.
struct SpeakerChips: View {
    let transcript: Transcript
    let recording: Recording
    let onEdit: (Speaker) -> Void

    var body: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(Array(transcript.speakers.enumerated()), id: \.element.key) { index, speaker in
                Button { onEdit(speaker) } label: { SpeakerChip(name: speaker.name, colorIndex: index) }
                    .buttonStyle(.plain)
                    .help("Rename \(speaker.name), or merge with another speaker")
                    .accessibilityLabel(speaker.name)
                    .accessibilityHint("Rename, or merge with another speaker")
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") { onEdit(speaker) }
                        MergeSpeakerMenu(speaker: speaker, transcript: transcript, recording: recording)
                    }
            }
        }
    }
}
