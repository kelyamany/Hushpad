#if os(macOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// Two columns: the sidebar (all meetings, folders), then one main area that shows the list of meetings
/// as a home page, or the meeting you opened, full width, with a back button.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingDelete: [Recording] = []

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            MacSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            if let id = model.selection, model.recordings.contains(where: { $0.id == id }) {
                MacDetailView(recordingID: id, pendingDelete: $pendingDelete)
                    .id(id)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Back", systemImage: "chevron.left") { model.selection = nil }
                                .keyboardShortcut("[", modifiers: .command)
                                .help("Back to all meetings (⌘[)")
                        }
                    }
            } else {
                MacMeetingList(pendingDelete: $pendingDelete)
            }
        }
        .noticeBanner()
        .modifier(GranolaImportModifier(isPicking: $model.showGranolaImport))
        .sheet(item: $model.mergeRequest) { MergeSheet(start: $0) }
        .sheet(item: $model.folderEditor) { FolderEditor(request: $0) }
        .errorAlert()
        .deleteMeetingsDialog($pendingDelete)
        .sheet(isPresented: Binding(get: { !model.settings.onboarded }, set: { if !$0 { model.settings.onboarded = true } })) {
            MacOnboardingView()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.reload() } }
        #if DEBUG
        .onChange(of: model.sections.count) {
            if ProcessInfo.processInfo.environment["LOCALSCRIBE_SNAPSHOT_SELECT"] != nil, model.selection == nil {
                model.selection = model.sections.first?.recordings.first?.id
            }
        }
        .onAppear {
            DebugSnapshot.scheduleIfRequested()
        }
        #endif
        .onDeleteCommand {
            if let id = model.selection, let recording = model.recordings.first(where: { $0.id == id }) { pendingDelete = [recording] }
        }
    }
}

// MARK: - Sidebar

private struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var pendingFolderDelete: Folder?

    var body: some View {
        List(selection: Binding<LibrarySource?>(get: { model.source }, set: { model.source = $0 ?? .all })) {
            Section {
                Label("All Meetings", systemImage: "tray.full").tag(LibrarySource.all)
                if model.hasImported {
                    Label("Imported", systemImage: "square.and.arrow.down").tag(LibrarySource.imported)
                }
            }
            Section {
                ForEach(model.folders) { folder in
                    FolderLabel(folder)
                        .badge(model.folderCounts[folder.id] ?? 0)
                        .tag(LibrarySource.folder(folder.id))
                        .dropDestination(for: String.self) { items, _ in
                            model.move(items.compactMap(UUID.init(uuidString:)), to: folder)
                            return true
                        }
                        .contextMenu {
                            Button("Edit Folder…", systemImage: "pencil") { model.folderEditor = FolderEditorRequest(folder: folder) }
                            Button("Export Folder…", systemImage: "shippingbox") {
                                model.export(model.recordings.filter { $0.folderID == folder.id })
                            }
                            .disabled(model.folderCounts[folder.id, default: 0] == 0 || model.exportProgress != nil)
                            Button("Delete Folder…", systemImage: "trash", role: .destructive) { pendingFolderDelete = folder }
                        }
                }
                .onMove { model.moveFolder(from: $0, to: $1) }
                if model.folders.isEmpty {
                    Button { model.folderEditor = FolderEditorRequest() } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus").foregroundStyle(Theme.inkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { model.folderEditor = FolderEditorRequest() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("New Folder…")
                        .accessibilityLabel("New Folder")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { NewMeetingButton().padding(.horizontal, Space.m).padding(.vertical, Space.s) }
        .deleteFolderDialog($pendingFolderDelete)
    }
}

/// The one Record entry in the window: "New Meeting", or the live timer with Stop while recording.
private struct NewMeetingButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let start = model.recordingStartedAt {
            HStack(spacing: Space.s) {
                LiveWaveform(bars: 10, color: Theme.record) { model.session?.micLevel ?? 0 }
                    .frame(width: 34, height: 16)
                ElapsedTime(since: start).font(.small.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Button { Task { await model.stopRecording() } } label: {
                    Label("Stop", systemImage: "stop.fill").font(.small.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.record)
                .help("Stop Recording (⇧⌘R)")
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Theme.record.opacity(0.08), in: Radius.shape(Radius.m))
            .contentShape(Rectangle())
            .onTapGesture(perform: showRecording)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Show Recording", showRecording)
        } else {
            Button { Task { await model.startRecording() } } label: {
                Label {
                    Text("New Meeting")
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(Theme.record).imageScale(.small)
                }
                .font(.small.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xs)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Start Recording (⇧⌘R)")
        }
    }

    private func showRecording() {
        if let id = model.session?.recording.id { model.selection = id }
    }
}

// MARK: - Meeting list

private struct MacMeetingList: View {
    @Environment(AppModel.self) private var model
    @Binding var pendingDelete: [Recording]
    /// What's highlighted in the list. One meeting opens it; several offer bulk actions in the menu.
    @State private var picked: Set<UUID> = []

    var body: some View {
        @Bindable var model = model
        List(selection: $picked) {
            if !model.sections.isEmpty {
                Text(model.sourceTitle)
                    .font(.displayMedium)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, Space.l)
                    .padding(.bottom, Space.xs)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.recordings) { recording in
                        MeetingRow(recording: recording)
                            .tag(recording.id)
                            .draggable(recording.id.uuidString)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(section.title)
                        .font(.label.weight(.medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.top, Space.s)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: model.recordings.filter { ids.contains($0.id) })
        }
        // A plain click opens the meeting; ⌘- and ⇧-click build a selection for bulk actions instead.
        .onChange(of: picked) { _, ids in
            let extending = !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
            if ids.count == 1, !extending { model.selection = ids.first }
        }
        .onAppear { picked = [] }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.s) {
                ExportProgressPill()
                if !model.recordings.isEmpty {
                    ChatThread(scope: .library)
                    AskBar(scope: .library, placeholder: "Ask about your meetings") { EmptyView() }
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.m)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search meetings")
        .navigationTitle(model.sourceTitle)
        .overlay { emptyState }
    }

    @ViewBuilder private func menu(for recordings: [Recording]) -> some View {
        if !recordings.isEmpty {
            MoveToFolderMenu(recordings: recordings)
            if let recording = recordings.first, recordings.count == 1 {
                Button("Merge With…", systemImage: "arrow.triangle.merge") { model.mergeRequest = recording }
                    .disabled(!model.canMerge(recording))
            }
            Button(recordings.count == 1 ? "Export Meeting…" : "Export \(recordings.count) Meetings…", systemImage: "shippingbox") {
                model.export(recordings)
            }
            .disabled(recordings.contains { model.session?.recording.id == $0.id } || model.exportProgress != nil)
            Divider()
            Button(recordings.count == 1 ? "Delete…" : "Delete \(recordings.count) Meetings…", systemImage: "trash", role: .destructive) {
                pendingDelete = recordings
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.sections.isEmpty {
            if LibraryStatusView.applies(model) {
                LibraryStatusView()
            } else if !model.query.isEmpty {
                EmptyState(.search, title: "No results", message: "Nothing matches “\(model.query)”.")
            } else if case .folder = model.source {
                EmptyState(.folder, title: "This folder is empty",
                           message: "Drag meetings here, or use Move to Folder.")
            } else if model.recordings.isEmpty {
                EmptyState(.library, title: "No meetings yet", message: "Start one with New Meeting, or press ⇧⌘R.") {
                    Button("Import from Granola…") { model.showGranolaImport = true }
                        .buttonStyle(.link)
                }
            }
        }
    }
}
#endif
