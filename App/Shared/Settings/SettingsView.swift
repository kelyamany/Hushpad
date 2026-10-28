import HushpadKit
import HushpadUI
import SwiftUI

/// The Settings pages, the same five on Mac (tabs) and iPhone (a list of pages). Each page is short: a label per
/// control, at most one short caption, and the longer explanations behind ⓘ (see `SettingsCopy`).
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", recording = "Recording", notes = "Notes", privacy = "Privacy", models = "Models"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "waveform"
        case .notes: "sparkles"
        case .privacy: "hand.raised"
        case .models: "arrow.down.circle"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .recording: RecordingSettings()
        case .notes: NotesSettings()
        case .privacy: PrivacySettings()
        case .models: ModelsSection()
        }
    }
}

#if os(iOS)
/// iPhone: a short list of pages instead of one long scroll.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(SettingsPage.allCases) { page in
                    NavigationLink {
                        Form { page.content }
                            .navigationTitle(page.rawValue)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                    }
                }
            }
            AboutSection()
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(item: Binding(get: { model.shareFile?.fromSettings == true ? model.shareFile : nil },
                             set: { if $0 == nil { model.shareFile = nil } })) { ActivityView(url: $0.url) }
    }
}

/// The system share sheet for a file (an export zip), which also offers "Save to Files".
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
