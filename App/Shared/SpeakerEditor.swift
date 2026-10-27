import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// What to change about one speaker in a transcript: rename them, or say they're the same person as another
/// speaker (diarization sometimes splits one voice in two, e.g. "Speaker A" and "Speaker B").
struct SpeakerEditorRequest: Identifiable {
    let speaker: Speaker
    let transcript: Transcript
    let recording: Recording
    var id: String { speaker.key }
}

struct SpeakerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SpeakerEditorRequest
    @State private var name: String
    @State private var duplicate: Speaker?

    init(request: SpeakerEditorRequest) {
        self.request = request
        _name = State(initialValue: request.speaker.name)
    }

    private var others: [(index: Int, speaker: Speaker)] {
        request.transcript.speakers.enumerated()
            .filter { $0.element.key != request.speaker.key }
            .map { ($0.offset, $0.element) }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit(save)
                } footer: {
                    Text("Every line from this speaker uses the new name.")
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.speaker.key) { other in
                            Button { merge(into: other.speaker) } label: {
                                HStack {
                                    SpeakerChip(name: other.speaker.name, colorIndex: other.index)
                                    Spacer()
                                    Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.inkTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Same person as \(other.speaker.name)")
                        }
                    } header: {
                        Text("Same person as…")
                    } footer: {
                        Text("Their lines join \(request.speaker.name)'s into one speaker. You can undo this.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.speaker.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(trimmed.isEmpty)
                }
            }
            .confirmationDialog("“\(duplicate?.name ?? "")” is already a speaker", isPresented: Binding(
                get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }), titleVisibility: .visible) {
                Button("Merge Into \(duplicate?.name ?? "")") {
                    if let duplicate { merge(into: duplicate) }
                }
                Button("Keep Separate") { rename() }
                Button("Cancel", role: .cancel) { duplicate = nil }
            } message: {
                Text("Is \(request.speaker.name) the same person? Merging joins their lines.")
            }
        }
        #if os(macOS)
        .frame(width: 380, height: others.isEmpty ? 200 : 420)
        #endif
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        if trimmed == request.speaker.name { return dismiss() }
        if let existing = request.transcript.speaker(named: trimmed, except: request.speaker.key) {
            duplicate = existing
        } else {
            rename()
        }
    }

    private func rename() {
        model.renameSpeaker(request.speaker, to: trimmed, in: request.transcript, recording: request.recording)
        dismiss()
    }

    private func merge(into target: Speaker) {
        model.mergeSpeaker(request.speaker, into: target, in: request.transcript, recording: request.recording)
        dismiss()
    }
}

/// "Merge Into ▸" for a speaker chip's context menu.
struct MergeSpeakerMenu: View {
    @Environment(AppModel.self) private var model
    let speaker: Speaker
    let transcript: Transcript
    let recording: Recording

    var body: some View {
        let others = transcript.speakers.filter { $0.key != speaker.key }
        if !others.isEmpty {
            Menu("Merge Into", systemImage: "arrow.triangle.merge") {
                ForEach(others) { other in
                    Button(other.name) { model.mergeSpeaker(speaker, into: other, in: transcript, recording: recording) }
                }
            }
        }
    }
}

/// A short-lived "Merged … · Undo" bar after changing speakers.
struct SpeakerUndoBar: View {
    @Environment(AppModel.self) private var model
    let recordingID: UUID

    var body: some View {
        if let undo = model.speakerUndo, undo.recordingID == recordingID {
            HStack(spacing: Space.m) {
                Text(undo.message).font(.small).foregroundStyle(Theme.ink).lineLimit(2)
                Spacer(minLength: Space.s)
                if undo.offerNotes {
                    Button("Update Notes") {
                        model.speakerUndo = nil
                        if let recording = model.recordings.first(where: { $0.id == recordingID }) { model.generateNotes(for: recording) }
                    }
                }
                Button("Undo") { model.undoSpeakerChange() }.fontWeight(.semibold)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.id) {
                try? await Task.sleep(for: .seconds(10))
                if model.speakerUndo?.id == undo.id { withAnimation(Motion.smooth) { model.speakerUndo = nil } }
            }
        }
    }
}
