#if os(iOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// Home: meetings grouped by day. The title is a menu that switches between All Meetings, Imported and folders.
/// One big record button at the bottom, or a mini player-style bar while recording.
struct PhoneRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var showRecorder = false
    @State private var pendingDelete: [Recording] = []
    @State private var pendingFolderDelete: Folder?
    @State private var moving: Recording?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.recordings) { recording in
                            NavigationLink(value: recording.id) {
                                MeetingRow(recording: recording)
                            }
                            .listRowBackground(Theme.paperRaised)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = [recording] }
                            }
                            .swipeActions(edge: .leading) {
                                if model.canMove(recording) {
                                    Button("Move", systemImage: "folder") { moving = recording }.tint(Theme.accent)
                                }
                            }
                            .contextMenu {
                                MoveToFolderMenu(recordings: [recording])
                                Button("Merge With…", systemImage: "arrow.triangle.merge") { model.mergeRequest = recording }
                                    .disabled(!model.canMerge(recording))
                                Divider()
                                Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = [recording] }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .overlay { emptyState }
            .navigationTitle(model.sourceTitle)
            .toolbarTitleMenu { sourceMenu }
            .searchable(text: $model.query, prompt: "Search meetings")
            .refreshable { model.reload() }
            .toolbar {
                // The title menu only opens from the small (scrolled) title, so folders also get a visible button.
                ToolbarItem(placement: .topBarLeading) {
                    Menu { sourceMenu } label: {
                        Label("Folders", systemImage: model.source == .all ? "folder" : "folder.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { model.showSettings = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in PhoneDetailView(recordingID: id) }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordingScreen { finished in
                showRecorder = false
                path = [finished]
            }
        }
        .noticeBanner()
        .confirmationDialog("Download over cellular?", isPresented: Binding(
            get: { model.cellularPrompt != nil }, set: { if !$0 { model.answerCellularPrompt(false) } }), titleVisibility: .visible) {
            Button("Download Now") { model.answerCellularPrompt(true) }
            Button("Wait for Wi-Fi", role: .cancel) { model.answerCellularPrompt(false) }
        } message: {
            let size = model.cellularPrompt?.megabytes.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1_000_000, countStyle: .file) }
            Text("The speech model is \(size ?? "large") and is downloaded once. You're not on Wi-Fi.")
        }
        .sheet(isPresented: $model.showSettings) { NavigationStack { SettingsView() } }
        .sheet(item: $model.mergeRequest) { MergeSheet(start: $0) }
        .sheet(item: $model.folderEditor) { FolderEditor(request: $0) }
        .sheet(item: Binding(get: { model.shareFile?.fromSettings == false ? model.shareFile : nil },
                             set: { if $0 == nil { model.shareFile = nil } })) { ActivityView(url: $0.url) }
        .sheet(item: $moving) { FolderPicker(recording: $0).presentationDetents([.medium, .large]) }
        .onChange(of: model.openRequest) { _, id in
            guard let id else { return }
            path = [id]
            model.openRequest = nil
        }
        .sheet(isPresented: Binding(get: { !model.settings.onboarded }, set: { if !$0 { model.settings.onboarded = true } })) {
            PhoneOnboardingView()
        }
        .deleteMeetingsDialog($pendingDelete)
        .deleteFolderDialog($pendingFolderDelete)
        .errorAlert()
        .onChange(of: scenePhase) { _, phase in
            // Pick up changes synced from the Mac while we were in the background.
            if phase == .active { model.reload() }
        }
        .onChange(of: model.isRecording) { _, recording in
            // Started from Control Center / Siri while the app was closed: show the recorder when we come back.
            if recording && scenePhase == .active && !showRecorder { showRecorder = true }
        }
    }

    // MARK: Title menu: what the list shows

    @ViewBuilder private var sourceMenu: some View {
        Picker("Show", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
            Label("All Meetings", systemImage: "tray.full").tag(LibrarySource.all)
            if model.hasImported {
                Label("Imported", systemImage: "square.and.arrow.down").tag(LibrarySource.imported)
            }
            ForEach(model.folders) { folder in
                Label(folder.name, systemImage: folder.symbol).tag(LibrarySource.folder(folder.id))
            }
        }
        Divider()
        Button("New Folder…", systemImage: "folder.badge.plus") { model.folderEditor = FolderEditorRequest() }
        if case .folder(let id) = model.source, let folder = model.folders.first(where: { $0.id == id }) {
            Button("Edit Folder…", systemImage: "pencil") { model.folderEditor = FolderEditorRequest(folder: folder) }
            Button("Delete Folder…", systemImage: "trash", role: .destructive) { pendingFolderDelete = folder }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.sections.isEmpty {
            Group {
                if LibraryStatusView.applies(model) {
                    LibraryStatusView()
                } else if !model.query.isEmpty {
                    EmptyState(.search, title: "No results", message: "Nothing matches “\(model.query)”.")
                } else if case .folder = model.source {
                    EmptyState(.folder, title: "This folder is empty",
                               message: "Swipe right on a meeting, or touch and hold it, to move it here.")
                } else {
                    EmptyState(.library, title: "No meetings yet",
                               message: "Tap the red button when a meeting starts. It's transcribed right on your iPhone.")
                }
            }
            .padding(.bottom, Size.floatingBarInset)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        ExportProgressPill()
        if model.isRecording {
            MiniRecorderBar { showRecorder = true }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            RecordButton(isRecording: false, diameter: 72) {
                Task {
                    await model.startRecording()
                    if model.isRecording { showRecorder = true }
                }
            }
            .padding(Space.s + 2)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding(.bottom, Space.xs)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// "Move to…" as a sheet (swipe actions can't hold menus).
private struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recording: Recording

    var body: some View {
        NavigationStack {
            List {
                Button { move(nil) } label: {
                    row(Label("No Folder", systemImage: "tray"), selected: recording.folderID == nil)
                }
                ForEach(model.folders) { folder in
                    Button { move(folder) } label: { row(FolderLabel(folder), selected: recording.folderID == folder.id) }
                }
                Button {
                    dismiss()
                    model.folderEditor = FolderEditorRequest(moving: [recording.id])
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
            }
            .tint(Theme.ink)
            .navigationTitle("Move to Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ label: some View, selected: Bool) -> some View {
        HStack {
            label
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }
    }

    private func move(_ folder: Folder?) {
        model.move([recording.id], to: folder)
        dismiss()
    }
}

/// While recording and the full-screen recorder is minimised.
struct MiniRecorderBar: View {
    @Environment(AppModel.self) private var model
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Button(action: onExpand) {
                HStack(spacing: Space.m) {
                    LiveWaveform(bars: 8, color: Theme.record) { model.session?.micLevel ?? 0 }
                        .frame(width: 30, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.session?.recording.title ?? "Recording").font(.small.weight(.semibold)).lineLimit(1)
                        if let start = model.recordingStartedAt {
                            ElapsedTime(since: start).font(.label).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show recording")
            Button { Task { await model.stopRecording() } } label: {
                Image(systemName: "stop.fill")
                    .font(.base.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: Size.hitTarget, height: Size.hitTarget)
                    .background(Theme.record, in: Circle())
            }
            .accessibilityLabel("Stop recording")
        }
        .padding(.leading, Space.l + 2)
        .padding(.trailing, Space.xs + 2)
        .padding(.vertical, Space.xs + 2)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
#endif
