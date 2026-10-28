import HushpadKit
import HushpadUI
import SwiftUI

/// Recording: what gets captured, and how it becomes a transcript.
struct RecordingSettings: View {
    var body: some View {
        RecordingSection()
        TranscriptionSection()
    }
}

struct RecordingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section("Recording") {
            #if os(macOS)
            Toggle("Record call audio (Zoom, Teams, Meet…)", isOn: $settings.captureSystemAudio)
            Picker("Screenshots of shared screens", selection: $settings.screenshotMode) {
                ForEach(ScreenshotMode.allCases) { Text($0.displayName).tag($0) }
            }
            #else
            Toggle("Camera button while recording", isOn: Binding(
                get: { settings.screenshotMode != .off },
                set: { settings.screenshotMode = $0 ? .manual : .off }))
            #endif
            Toggle("Live captions while recording", isOn: $settings.liveTranscript)
        }
    }
}

struct TranscriptionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Picker("Model", selection: $settings.modelID) {
                ForEach(settings.allModels) { Text($0.displayName).tag($0.id) }
            }
            Toggle(isOn: $settings.autoTranscribe) {
                Text("Full transcript when recording stops")
                Text(SettingsCopy.fullTranscript)
            }
            LanguagePicker("Spoken language", selection: $settings.language)
        } header: {
            SettingsHeader("Transcription", info: SettingsCopy.infoTranscription)
        }
    }
}
