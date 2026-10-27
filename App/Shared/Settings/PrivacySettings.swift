import LocalScribeKit
import LocalScribeUI
import SwiftUI

/// Privacy: app lock, audio retention, encryption, cloud notes and system permissions.
struct PrivacySettings: View {
    var body: some View {
        PrivacySection()
        CloudSection()
        PermissionsSection()
    }
}

struct PrivacySection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEncrypt = false
    @State private var confirmDecrypt = false
    @State private var recoveryInput = ""
    @State private var recoveryFailed = false
    /// A retention choice waiting for confirmation because it would delete audio right now.
    @State private var pendingRetention: (days: Int, count: Int)?

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("Lock with \(AppModel.biometryName)", isOn: Binding(
                get: { settings.lockEnabled },
                set: { value in Task { await model.setLock(value) } }))
            if settings.lockEnabled {
                Picker("Lock after", selection: $settings.lockAfterMinutes) {
                    Text("Immediately").tag(0)
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                }
            }
            Picker("Delete audio after", selection: Binding(get: { settings.audioRetentionDays }, set: chooseRetention)) {
                Text("Never").tag(0)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }
        } header: {
            #if os(iOS)
            SettingsHeader("App Lock & Audio", info: SettingsCopy.infoLockPhone)
            #else
            Text("App Lock & Audio")
            #endif
        } footer: {
            Text(settings.lockEnabled ? "\(SettingsCopy.lock) \(SettingsCopy.retention)" : SettingsCopy.retention)
        }

        .confirmationDialog("Delete old audio?", isPresented: Binding(get: { pendingRetention != nil },
                                                                      set: { if !$0 { pendingRetention = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Audio", role: .destructive) {
                if let pending = pendingRetention {
                    model.settings.audioRetentionDays = pending.days
                    model.applyAudioRetention()
                }
                pendingRetention = nil
            }
        } message: {
            let count = pendingRetention?.count ?? 0
            Text("\(count) meeting\(count == 1 ? "" : "s") older than that will lose \(count == 1 ? "its" : "their") audio now. Transcripts and notes stay. This can't be undone.")
        }

        Section {
            encryptionRows
        } header: {
            SettingsHeader("Encryption", info: SettingsCopy.infoEncryption)
        } footer: {
            Text(SettingsCopy.encryption)
        }
        .confirmationDialog("Encrypt your library?", isPresented: $confirmEncrypt) {
            Button("Encrypt Library") { model.enableEncryption() }
        } message: {
            Text("Every meeting is encrypted on this device and in sync. You'll get a Recovery Key: without it and your iCloud Keychain, the meetings can't be opened again.")
        }
        .confirmationDialog("Turn off encryption?", isPresented: $confirmDecrypt) {
            Button("Decrypt Library", role: .destructive) { model.disableEncryption() }
        } message: {
            Text("Your meetings are stored as plain files again.")
        }
        .sheet(item: Binding(get: { model.privacy.recoveryKey.map(RecoveryKey.init) },
                             set: { if $0 == nil { model.privacy.recoveryKey = nil } })) { key in
            RecoveryKeySheet(key: key.text)
        }
    }

    @ViewBuilder private var encryptionRows: some View {
        if let progress = model.privacy.converting {
            ProgressView(value: progress) {
                Text(model.settings.libraryEncrypted ? "Encrypting meetings…" : "Decrypting meetings…")
            }
        } else if model.privacy.needsKey {
            Label("This library is encrypted. Enter your Recovery Key to open it here, or wait for iCloud Keychain to bring the key.",
                  systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(Theme.cloud)
            SecureField("Recovery Key", text: $recoveryInput)
                .onSubmit(submitRecovery)
            Button("Unlock Library", action: submitRecovery).disabled(recoveryInput.isEmpty)
            if recoveryFailed {
                Text("That Recovery Key doesn't match this library.").foregroundStyle(Theme.danger).font(.label)
            }
        } else if model.settings.libraryEncrypted {
            Label("Library encrypted", systemImage: "lock.fill")
            Button("Show Recovery Key…") { model.showRecoveryKey() }
            Button("Turn Off Encryption…", role: .destructive) { confirmDecrypt = true }
        } else {
            Button("Encrypt Library…") { confirmEncrypt = true }
                .disabled(model.isRecording)
        }
    }

    private func chooseRetention(_ days: Int) {
        let count = model.audioExpired(after: days).count
        if count > 0 {
            pendingRetention = (days, count)
        } else {
            model.settings.audioRetentionDays = days
        }
    }

    private func submitRecovery() {
        recoveryFailed = !model.enterRecoveryKey(recoveryInput)
        if !recoveryFailed { recoveryInput = "" }
    }
}

private struct RecoveryKey: Identifiable {
    let text: String
    var id: String { text }
}

private struct RecoveryKeySheet: View {
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Your Recovery Key").font(.displaySmall)
            Text("Write it down or save it in your password manager. You need it to open your meetings on a device without your iCloud Keychain.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(key)
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: Radius.shape(Radius.l))
            HStack {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    #else
                    UIPasteboard.general.string = key
                    #endif
                    copied = true
                }
                ShareLink(item: "LocalScribe Recovery Key: \(key)") { Label("Save…", systemImage: "square.and.arrow.up") }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 440)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

// MARK: - Cloud

struct CloudSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            Toggle("Allow cloud notes", isOn: $settings.cloudEnabled.animation())
            if settings.cloudEnabled {
                CloudKeyField(provider: .openRouter)
                CloudKeyField(provider: .openCodeGo)
                Toggle(isOn: $settings.cloudPrivateRouting) {
                    Text("Only providers that keep no data")
                    Text(SettingsCopy.cloudPrivateRouting)
                }
                Toggle(isOn: $settings.cloudMaskNames) {
                    Text("Hide names from cloud notes")
                    Text(SettingsCopy.cloudMaskNames)
                }
            }
        } header: {
            SettingsHeader("Cloud (optional)", info: SettingsCopy.infoCloud)
        } footer: {
            Text(SettingsCopy.cloud)
        }
    }
}

