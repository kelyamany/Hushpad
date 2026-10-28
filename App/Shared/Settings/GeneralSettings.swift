import HushpadKit
import HushpadUI
import SwiftUI
import UniformTypeIdentifiers

/// General: where meetings are kept, call detection (Mac), version.
struct GeneralSettings: View {
    var body: some View {
        LibrarySection()
        #if os(macOS)
        MeetingsSection()
        AboutSection()
        #endif
    }
}

// MARK: - Library (sync)

struct LibrarySection: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var pending: URL?
    @State private var confirmLocal = false

    var body: some View {
        Section {
            LabeledContent {
                Text(model.libraryIsCustom ? model.store.root.lastPathComponent : "This device")
                    .foregroundStyle(.secondary)
            } label: {
                Label("Library", systemImage: model.libraryIsCustom ? "folder" : "internaldrive")
                    .help(model.libraryDisplayPath)
            }
            Button(model.libraryIsCustom ? "Choose a Different Folder…" : "Choose Folder…") { choosing = true }
            if model.libraryIsCustom {
                #if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.open(model.store.root) }
                #endif
                Button("Keep Meetings on This Device Only…") { pending = nil; confirmLocal = true }
            }
            Button {
                model.export(nil, fromSettings: true)
            } label: {
                if let progress = model.exportProgress {
                    LabeledContent("Exporting…") { Text(progress, format: .percent.precision(.fractionLength(0))) }
                } else {
                    Text("Export All Meetings…")
                }
            }
            .disabled(model.recordings.isEmpty || model.exportProgress != nil)
        } header: {
            Text("Library & Sync")
        } footer: {
            Text(SettingsCopy.librarySync)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { pending = url }
        }
        .confirmationDialog("Move your meetings?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Move \(model.recordings.count) Meetings There") { apply(pending, move: true) }
            Button("Just Switch (Leave Them Here)") { apply(pending, move: false) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The new folder becomes your library. Meetings already in it will appear too.")
        }
        .confirmationDialog("Keep meetings on this device only?", isPresented: $confirmLocal, titleVisibility: .visible) {
            Button("Move Meetings to This Device") { apply(nil, move: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll stop syncing with your other devices.")
        }
    }

    private func apply(_ url: URL?, move: Bool) {
        model.setLibraryFolder(url, moveExisting: move)
        pending = nil
    }
}

// MARK: - Meetings (Mac)

#if os(macOS)
/// Meeting detection: offer "Take notes" when a call starts, stop when it ends.
struct MeetingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle(isOn: $settings.detectMeetings) {
                Text("Offer to take notes when a call starts")
                Text(SettingsCopy.meetingsOffer)
            }
            if settings.detectMeetings {
                LabeledContent("Never offer for") {
                    Menu(settings.ignoredMeetingApps.isEmpty ? "No apps" : settings.ignoredMeetingApps.sorted().joined(separator: ", ")) {
                        ForEach(MeetingApp.allNames, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { settings.ignoredMeetingApps.contains(name) },
                                set: { on in
                                    settings.ignoredMeetingApps.removeAll { $0 == name }
                                    if on { settings.ignoredMeetingApps.append(name) }
                                }))
                        }
                    }
                    .fixedSize()
                }
            }
            Toggle(isOn: $settings.stopWhenCallEnds) {
                Text("Stop when the meeting is over")
                Text(SettingsCopy.meetingsStop)
            }
        } header: {
            SettingsHeader("Meetings", info: SettingsCopy.infoMeetings)
        }
        .onChange(of: settings.detectMeetings) { model.meetings.updateEnabled() }
        .onChange(of: settings.stopWhenCallEnds) { model.meetings.updateEnabled() }
    }
}
#endif

// MARK: - About

struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            PrivacyFooter()
        }
    }
}

/// A section title with an optional ⓘ for the longer explanation.
struct SettingsHeader: View {
    let title: String
    let info: String?

    init(_ title: String, info: String? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(title)
            if let info { InfoButton(info) }
        }
    }
}
