import HushpadKit
import HushpadUI
import SwiftUI

/// Which model writes the meeting notes: provider, model and a connection check. Shared by the Mac Notes tab and the
/// iPhone Settings sheet. The choice syncs to your other devices; a local model (LM Studio, Ollama) runs on the Mac.
struct NotesModelSection: View {
    @Environment(AppModel.self) private var model
    @State private var models: [String] = []
    @State private var status: ConnectionStatus = .unknown

    enum ConnectionStatus: Equatable { case unknown, checking, ok(Int), failed(String) }

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker("Provider", selection: Binding(get: { settings.notesProvider }, set: { provider in
                settings.chooseNotesProvider(provider)
                Task { await refresh() }
            })) {
                ForEach(NotesProvider.allCases) { Text($0.displayName).tag($0) }
            }
            #if os(iOS)
            if !settings.notesProvider.isCloud {
                Label(SettingsCopy.notesOnMac, systemImage: "desktopcomputer")
                    .font(.label)
                    .foregroundStyle(Theme.inkSecondary)
            }
            #endif
            if settings.notesProviderAllowed || settings.notesProvider.isCloud {
                HStack {
                    if models.isEmpty {
                        TextField("Model", text: $settings.notesModel, prompt: Text("e.g. qwen3-14b"))
                    } else {
                        Picker("Model", selection: $settings.notesModel) {
                            if !models.contains(settings.notesModel) { Text("Choose…").tag("") }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Reload the list of models from the server")
                        .accessibilityLabel("Reload models")
                }
                statusRow
            }
            #if os(macOS)
            DisclosureGroup("Advanced") {
                TextField("Server address", text: $settings.notesBaseURL)
                    .onSubmit { Task { await refresh() } }
                Toggle("Add the transcript to the notes file (folded)", isOn: $settings.notesIncludeTranscript)
            }
            #endif
        } header: {
            Text("Notes model")
        } footer: {
            if settings.notesProvider.isCloud {
                Label("Uses cloud: your notes and transcript go to \(settings.notesProvider.displayName).", systemImage: "cloud")
                    .foregroundStyle(Theme.cloud)
                if settings.notesProvider == .openCodeGo { Text(SettingsCopy.notesOpenCodeGo) }
            } else {
                #if os(macOS)
                Text(localHint(settings.notesProvider))
                #endif
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder private var statusRow: some View {
        switch status {
        case .unknown: EmptyView()
        case .checking:
            Label("Connecting…", systemImage: "network").foregroundStyle(.secondary)
        case .ok(let count):
            Label("Connected · \(count) model\(count == 1 ? "" : "s") available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).lineLimit(3)
        }
    }

    private func localHint(_ provider: NotesProvider) -> String {
        switch provider {
        case .lmStudio: SettingsCopy.notesLocalLMStudio
        case .ollama: SettingsCopy.notesLocalOllama
        default: SettingsCopy.notesLocalCustom
        }
    }

    private func refresh() async {
        let settings = model.settings
        guard let url = URL(string: settings.notesBaseURL) else { return }
        let provider = settings.notesProvider
        if provider.isCloud, !settings.cloudEnabled || settings.key(for: provider).isEmpty {
            status = .failed("Turn on cloud notes and add your \(provider.displayName) key under Cloud first.")
            models = []
            return
        }
        #if os(iOS)
        guard provider.isCloud else {
            status = .unknown
            models = []
            return
        }
        #endif
        status = .checking
        do {
            let client = LLMClient.make(provider, baseURL: url, apiKey: provider.isCloud ? settings.key(for: provider) : nil,
                                        model: "", privateRouting: false)
            models = try await client.listModels()
            status = .ok(models.count)
            if settings.notesModel.isEmpty, let first = models.first { settings.notesModel = first }
        } catch {
            models = []
            status = .failed("Can't reach \(provider.displayName). \(provider.isCloud ? "Check your key and connection." : "Is it open, with its server started?")")
        }
    }
}
