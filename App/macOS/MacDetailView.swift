#if os(macOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI
import UniformTypeIdentifiers

/// One meeting as a document: serif title, a quiet meta line, your notes (or the enhanced notes),
/// the transcript in a drawer on the right (live captions while recording), and "Ask anything" floating at the bottom.
struct MacDetailView: View {
    @Environment(AppModel.self) private var model
    let recordingID: UUID
    @Binding var pendingDelete: [Recording]

    @SceneStorage("showTranscript") private var showTranscript = false
    @State private var detail = MeetingDetailModel()
    @State private var editingSpeaker: SpeakerEditorRequest?
    @State private var enlarged: Screenshot?
    @State private var transcribingAgain = false
    @State private var addingImages = false
    @State private var dropTargeted = false

    private var recording: Recording? { model.recordings.first { $0.id == recordingID } }
    private var transcript: Transcript? { detail.transcript }
    private var isLive: Bool { model.session?.recording.id == recordingID }

    var body: some View {
        if let recording {
            content(recording)
        } else {
            EmptyState(.search, title: "Meeting not found", message: "It may have been deleted on another device.")
        }
    }

    private func content(_ recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header(recording)
                if let job = model.jobs[recording.id] ?? model.pausedTranscription(recording).map(JobState.paused) {
                    JobCard(job: job, retry: { model.transcribe(recording) }, pause: { model.pauseTranscription(recording) })
                }
                if detail.isLoaded {
                    MacNotesView(recording: recording, detail: detail)
                    MacAttachmentsView(recording: recording, detail: detail, isLive: isLive,
                                       enlarged: $enlarged, addingImages: $addingImages)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(.horizontal, Space.xxl + Space.s)
            .padding(.top, Space.xl)
            .padding(.bottom, Size.floatingBarInset)
            .frame(maxWidth: Size.readableWidth + 80, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .paperBackground()
        .safeAreaInset(edge: .bottom) { bottomBar(recording) }
        .inspector(isPresented: $showTranscript) {
            transcriptDrawer(recording)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
        .toolbar { toolbar(recording) }
        .navigationTitle("")
        .task(id: LoadKey(id: recording.id, version: model.version(of: recording.id), live: isLive)) {
            // A meeting being recorded still lives in the staging folder until it stops.
            let store = isLive ? ((try? RecordingStore.staging()) ?? model.store) : model.store
            await detail.load(recording, store: store, isLive: isLive)
            if isLive, !model.liveNotes.isEmpty { detail.replaceMyNotes(model.liveNotes) }
            while isLive, !Task.isCancelled, let folder = model.session?.folder {
                try? await Task.sleep(for: .seconds(4))
                await detail.refreshScreenshots(in: folder)
            }
        }
        .onDisappear { detail.player.stop() }
        .sheet(item: $editingSpeaker) { SpeakerEditor(request: $0) }
        .overlay(alignment: .bottom) {
            SpeakerUndoBar(recordingID: recording.id).frame(maxWidth: 560)
        }
        .animation(Motion.smooth, value: model.speakerUndo?.id)
        .sheet(item: $enlarged) { shot in
            ScreenshotViewer(screenshots: detail.screenshots, start: shot, showsTime: recording.hasAudio,
                             delete: isLive ? nil : { model.delete($0, in: recording) })
        }
        .sheet(isPresented: $transcribingAgain) { TranscribeAgainSheet(recording: recording) }
        // Image files dropped anywhere on the meeting go into its attachments.
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            guard !isLive, !images.isEmpty else { return false }
            Task { await model.addImages(images, to: recording) }
            return true
        } isTargeted: { dropTargeted = $0 && !isLive }
        .overlay {
            if dropTargeted {
                Radius.shape(Radius.l)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(Space.s)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $addingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { Task { await model.addImages(urls, to: recording) } }
        }
    }

    // MARK: Header

    private func header(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TitleField(recording: recording) { model.rename(recording, to: $0) }
            HStack(spacing: Space.s) {
                if let folder = model.folder(for: recording) {
                    FolderLabel(folder).font(.meta).foregroundStyle(Theme.inkSecondary)
                    Text("·").font(.meta).foregroundStyle(Theme.inkTertiary)
                }
                MetaLine([
                    recording.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()),
                    recording.durationText,
                    recording.attendees.isEmpty ? nil : recording.attendees.joined(separator: ", "),
                ])
                if let transcript, transcript.usedCloud { StatusPill(.cloud).help("Transcribed with \(model.engineLabel(transcript.engine))") }
                if isLive { StatusPill(.recording) }
            }
            if !isLive {
                HStack(spacing: Space.m) {
                    MeetingLanguages(recording: recording)
                }
                // Quiet chips: text and a chevron, no bezel.
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .font(.label)
                .foregroundStyle(Theme.inkTertiary)
                .tint(Theme.inkSecondary)
                .fixedSize()
            }
        }
    }

    // MARK: Bottom bar: Generate Notes, Ask, transcript toggle

    private func bottomBar(_ recording: Recording) -> some View {
        VStack(spacing: Space.s) {
            ExportProgressPill()
            ChatThread(scope: .meeting(recording.id)) { answer in addToNotes(answer, recording) }
            if !isLive, detail.isLoaded, detail.enhancedNotes == nil, model.notesJobs[recording.id] == nil,
               transcript != nil, model.settings.notesUnavailableReason == nil {
                Button { model.generateNotes(for: recording) } label: {
                    Label("Generate Notes", systemImage: "sparkles")
                        .font(.small.weight(.medium))
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs + 2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink)
                .background(Theme.highlight, in: Capsule())
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Write meeting notes from your notes and the transcript (⇧⌘G)")
            }
            AskBar(scope: .meeting(recording.id)) {
                Button { showTranscript.toggle() } label: {
                    HStack(spacing: 5) {
                        if isLive {
                            LiveWaveform(bars: 3, color: model.isPaused ? Theme.inkTertiary : Theme.listening) { model.session?.micLevel ?? 0 }
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "text.quote")
                        }
                        Text("Transcript").font(.small)
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 5)
                    .background(showTranscript ? Theme.paperSunken : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkSecondary)
                .keyboardShortcut("t", modifiers: [.command, .option])
                .help("Show or hide the transcript (⌥⌘T)")
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.m)
    }

    private func addToNotes(_ answer: String, _ recording: Recording) {
        let current = isLive ? model.liveNotes : detail.myNotes
        let notes = current.isEmpty ? answer : current + "\n\n" + answer
        model.saveMyNotes(notes, for: recording)
        detail.replaceMyNotes(notes)
        model.post("Added to your notes.")
    }

    // MARK: Transcript (drawer)

    @ViewBuilder private func transcriptDrawer(_ recording: Recording) -> some View {
        if isLive {
            LiveTranscriptView(transcript: model.session?.live?.transcript, paused: model.isPaused)
                .background(Theme.paper)
        } else {
            ScrollView {
                transcriptSection(recording).padding(Space.l)
            }
            .background(Theme.paper)
            .safeAreaInset(edge: .bottom) {
                if recording.hasAudio, transcript != nil {
                    PlaybackBar(player: detail.player).padding(Space.s)
                }
            }
        }
    }

    private func transcriptSection(_ recording: Recording) -> some View {
        MeetingTranscript(recording: recording, detail: detail, isLive: isLive,
                          transcribeAgain: { transcribingAgain = true },
                          editSpeaker: { editSpeaker($0, $1, recording) },
                          open: { enlarged = $0 })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ recording: Recording) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                MeetingActions(recording: recording, transcript: transcript, screenshots: detail.screenshots, isLive: isLive,
                               transcribeAgain: { transcribingAgain = true }, delete: { pendingDelete = [recording] })
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    // MARK: Actions

    private func editSpeaker(_ speaker: Speaker, _ transcript: Transcript, _ recording: Recording) {
        editingSpeaker = SpeakerEditorRequest(speaker: speaker, transcript: transcript, recording: recording)
    }
}

#endif