/// One provider's API key, with where it is stored and a link to get one.
private struct CloudKeyField: View {
    @Environment(AppModel.self) private var model
    let provider: NotesProvider
    @State private var key = ""

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: Space.xs) {
            SecureField("\(provider.displayName) API key", text: $key)
                .onChange(of: key) { _, value in settings.setKey(value, for: provider) }
            HStack {
                if !key.isEmpty {
                    Label(settings.keyIsSynced(provider) ? "Synced with iCloud Keychain" : "Saved on this device only",
                          systemImage: settings.keyIsSynced(provider) ? "key.icloud" : "key")
                        .font(.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = provider.keyURL { Link("Get a key", destination: url).font(.label) }
            }
        }
        .onAppear { key = settings.key(for: provider) }
    }
}

// MARK: - Permissions

struct PermissionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(Permission.allCases) { PermissionRow(permission: $0) }
        } header: {
            Text("Permissions")
        }
        // Keeps the rows in step with System Settings while this screen is open.
        .task { await model.permissions.watch() }
    }
}

struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let permission: Permission
    @State private var asking = false

    var body: some View {
        let status = model.permissions.status(permission)
        HStack(spacing: Space.m) {
            Image(systemName: permission.symbol)
                .font(.base.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.12), in: Radius.shape(Radius.s))
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(permission.title)
                    if !permission.isRequired { Text("Optional").font(.micro).foregroundStyle(.tertiary) }
                }
                Text(caption(status)).font(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.success)
                    .imageScale(.large)
                    .help("Allowed")
            case .notDetermined:
                Button("Allow") {
                    asking = true
                    Task {
                        await model.permissions.request(permission)
                        asking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(asking)
            case .denied, .unknown:
                Button("Open Settings") { Permissions.openSettings(for: permission) }
                    .controlSize(.small)
            case .needsRestart:
                #if os(macOS)
                Button("Restart") { Permissions.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                #else
                EmptyView()
                #endif
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The purpose, or what to do next when it isn't allowed.
    private func caption(_ status: PermissionStatus) -> String {
        switch status {
        case .denied:
            "Turned off. Switch on LocalScribe in \(AppModel.settingsName) › Privacy & Security › \(settingsPane)."
        case .unknown:
            "If calls record silently, check LocalScribe in \(AppModel.settingsName) › Privacy & Security › \(settingsPane)."
        case .needsRestart:
            "Allowed. Restart LocalScribe to start using it."
        default:
            permission.purpose
        }
    }

    private var settingsPane: String {
        switch permission {
        case .microphone: "Microphone"
        #if os(macOS)
        case .systemAudio: "Screen & System Audio Recording"
        case .screenRecording: "Screen & System Audio Recording"
        #else
        case .camera: "Camera"
        case .notifications: "Notifications"
        #endif
        }
    }
}
