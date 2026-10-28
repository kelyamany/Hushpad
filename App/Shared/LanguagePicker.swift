import SwiftUI
import HushpadKit

/// Auto, then the popular languages, then all the rest. A language the app doesn't know (a code from another device)
/// is kept in the list so the current choice always has a matching tag.
struct LanguagePicker: View {
    let title: String
    @Binding var selection: TranscriptLanguage
    let autoLabel: String

    init(_ title: String, selection: Binding<TranscriptLanguage>, autoLabel: String = "Auto-detect") {
        self.title = title
        _selection = selection
        self.autoLabel = autoLabel
    }

    private static let rest: [TranscriptLanguage] = {
        let common = Set(TranscriptLanguage.common)
        return TranscriptLanguage.all.filter { !common.contains($0) }
    }()

    private var isKnown: Bool {
        selection == .auto || TranscriptLanguage.common.contains(selection) || Self.rest.contains(selection)
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text(autoLabel).tag(TranscriptLanguage.auto)
            if !isKnown { Text(selection.displayName).tag(selection) }
            Section("Common") {
                ForEach(TranscriptLanguage.common) { Text($0.displayName).tag($0) }
            }
            Section("All Languages") {
                ForEach(Self.rest) { Text($0.displayName).tag($0) }
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
    }
}

/// A meeting's transcript and notes languages. Changing one offers to redo the work it affects.
struct MeetingLanguages: View {
    @Environment(AppModel.self) private var model
    let recording: Recording
    @State private var transcribeAgain: TranscriptLanguage?
    @State private var writeAgain: TranscriptLanguage?

    var body: some View {
        Group {
            LanguagePicker("Transcript", selection: Binding(get: { recording.language }, set: setTranscript))
            LanguagePicker("Notes", selection: Binding(get: { recording.notesLanguage }, set: setNotes),
                           autoLabel: "Same as the meeting")
        }
        .confirmationDialog("Transcribe again in \(transcribeAgain?.displayName ?? "")?",
                            isPresented: Binding(get: { transcribeAgain != nil }, set: { if !$0 { transcribeAgain = nil } }),
                            titleVisibility: .visible) {
            Button("Transcribe Again") { model.transcribe(current) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("The current transcript is kept as another version.")
        }
        .confirmationDialog("Regenerate the notes in \(writeAgain?.displayName ?? "")?",
                            isPresented: Binding(get: { writeAgain != nil }, set: { if !$0 { writeAgain = nil } }),
                            titleVisibility: .visible) {
            Button("Regenerate") { model.generateNotes(for: current) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("The notes you wrote are kept. The generated notes are replaced.")
        }
    }

    /// The latest copy, so a re-run uses the language just chosen.
    private var current: Recording { model.recordings.first { $0.id == recording.id } ?? recording }

    private func setTranscript(_ language: TranscriptLanguage) {
        guard language != recording.language else { return }
        var updated = recording
        updated.language = language
        model.update(updated)
        if recording.hasAudio, !model.transcripts(for: recording).isEmpty { transcribeAgain = language }
    }

    private func setNotes(_ language: TranscriptLanguage) {
        guard language != recording.notesLanguage else { return }
        var updated = recording
        updated.notesLanguage = language
        model.update(updated)
        if model.enhancedNotes(for: recording) != nil, model.settings.notesUnavailableReason == nil { writeAgain = language }
    }
}
