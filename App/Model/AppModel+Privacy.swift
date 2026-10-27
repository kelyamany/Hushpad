import CryptoKit
import Foundation
import LocalAuthentication
import LocalScribeKit
import Observation

/// State for the privacy features: app lock and library encryption.
@MainActor
@Observable
final class PrivacyState {
    /// True while the app is locked (Touch ID / Face ID / password needed).
    var isLocked = false
    /// Conversion progress while turning encryption on or off.
    var converting: Double?
    /// The Recovery Key to show once, right after encryption is turned on.
    var recoveryKey: String?
    /// True when the library is encrypted but this device doesn't have the key yet.
    var needsKey = false

    @ObservationIgnored var backgroundSince: Date?
    @ObservationIgnored var conversion: Task<Void, Never>?
}

extension AppModel {
    // MARK: App lock

    /// Locks at launch when the lock is on.
    func lockAtLaunch() {
        if settings.lockEnabled { privacy.isLocked = true }
    }

    func appDidEnterBackground() {
        privacy.backgroundSince = Date()
    }

    func appDidBecomeActive() {
        defer { privacy.backgroundSince = nil }
        guard settings.lockEnabled, let since = privacy.backgroundSince else { return }
        if Date().timeIntervalSince(since) >= Double(settings.lockAfterMinutes * 60) { privacy.isLocked = true }
    }

    /// Asks for Touch ID / Face ID, falling back to the device password.
    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode or biometrics on this device: the lock can't protect anything, so don't trap the user.
            privacy.isLocked = false
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your meetings")) == true {
            privacy.isLocked = false
        }
    }

    /// Turning the lock on checks that authentication works first, so you can't lock yourself out.
    func setLock(_ enabled: Bool) async {
        guard enabled else {
            settings.lockEnabled = false
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "Set up Touch ID, Face ID or a password for this device first."
            return
        }
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on the app lock")) == true {
            settings.lockEnabled = true
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Password"
        }
    }

    // MARK: Encryption

    /// Loads the key for an encrypted library at launch (and when another device turns encryption on or off).
    func activateEncryption() {
        guard settings.libraryEncrypted else {
            LibraryKeyStore.activate(LibraryKeyStore.load(), encrypted: false)
            privacy.needsKey = false
            return
        }
        let key = LibraryKeyStore.load()
        let matches = key.map { settings.libraryKeyID == nil || LibraryCrypto.keyID($0) == settings.libraryKeyID } ?? false
        LibraryKeyStore.activate(matches ? key : nil, encrypted: true)
        privacy.needsKey = !matches
        if !matches {
            post("Your library is encrypted. Enter your Recovery Key in Settings to open it on this device (or wait for iCloud Keychain to sync the key).",
                 action: .settings)
        }
    }

    /// Creates a key, saves it to iCloud Keychain, converts every meeting, and shows the Recovery Key.
    func enableEncryption() {
        guard !settings.libraryEncrypted, privacy.converting == nil else { return }
        let key = LibraryKeyStore.load() ?? LibraryCrypto.newKey()
        LibraryKeyStore.save(key)
        settings.libraryKeyID = LibraryCrypto.keyID(key)
        settings.libraryEncrypted = true
        LibraryKeyStore.activate(key, encrypted: true)
        privacy.recoveryKey = LibraryCrypto.recoveryKey(key)
        convertLibrary(encrypt: true, key: key)
    }

    /// Decrypts every meeting back to plain files. The key stays in the Keychain in case another device is behind.
    func disableEncryption() {
        guard settings.libraryEncrypted, let key = LibraryCrypto.key, privacy.converting == nil else { return }
        LibraryKeyStore.activate(key, encrypted: false)
        settings.libraryEncrypted = false
        convertLibrary(encrypt: false, key: key)
    }

    /// Opens an encrypted library on a device without the key. Returns false if the key is wrong.
    func enterRecoveryKey(_ text: String) -> Bool {
        guard let key = LibraryCrypto.key(fromRecoveryKey: text),
              settings.libraryKeyID == nil || LibraryCrypto.keyID(key) == settings.libraryKeyID else { return false }
        LibraryKeyStore.save(key)
        activateEncryption()
        reload()
        return true
    }

    func showRecoveryKey() {
        if let key = LibraryCrypto.key { privacy.recoveryKey = LibraryCrypto.recoveryKey(key) }
    }

    private func convertLibrary(encrypt: Bool, key: SymmetricKey) {
        let converter = LibraryConverter(store: store)
        privacy.converting = 0
        privacy.conversion = Task {
            do {
                try await Task.detached(priority: .utility) {
                    try await converter.convert(encrypt: encrypt, key: key) { fraction in
                        Task { @MainActor [weak self] in self?.privacy.converting = fraction }
                    }
                }.value
            } catch {
                errorMessage = "Couldn't finish \(encrypt ? "encrypting" : "decrypting") the library: \(error.localizedDescription). It continues next time you open Hushpad."
            }
            privacy.converting = nil
            reload()
        }
    }

    /// Seals plain files left by recording, merging, importing or the Watch, and finishes an interrupted conversion.
    func sealNewFiles(_ id: UUID? = nil) {
        guard settings.libraryEncrypted, LibraryCrypto.key != nil, privacy.converting == nil else { return }
        let converter = LibraryConverter(store: store)
        let ids = id.map { [$0] } ?? recordings.filter { $0.id != session?.recording.id }.map(\.id)
        Task.detached(priority: .utility) { [weak self] in
            var failed = 0
            for id in ids {
                do { try converter.seal(id) } catch { failed += 1 }
            }
            guard failed > 0 else { return }
            await MainActor.run {
                self?.errorMessage = "Couldn't encrypt \(failed) meeting\(failed == 1 ? "" : "s"). Hushpad tries again next launch."
            }
        }
    }

    // MARK: On-device protection

    /// iPhone: a finished meeting's files become unreadable while the phone is locked.
    func protectFinished(_ id: UUID) {
        #if os(iOS)
        guard jobs[id] == nil, !notes.isRunning(id), session?.recording.id != id else { return }
        let store = self.store
        Task.detached(priority: .utility) { store.setStrongProtection(id, true) }
        #endif
    }

    /// Lets background work read a meeting's files again while the phone is locked.
    func unprotect(_ id: UUID) {
        #if os(iOS)
        store.setStrongProtection(id, false)
        #endif
    }

    /// Meetings whose audio is older than `days` and would be deleted by the retention setting.
    func audioExpired(after days: Int) -> [Recording] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return recordings.filter {
            $0.hasAudio && $0.createdAt < cutoff && jobs[$0.id] == nil && session?.recording.id != $0.id
        }
    }

    /// Deletes audio older than the retention setting (off by default). Transcripts and notes are kept.
    /// Turning the setting on asks first (see `PrivacySection`); after that it runs quietly at launch.
    func applyAudioRetention() {
        let expired = audioExpired(after: settings.audioRetentionDays)
        guard !expired.isEmpty else { return }
        let failed = expired.filter { (try? store.removeAudio($0)) == nil }.count
        if failed > 0 { post("Couldn't delete old audio from \(failed) meeting\(failed == 1 ? "" : "s"). Hushpad tries again next launch.") }
        reload()
    }
}
