#if os(iOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// One meeting as a document, like on the Mac: serif title, quiet meta line, then Notes · Transcript · Attachments.
/// Everything else lives in the "…" menu.
struct PhoneDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recordingID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes", transcript = "Transcript", photos = "Attachments"
        var id: String { rawValue }
    }

    @State private var tab: Tab?
    @State private var notesMode: NotesMode?
    @State private var detail = MeetingDetailModel()
    @State private var editingSpeaker: SpeakerEditorRequest?
    @State private var enlarged: Screenshot?
    @State private var pendingDelete: [Recording] = []
    @State private var confirmRegenerate = false
    @State private var transcribingAgain = false
    @State private var editingLanguages = false

    private var recording: Recording? { model.recordings.first { $0.id == recordingID } }
    private var transcript: Transcript? { detail.transcript }
    private var isLive: Bool { model.session?.recording.id == recordingID }
    private var tabs: [Tab] { detail.screenshots.isEmpty ? [.notes, .transcript] : Tab.allCases }
    private var notesJob: NotesJob? { model.notesJobs[recordingID] }
    /// Opens on the notes when there are generated notes (or some are being written), otherwise on the transcript.
    private var currentTab: Tab {
        tab.flatMap { tabs.contains($0) ? $0 : nil } ?? (detail.enhancedNotes != nil || notesJob != nil ? .notes : .transcript)
    }
    private var currentNotesMode: NotesMode { notesMode ?? (detail.enhancedNotes != nil || notesJob != nil ? .enhanced : .mine) }

    var body: some View {
        if let recording {
            content(recording)
        } else {
            EmptyState(.search, title: "Meeting not found", message: "It may have been deleted on another device.")
        }
    }

    private func content(_ recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l + Space.xs) {
                header(recording)
                if let job = model.jobs[recording.id] ?? model.pausedTranscription(recording).map(JobState.paused) {
                    JobCard(job: job, retry: { model.transcribe(recording) }, pause: { model.pauseTranscription(recording) })
                }
                Picker("Section", selection: Binding(get: { currentTab }, set: { tab = $0 })) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if detail.isLoaded {
                    switch currentTab {
                    case .notes: notesSection(recording)
                    case .transcript: transcriptSection(recording)
                    case .photos: photosSection(recording)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(.horizontal, Space.l + Space.xs)
            .padding(.bottom, Size.floatingBarInset + Space.s)
        }
        .scrollDismissesKeyboard(.interactively)
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if recording.hasAudio && !isLive && currentTab == .transcript {
                PlaybackBar(player: detail.player).padding(.horizontal, Space.m).padding(.bottom, Space.xs)
            } else {
                // Ask anything about this meeting, like on the Mac.
                VStack(spacing: Space.s) {
                    ExportProgressPill()
                    ChatThread(scope: .meeting(recording.id)) { answer in
                        let notes = detail.myNotes.isEmpty ? answer : detail.myNotes + "\n\n" + answer
                        model.saveMyNotes(notes, for: recording)
                        detail.replaceMyNotes(notes)
                        model.post("Added to your notes.")
                    }
                    AskBar(scope: .meeting(recording.id)) { EmptyView() }
                }
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.xs)
            }
        }
        .toolbar { toolbar(recording) }
        .task(id: LoadKey(id: recording.id, version: model.version(of: recording.id), live: isLive)) {
            await detail.load(recording, store: model.store, isLive: isLive)
        }
        .onChange(of: notesJob) { _, job in if job != nil { notesMode = .enhanced } }
        .confirmRegenerate($confirmRegenerate) { generateNotes(recording) }
        .onDisappear { detail.player.stop() }
        .sheet(item: $editingSpeaker) { SpeakerEditor(request: $0).presentationDetents([.medium, .large]) }
        .overlay(alignment: .bottom) { SpeakerUndoBar(recordingID: recording.id) }
        .animation(Motion.smooth, value: model.speakerUndo?.id)
        .sheet(item: $enlarged) { shot in
            ScreenshotViewer(screenshots: detail.screenshots, start: shot, showsTime: recording.hasAudio,
                             delete: { model.delete($0, in: recording) })
        }
        .sheet(isPresented: $transcribingAgain) { TranscribeAgainSheet(recording: recording) }
        .sheet(isPresented: $editingLanguages) { languagesSheet(recording) }
        .deleteMeetingsDialog($pendingDelete) { dismiss() }
    }

    // MARK: Header

    private func header(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TitleField(recording: recording, font: .displayMedium) { model.rename(recording, to: $0) }
            MetaLine([
                recording.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()),
                recording.durationText,
                model.folder(for: recording)?.name,
            ])
            if transcript?.usedCloud == true || isLive {
                HStack(spacing: Space.s) {
                    if isLive { StatusPill(.recording) }
                    if transcript?.usedCloud == true { StatusPill(.cloud) }
                }
            }
        }
        .padding(.top, Space.s)
    }

    // MARK: Notes

    @ViewBuilder private func notesSection(_ recording: Recording) -> some View {
        let enhanced = detail.enhancedNotes
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Picker("Notes", selection: Binding(get: { currentNotesMode }, set: { notesMode = $0 })) {
                    ForEach(NotesMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
                if currentNotesMode == .enhanced { notesActions(recording, enhanced: enhanced) }
            }
            switch currentNotesMode {
            case .mine:
                NotesEditor(initial: detail.myNotes, placeholder: "Write what matters to you…") {
                    model.saveMyNotes($0, for: recording)
                    detail.setMyNotes($0)
                }
                .frame(minHeight: 220)
                .id(recording.id)
            case .enhanced:
                if notesJob != nil {
                    NotesJobView(recording: recording) { generateNotes(recording) }
                } else if let enhanced {
                    MarkdownView(enhanced, hidesTitle: true, myNotes: detail.myNotes)
                } else {
                    GenerateNotesPrompt(recording: recording) { generateNotes(recording) }
                }
            }
        }
    }

    @ViewBuilder private func notesActions(_ recording: Recording, enhanced: String?) -> some View {
        if notesJob?.isRunning == true {
            Button("Stop", systemImage: "stop.fill") { model.cancelNotes(for: recording) }
                .buttonStyle(.bordered)
        } else {
            if model.settings.notesProvider.isCloud { StatusPill(.cloud) }
            if let enhanced {
                Menu {
                    Button("Regenerate…", systemImage: "sparkles") { confirmRegenerate = true }
                        .disabled(model.settings.notesUnavailableReason != nil)
                    TemplatePicker()
                    Divider()
                    Button("Copy Notes", systemImage: "doc.on.doc") {
                        Clipboard.copy(enhanced)
                        model.post("Copied the notes.")
                    }
                    ShareLink(item: enhanced, preview: SharePreview(recording.title)) {
                        Label("Share Notes", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Notes actions", systemImage: "sparkles")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Notes actions")
            }
        }
    }

    private func generateNotes(_ recording: Recording) {
        notesMode = .enhanced
        model.generateNotes(for: recording)
    }

    // MARK: Transcript

    private func transcriptSection(_ recording: Recording) -> some View {
        MeetingTranscript(recording: recording, detail: detail, isLive: isLive,
                          transcribeAgain: { transcribingAgain = true },
                          editSpeaker: { editSpeaker($0, $1, recording) },
                          open: { enlarged = $0 })
    }

    // MARK: Photos

    private func photosSection(_ recording: Recording) -> some View {
        ScreensGrid(screenshots: detail.screenshots, open: { enlarged = $0 }) { shot in
            ShareLink(item: shot.url)
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(shot, in: recording) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ recording: Recording) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                MeetingActions(recording: recording, transcript: transcript, screenshots: detail.screenshots, isLive: isLive,
                               transcribeAgain: { transcribingAgain = true }, delete: { pendingDelete = [recording] },
                               editLanguages: { editingLanguages = true })
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    private func languagesSheet(_ recording: Recording) -> some View {
        NavigationStack {
            Form {
                Section {
                    MeetingLanguages(recording: recording)
                } footer: {
                    Text("Auto handles meetings with several languages. Notes in a set language are translated.")
                }
            }
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingLanguages = false } } }
        }
        .presentationDetents([.medium])
    }

    // MARK: Actions

    private func editSpeaker(_ speaker: Speaker, _ transcript: Transcript, _ recording: Recording) {
        editingSpeaker = SpeakerEditorRequest(speaker: speaker, transcript: transcript, recording: recording)
    }
}
#endif
