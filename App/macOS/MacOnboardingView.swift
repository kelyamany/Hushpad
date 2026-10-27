#if os(macOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// First launch: what LocalScribe does, where the library lives, permissions, the model download.
/// Every step can be skipped; anything left out is offered again the moment it's needed.
struct MacOnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var downloadFailed = false
    private let steps = ["Welcome", "Library", "Permissions", "Model", "Notes"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.accent : Theme.hairline)
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xl)

            Group {
                switch step {
                case 0: welcome
                case 1: library
                case 2: permissions
                case 3: modelStep
                default: notesStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xl)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))

            HStack {
                if step > 0 { Button("Back") { withAnimation(Motion.smooth) { step -= 1 } } }
                Spacer()
                if step < steps.count - 1 {
                    Button("Skip Setup") { finish() }.buttonStyle(.link)
                }
                Button(step < steps.count - 1 ? "Continue" : "Get Started") {
                    if step < steps.count - 1 { withAnimation(Motion.smooth) { step += 1 } } else { finish() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Space.xl)
        }
        .frame(width: 620, height: 580)
        .background(Theme.paper)
    }

    private func finish() {
        model.settings.onboarded = true
        dismiss()
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(.displayLarge).foregroundStyle(Theme.ink)
            Text(subtitle).font(.heading).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            SoundLine()
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 180, height: 34)
            heading("Welcome to LocalScribe", "Listen in, write less. Your meetings become notes, made on your Mac.")
            VStack(alignment: .leading, spacing: Space.l) {
                FeatureRow(symbol: "person.2.wave.2", title: "In the room and on calls",
                           detail: "Records your microphone and Zoom, Teams or Meet audio. No bot joins the call.")
                FeatureRow(symbol: "rectangle.on.rectangle", title: "Slides captured for you",
                           detail: "When someone shares their screen, new slides are added to the transcript.")
                FeatureRow(symbol: "sparkles", title: "Notes from your notes",
                           detail: "A model on your Mac turns what you jot down plus the transcript into clean notes.")
                FeatureRow(symbol: "lock", title: "Private by default",
                           detail: "Audio never leaves your devices. Text only goes to a cloud notes model if you choose one, marked “Uses cloud”.")
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Where should meetings live?",
                    "Pick a folder in iCloud Drive and choose the same one on your iPhone to sync. Or keep everything on this Mac.")
            Form { LibrarySection() }.formStyle(.grouped).scrollDisabled(true).scrollContentBackground(.hidden)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Permissions", "Allow these now so nothing interrupts your first meeting.")
            Form { PermissionsSection() }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            let whisper = model.settings.model
            let size = whisper.approxSizeMB.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1_000_000, countStyle: .file) }
            heading("Download the speech model",
                    "About \(size ?? "1.5 GB"), once. After that, transcription works offline.")
            let _ = model.revision
            if model.modelsReady {
                Label("Ready to transcribe", systemImage: "checkmark.circle.fill").font(.heading).foregroundStyle(Theme.success)
            } else if let fraction = model.modelDownloads[whisper.id] ?? model.modelDownloads["speakers"] {
                ProgressView(value: fraction) {
                    Text("Downloading… \(Int(fraction * 100))%")
                }
                Text("You can get started now; it keeps downloading.").foregroundStyle(Theme.inkSecondary)
            } else {
                if downloadFailed {
                    InlineBanner("The download didn't finish", detail: "Check your internet connection and try again.") { download() }
                } else {
                    Button("Download Now", systemImage: "arrow.down", action: download)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Text("Or skip for now: you'll be asked the first time you transcribe.")
                    .font(.small).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var notesStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            heading("Choose how notes are written",
                    "Optional. Use a model on this Mac (LM Studio or Ollama), or allow a cloud model. You can change this in Settings › Notes.")
            Form {
                NotesModelSection()
                CloudSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func download() {
        downloadFailed = false
        Task {
            await model.downloadSpeakerModel()
            await model.download(model.settings.model)
            downloadFailed = !model.modelsReady
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.heading)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.base.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
