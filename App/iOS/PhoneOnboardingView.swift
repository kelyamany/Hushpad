#if os(iOS)
import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// Four short pages: what it is, syncing with the Mac, permissions, the model. Every page can be skipped;
/// anything left out is offered again when it's needed.
struct PhoneOnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < pageCount - 1 {
                    Button("Skip") { finish() }.foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(height: Size.hitTarget)
            .padding(.horizontal, Space.xl)

            TabView(selection: $page) {
                WelcomePage().tag(0)
                SyncPage().tag(1)
                PermissionsPage().tag(2)
                ModelPage().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            Button {
                if page < pageCount - 1 { withAnimation(Motion.smooth) { page += 1 } } else { finish() }
            } label: {
                Text(page < pageCount - 1 ? "Continue" : "Get Started")
                    .font(.base.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.xs + 2)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.l)
        }
        .paperBackground()
        .interactiveDismissDisabled()
    }

    private func finish() {
        model.settings.onboarded = true
        dismiss()
    }
}

private struct OnboardingPage<Art: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var art: Art
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                art.frame(height: 140).padding(.top, Space.l)
                Text(title).font(.displayLarge).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                Text(subtitle).font(.base).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                content.padding(.top, Space.s)
            }
            .padding(.horizontal, Space.xl + Space.xs)
            .padding(.bottom, 60)
        }
    }
}

private struct WelcomePage: View {
    var body: some View {
        OnboardingPage(title: "Hushpad",
                       subtitle: "Listen in, write less. Record any meeting and get notes that know who said what.") {
            Vignette(.library, size: 140)
        } content: {
            VStack(alignment: .leading, spacing: Space.l) {
                Feature(symbol: "person.2.wave.2", text: "Tells speakers apart, in almost 100 languages")
                Feature(symbol: "lock.iphone", text: "Keeps recording with the screen off, or from your Watch")
                Feature(symbol: "lock", text: "Runs on your iPhone. Audio never leaves your devices.")
            }
        }
    }
}

private struct SyncPage: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false

    var body: some View {
        OnboardingPage(title: "Use it with your Mac",
                       subtitle: "Pick the same folder here and on your Mac, for example iCloud Drive › Documents › Hushpad, to share one library.") {
            Vignette(.folder, size: 140)
        } content: {
            VStack(spacing: Space.m) {
                if model.libraryIsCustom {
                    Label("Using “\(model.store.root.lastPathComponent)”", systemImage: "checkmark.circle.fill")
                        .font(.base.weight(.semibold))
                        .foregroundStyle(Theme.success)
                }
                Button(model.libraryIsCustom ? "Choose a Different Folder…" : "Choose Folder…") { choosing = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Text("Or keep everything on this iPhone; you can change this in Settings.")
                    .font(.label).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setLibraryFolder(url, moveExisting: true) }
        }
    }
}

private struct PermissionsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPage(title: "Permissions", subtitle: "Only the microphone is needed. The others make it nicer.") {
            Vignette(.done, size: 140)
        } content: {
            VStack(spacing: Space.l) {
                ForEach(Permission.allCases) { PermissionRow(permission: $0) }
            }
            .card()
            .task { await model.permissions.watch() }
        }
    }
}

private struct ModelPage: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false

    var body: some View {
        let whisper = model.settings.model
        let size = whisper.approxSizeMB.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1_000_000, countStyle: .file) }
        OnboardingPage(title: "Download the speech model",
                       subtitle: "About \(size ?? "600 MB"), once. Then transcription works offline. Wi-Fi recommended.") {
            Vignette(.transcript, size: 140)
        } content: {
            VStack(spacing: Space.m) {
                let _ = model.revision
                if model.modelsReady {
                    Label("Ready to transcribe", systemImage: "checkmark.circle.fill")
                        .font(.base.weight(.semibold))
                        .foregroundStyle(Theme.success)
                } else if let fraction = model.modelDownloads[whisper.id] ?? model.modelDownloads["speakers"] {
                    ProgressView(value: fraction) { Text("Downloading… \(Int(fraction * 100))%") }
                    Text("You can get started; it keeps downloading.")
                        .font(.label).foregroundStyle(Theme.inkSecondary)
                } else {
                    if failed {
                        InlineBanner("The download didn't finish", detail: "Check your connection and try again.") { download() }
                    } else {
                        Button(action: download) {
                            Label("Download Now", systemImage: "arrow.down").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Text("Or later: it downloads the first time you transcribe.")
                        .font(.label).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private func download() {
        failed = false
        Task {
            await model.downloadSpeakerModel()
            await model.download(model.settings.model)
            failed = !model.modelsReady
        }
    }
}

private struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.base)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(text).font(.base).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
    }
}
#endif
