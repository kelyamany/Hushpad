import CryptoKit
import Foundation

/// Keeps the library encryption key in iCloud Keychain (so every device signed in to the same Apple Account can
/// open the library) and loads it into `LibraryCrypto`.
public enum LibraryKeyStore {
    static let account = "library-key"

    /// The key from the Keychain, if this device has it.
    public static func load() -> SymmetricKey? {
        guard let text = KeychainStore.read(account), let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public static func save(_ key: SymmetricKey) {
        KeychainStore.write(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: account)
    }

    public static func remove() {
        KeychainStore.write(nil, for: account)
    }

    /// Makes the key available to file reads and writes, and says whether new files should be sealed.
    public static func activate(_ key: SymmetricKey?, encrypted: Bool) {
        LibraryCrypto.key = key
        LibraryCrypto.encryptNewFiles = encrypted
    }
}

/// Converts a whole library to or from encryption. Each file is converted atomically and already-converted files
/// are skipped, so an interrupted conversion simply continues next time.
public struct LibraryConverter: Sendable {
    public let store: RecordingStore

    public init(store: RecordingStore) { self.store = store }

    public func convert(encrypt: Bool, key: SymmetricKey, progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let recordings = store.loadAll()
        for (index, recording) in recordings.enumerated() {
            try Task.checkCancellation()
            try LibraryCrypto.convert(folder: store.folder(for: recording.id), encrypt: encrypt, key: key)
            progress(Double(index + 1) / Double(max(recordings.count, 1)))
            await Task.yield()
        }
        try LibraryCrypto.convert(file: store.root.appendingPathComponent("folders.json"), encrypt: encrypt, key: key)
        if !encrypt { LibraryCrypto.clearCache() }
    }

    /// Seals any plain files in one meeting (after recording, merging, importing or receiving from the Watch).
    public func seal(_ id: UUID) throws {
        guard LibraryCrypto.encryptNewFiles, let key = LibraryCrypto.key, let folder = store.existingFolder(id) else { return }
        try LibraryCrypto.convert(folder: folder, encrypt: true, key: key)
    }
}
