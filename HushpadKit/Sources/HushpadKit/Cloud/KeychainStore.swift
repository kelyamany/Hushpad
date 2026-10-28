import Foundation
import Security

/// Stores secrets (the OpenRouter API key) in the Keychain. Items are synchronizable, so iCloud Keychain carries
/// them end-to-end encrypted to your other devices signed in to the same Apple Account (the Mac and iPhone apps
/// share a keychain access group because they share a bundle id and team). Keys saved under the app's old name
/// (`LegacyInstall`) are copied across the first time they're read.
///
/// A Mac build without a provisioning profile (ad-hoc signed) can't use the synced keychain; the key is then
/// kept on that Mac only, as before.
public enum KeychainStore {
    private static let service = DemoMode.library == nil ? "Hushpad" : "Hushpad Demo"

    public enum Scope: Sendable, Equatable {
        /// In iCloud Keychain.
        case synced
        /// On this device only.
        case local
    }

    /// Where the last successful write went (nil until something is written or read).
    public private(set) nonisolated(unsafe) static var lastScope: Scope?

    public static func read(_ account: String) -> String? {
        if let value = copy(account, synchronizable: true) {
            lastScope = .synced
            return value
        }
        if let value = copy(account, synchronizable: false) {
            lastScope = .local
            // Written by an older version (device only): move it into iCloud Keychain if that's possible here.
            if add(value, for: account, synchronizable: true) == errSecSuccess {
                delete(account, synchronizable: false)
                lastScope = .synced
            }
            return value
        }
        // Saved before the app was renamed: copy it across. The old item stays, for devices still on the old app.
        guard DemoMode.library == nil,
              let value = copy(account, synchronizable: true, service: LegacyInstall.keychainService)
                ?? copy(account, synchronizable: false, service: LegacyInstall.keychainService) else { return nil }
        write(value, for: account)
        return value
    }

    public static func write(_ value: String?, for account: String) {
        delete(account, synchronizable: true)
        delete(account, synchronizable: false)
        guard let value, !value.isEmpty else {
            // Also remove the copy from before the rename, or `read` would bring the key back.
            if DemoMode.library == nil {
                delete(account, synchronizable: true, service: LegacyInstall.keychainService)
                delete(account, synchronizable: false, service: LegacyInstall.keychainService)
            }
            return
        }
        if add(value, for: account, synchronizable: true) == errSecSuccess {
            lastScope = .synced
        } else if add(value, for: account, synchronizable: false) == errSecSuccess {
            lastScope = .local
        }
    }

    // MARK: Helpers

    private static func baseQuery(_ account: String, synchronizable: Bool, service: String = KeychainStore.service) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        #if os(macOS)
        // Synced items only exist in the data protection keychain (the iOS-style one) on the Mac.
        if synchronizable { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    private static func copy(_ account: String, synchronizable: Bool, service: String = KeychainStore.service) -> String? {
        var query = baseQuery(account, synchronizable: synchronizable, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func add(_ value: String, for account: String, synchronizable: Bool) -> OSStatus {
        var attributes = baseQuery(account, synchronizable: synchronizable)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func delete(_ account: String, synchronizable: Bool, service: String = KeychainStore.service) {
        SecItemDelete(baseQuery(account, synchronizable: synchronizable, service: service) as CFDictionary)
    }
}
