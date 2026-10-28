import HushpadKit
import HushpadUI
import SwiftUI
import UniformTypeIdentifiers

/// Model, language and people hints in one place (instead of a menu that mixes settings with actions).
/// The hints are remembered on the recording, so retries reuse them.
struct TranscribeAgainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let recording: Recording

    @State private var choice: WhisperModel?
    @State private var language: TranscriptLanguage = .auto
    @State private var room = 0
    @State private var call = 0
    @State private var existing: Set<String> = []

    private var busy: Bool { model.jobs[recording.id]?.isActive == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $choice) {
                        ForEach(model.settings.allModels) { whisper in
                            Text(label(for: whisper)).tag(Optional(whisper))
                        }
                    }
                    LanguagePicker("Language", selection: $language)
                } footer: {
                    footer
                }
                Section {
                    Picker(recording.hasSystemAudio ? "In the room" : "People", selection: $room) {
                        Text("Detect").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    if recording.hasSystemAudio {
                        Picker("On the call", selection: $call) {
                            Text("Detect").tag(0)
                            ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                } header: {
                    Text("How many people spoke?")
                } footer: {
                    Text("Optional. Helps when voices get mixed up.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Transcribe Again")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Transcribe", action: start).disabled(busy) }
            }
            .onAppear {
                choice = model.settings.model
                language = recording.language
                room = recording.roomSpeakers ?? 0
                call = recording.remoteSpeakers ?? 0
                existing = Set(model.transcripts(for: recording).map(\.engine))
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 440)
        #endif
    }

    @ViewBuilder private var footer: some View {
        if busy {
            Text("A transcription is running for this meeting. You can start another when it finishes.")
        } else {
            Text("Runs on this device; the audio never leaves it. Each model keeps its own version, so you can compare them and switch back any time.")
        }
    }

    /// "Large v3 · current", "Small · 190 MB download", "Base · has a version (replaced)".
    private func label(for whisper: WhisperModel) -> String {
        var parts = [whisper.displayName]
        if recording.activeEngine == whisper.engineIdentifier {
            parts.append("current")
        } else if existing.contains(whisper.engineIdentifier) {
            parts.append("redo")
        }
        if !model.isDownloaded(whisper) { parts.append(sizeNote(whisper)) }
        return parts.joined(separator: " · ")
    }

    private func sizeNote(_ whisper: WhisperModel) -> String {
        whisper.approxSizeMB.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0) * 1_000_000, countStyle: .file)) download" } ?? "download"
    }

    private func start() {
        var updated = recording
        updated.language = language
        updated.roomSpeakers = room == 0 ? nil : room
        updated.remoteSpeakers = call == 0 ? nil : call
        if updated != recording { model.update(updated) }
        model.transcribe(updated, with: choice)
        dismiss()
    }
}
