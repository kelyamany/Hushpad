#if os(macOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI
import UniformTypeIdentifiers

/// Notes in one column: switch between what you wrote and the enhanced notes.
/// "Generate" combines your notes with the transcript using your local model (or a cloud model, if you allowed one).
struct MacNotesView: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let detail: MeetingDetailModel

    @State private var mode: NotesMode?
    @State private var editing = false
    @State private var draft = ""
    @State private var exporting = false
    @State private var copied = false
    @State private var confirmRegenerate = false

    private var job: NotesJob? { model.notesJobs[recording.id] }
    private var enhanced: String? { detail.enhancedNotes }
    private var currentMode: NotesMode { mode ?? (enhanced != nil || job != nil ? .enhanced : .mine) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            bar
            switch currentMode {
            case .mine:
                NotesEditor(initial: detail.myNotes, placeholder: "Write what matters to you. Generated notes keep every point you write here.") {
                    model.saveMyNotes($0, for: recording)
                    detail.setMyNotes($0)
                }
                .frame(minHeight: 380)
                .id("\(recording.id)-\(detail.notesGeneration)")
            case .enhanced:
                enhancedContent
                if job == nil, !editing { instructionsCaption }
            }
        }
        .onChange(of: job) { _, newValue in if newValue != nil { mode = .enhanced } }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            do {
                let file = try model.exportNotes(recording, to: folder)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .confirmRegenerate($confirmRegenerate, action: generate)
    }

    // MARK: Bar: My Notes / Enhanced, then the one primary action

    private var bar: some View {
        HStack(spacing: Space.s) {
            Picker("Notes", selection: Binding(get: { currentMode }, set: { mode = $0; editing = false })) {
                ForEach(NotesMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if currentMode == .enhanced { enhancedActions }
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var enhancedActions: some View {
        if job?.isRunning == true {
            Button("Stop", systemImage: "stop.fill") { model.cancelNotes(for: recording) }
        } else if editing {
            Button("Cancel") { editing = false }
            Button("Save") {
                model.saveEnhancedNotes(draft, for: recording)
                detail.setEnhancedNotes(draft)
                editing = false
            }
            .buttonStyle(.borderedProminent)
        } else {
            if model.settings.notesProvider.isCloud { StatusPill(.cloud).help("Your notes and the transcript are sent to \(model.settings.notesProvider.displayName).") }
            if let enhanced {
                Button {
                    Clipboard.copy(enhanced)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy as Markdown (for Obsidian)")
                Menu {
                    TemplatePicker()
                    Divider()
                    Button("Edit Notes", systemImage: "pencil") { draft = enhanced; editing = true }
                    Button("Export as Markdown…", systemImage: "square.and.arrow.up") { exporting = true }
                } label: {
                    Label("Regenerate…", systemImage: "sparkles")
                } primaryAction: {
                    confirmRegenerate = true
                }
                .fixedSize()
                .help("Write the notes again (⇧⌘G). The arrow has templates, editing and export.")
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }

    /// Where the instructions come from and which language the notes are in.
    private var instructionsCaption: some View {
        let source = model.settings.notesInstructions(folder: model.folder(for: recording)).source
        let language = recording.notesLanguage == .auto ? nil : "Notes in \(recording.notesLanguage.displayName)"
        return MetaLine([source, language])
    }

    // MARK: Enhanced

    @ViewBuilder private var enhancedContent: some View {
        if job != nil {
            NotesJobView(recording: recording, retry: generate)
        } else if editing {
            TextEditor(text: $draft)
                .font(.mono)
                .frame(minHeight: 420)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .background(Theme.paperSunken, in: Radius.shape(Radius.m))
        } else if let enhanced {
            MarkdownView(enhanced, hidesTitle: true, myNotes: detail.myNotes)
        } else {
            GenerateNotesPrompt(recording: recording, generate: generate)
        }
    }

    private func generate() {
        editing = false
        mode = .enhanced
        model.generateNotes(for: recording)
    }
}
#endif
