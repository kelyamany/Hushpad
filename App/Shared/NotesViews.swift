import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// A running or failed notes job for a meeting: progress, the notes as they stream in, or what went wrong.
/// Shows nothing when no job exists. Shared by Mac and iPhone.
struct NotesJobView: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let retry: () -> Void

    var body: some View {
        let draft = model.notesDrafts[recording.id] ?? ""
        switch model.notesJobs[recording.id] {
        case .condensing(let part, let total)?:
            progress("Reading the transcript… \(part) of \(total)")
        case .thinking?:
            progress("Thinking…")
        case .writing? where draft.isEmpty:
            progress("Starting…")
        case .writing?:
            MarkdownView(draft, hidesTitle: true)
        case .failed(let message)?:
            InlineBanner("Couldn't write the notes", detail: failureDetail(message), retry: retry)
        case nil:
            EmptyView()
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(Theme.inkSecondary)
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }

    private func failureDetail(_ message: String) -> String {
        guard !model.settings.notesProvider.isCloud else { return message }
        return message + "\n\nIs \(model.settings.notesProvider.displayName) running, with its server started and a model loaded?"
    }
}

/// The notes tab when there are no generated notes yet: one button, or what to set up first.
struct GenerateNotesPrompt: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    let generate: () -> Void

    var body: some View {
        let hasTranscript = model.summaries[recording.id]?.hasTranscript == true
        EmptyState(.notes, title: "Turn this meeting into notes",
                   message: hasTranscript
                       ? "Your notes and the transcript become a summary with decisions and action items."
                       : "Works best after transcribing. Your own notes alone work too.") {
            VStack(spacing: Space.s) {
                if let reason = model.settings.notesUnavailableReason {
                    Text(reason)
                        .font(.small)
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                    OpenSettingsButton()
                } else {
                    Button("Generate Notes", action: generate)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        #if os(macOS)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        #endif
                    Menu {
                        TemplatePicker()
                    } label: {
                        Text("Template: \(model.settings.template.name)")
                    }
                    #if os(macOS)
                    .menuStyle(.button)
                    .buttonStyle(.link)
                    #endif
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Opens Settings: the Settings window on the Mac, the Settings sheet on iPhone.
struct OpenSettingsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        SettingsLink { Text("Open Settings…") }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        #else
        Button("Open Settings") { model.showSettings = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        #endif
    }
}

/// The note templates, as a picker for menus.
struct TemplatePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Template", selection: Binding(get: { model.settings.notesTemplateID }, set: { model.settings.notesTemplateID = $0 })) {
            ForEach(model.settings.templates) { Text($0.name).tag($0.id) }
        }
    }
}

/// "Replace the current notes?" before writing them again.
extension View {
    func confirmRegenerate(_ isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        confirmationDialog("Replace the current notes?", isPresented: isPresented) {
            Button("Regenerate", action: action)
        } message: {
            Text("Your own notes are kept. Edits you made to the generated notes will be replaced.")
        }
    }
}
