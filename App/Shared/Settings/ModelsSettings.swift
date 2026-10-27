import LocalScribeKit
import LocalScribeUI
import SwiftUI

struct ModelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var repo = ""
    @State private var variant = ""

    var body: some View {
        let settings = model.settings
        Section {
            ForEach(settings.allModels) { ModelRow(whisper: $0) }
            SpeakerModelRow()
            DisclosureGroup("Add a Custom Model") {
                TextField("Hugging Face repo", text: $repo, prompt: Text("you/whisper-arabic-coreml"))
                    .autocorrectionDisabled()
                TextField("Model folder in the repo", text: $variant)
                    .autocorrectionDisabled()
                Button("Add Model") {
                    let name = variant.trimmingCharacters(in: .whitespaces)
                    let custom = WhisperModel(variant: name, repo: repo.trimmingCharacters(in: .whitespaces),
                                              displayName: name, note: repo)
                    if !settings.customModels.contains(custom) { settings.customModels.append(custom) }
                    repo = ""
                    variant = ""
                }
                .disabled(repo.isEmpty || variant.isEmpty)
            }
        } header: {
            Text("Speech Models")
        } footer: {
            Text(SettingsCopy.models)
        }
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let whisper: WhisperModel

    var body: some View {
        let _ = model.revision
        let downloaded = model.isDownloaded(whisper)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(whisper.displayName)
                    if whisper.id == model.settings.modelID {
                        Text("Default")
                            .font(.micro.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(Theme.accent)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text([whisper.approxSizeMB.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1_000_000, countStyle: .file) },
                      whisper.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.label).foregroundStyle(.secondary)
            }
            Spacer()
            if let fraction = model.modelDownloads[whisper.id] {
                ProgressRing(fraction: fraction).frame(width: 22, height: 22)
                Text("\(Int(fraction * 100))%").font(.label.monospacedDigit()).foregroundStyle(.secondary)
            } else if downloaded {
                Text("Downloaded").font(.label).foregroundStyle(.secondary)
                Menu {
                    if whisper.id != model.settings.modelID {
                        Button("Use as Default", systemImage: "star") { model.settings.modelID = whisper.id }
                    }
                    Button("Delete Download…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").imageScale(.large)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("Options for \(whisper.displayName)")
            } else {
                Button { Task { await model.download(whisper) } } label: {
                    Image(systemName: "arrow.down.circle").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(whisper.displayName)")
            }
        }
        .confirmationDialog("Delete the \(whisper.displayName) download?", isPresented: $confirmDelete) {
            Button("Delete Download", role: .destructive) {
                Task {
                    if await model.deleteModel(whisper) { model.settings.customModels.removeAll { $0 == whisper } }
                }
            }
        } message: {
            Text("You can download it again any time. Transcripts made with it are kept.")
        }
    }

    @State private var confirmDelete = false
}

struct SpeakerModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker separation")
                Text("Needed to tell people apart").font(.label).foregroundStyle(.secondary)
            }
            Spacer()
            if let fraction = model.modelDownloads["speakers"] {
                ProgressRing(fraction: fraction).frame(width: 22, height: 22)
            } else if model.speakerModelDownloaded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).imageScale(.large)
            } else {
                Button { Task { await model.downloadSpeakerModel() } } label: {
                    Image(systemName: "arrow.down.circle").imageScale(.large)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
