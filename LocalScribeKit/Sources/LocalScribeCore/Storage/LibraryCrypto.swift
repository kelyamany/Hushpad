import CryptoKit
import Synchronization
import Foundation

/// Optional encryption of the library: every meeting file (and `folders.json`) is sealed with ChaCha20-Poly1305
/// under one library key, which lives in iCloud Keychain and is backed up as a Recovery Key the user keeps.
///
/// File names stay the same, so syncing, listing and deleting don't change. Encrypted files start with `LSE1`;
/// anything without that header is read as plain text, so a library can be converted file by file and a
/// half-converted library keeps working.
///
/// Reading is transparent: `FileCoordination.read` opens sealed data, and audio and screenshots are decrypted
/// into a private cache (`readable(_:)`) for players and image views that need a file.
///
///     "LSE1" | UInt32 chunk size | chunks…
///     chunk = UInt32 length | nonce (12) | ciphertext | tag (16)     AAD = chunk index (UInt64) + last flag (UInt8)
public enum LibraryCrypto {
    public static let magic = Data("LSE1".utf8)
    static let chunkSize = 1 << 20

    private static let state = Mutex(State())
    private struct State: Sendable {
        var key: SymmetricKey?
        var encryptNewFiles = false
    }

    /// The library key, when this device has it.
    public static var key: SymmetricKey? {
        get { state.withLock { $0.key } }
        set { state.withLock { $0.key = newValue } }
    }

    /// True when the library is encrypted: new and changed files are sealed.
    public static var encryptNewFiles: Bool {
        get { state.withLock { $0.encryptNewFiles && $0.key != nil } }
        set { state.withLock { $0.encryptNewFiles = newValue } }
    }

    // MARK: Data

    public static func isSealed(_ data: Data) -> Bool { data.count >= 8 && data.prefix(4) == magic }

    public static func isSealed(file url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == magic
    }

    public static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        var output = magic
        output.append(uint32(UInt32(chunkSize)))
        var index: UInt64 = 0
        var offset = data.startIndex
        repeat {
            let end = min(offset + chunkSize, data.endIndex)
            let last = end == data.endIndex
            let box = try ChaChaPoly.seal(data[offset..<end], using: key, authenticating: aad(index, last: last))
            output.append(uint32(UInt32(box.combined.count)))
            output.append(box.combined)
            offset = end
            index += 1
        } while offset < data.endIndex
        return output
    }

    public static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        guard isSealed(data) else { return data }
        var output = Data()
        var offset = data.startIndex + 8
        var index: UInt64 = 0
        while offset < data.endIndex {
            guard offset + 4 <= data.endIndex else { throw LocalScribeError.damagedFile }
            let length = Int(readUInt32(data, at: offset))
            offset += 4
            guard length >= 28, offset + length <= data.endIndex else { throw LocalScribeError.damagedFile }
            let last = offset + length == data.endIndex
            let box = try ChaChaPoly.SealedBox(combined: data[offset..<(offset + length)])
            do {
                output.append(try ChaChaPoly.open(box, using: key, authenticating: aad(index, last: last)))
            } catch {
                throw LocalScribeError.wrongKey
            }
            offset += length
            index += 1
        }
        return output
    }

    /// Opens sealed data with this device's key (plain data passes through).
    public static func open(_ data: Data) throws -> Data {
        guard isSealed(data) else { return data }
        guard let key else { throw LocalScribeError.libraryLocked }
        return try open(data, with: key)
    }

    /// Seals data for writing when the library is encrypted.
    public static func prepareForWriting(_ data: Data) throws -> Data {
        guard encryptNewFiles, let key, !isSealed(data) else { return data }
        return try seal(data, with: key)
    }

    // MARK: Files

    /// Encrypts or decrypts one file in place (atomically, through file coordination). Returns true if it changed.
    /// Large files are processed a chunk at a time, so audio never has to fit in memory.
    @discardableResult
    public static func convert(file url: URL, encrypt: Bool, key: SymmetricKey) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), isSealed(file: url) != encrypt else { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).converting")
        try? FileManager.default.removeItem(at: temporary)
        if encrypt {
            try streamSeal(url, to: temporary, key: key)
        } else {
            try streamOpen(url, to: temporary, key: key)
        }
        try copyProtection(from: url, to: temporary)
        try FileCoordination.move(temporary, to: url, replacing: true)
        return true
    }

    /// Converts every file of one meeting folder (audio, screenshots, notes, transcripts, recording.json).
    public static func convert(folder: URL, encrypt: Bool, key: SymmetricKey) throws {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try Task.checkCancellation()
            try convert(file: file, encrypt: encrypt, key: key)
        }
    }

    // MARK: Readable copies

    /// A plain copy of a sealed file for APIs that need a file (players, image views, share sheets), kept in a
    /// private cache and reused while the original is unchanged. Plain files (and missing ones) are returned as is.
    public static func readable(_ url: URL) -> URL {
        guard isSealed(file: url), let key else { return url }
        let cached = cacheURL(for: url)
        let fm = FileManager.default
        if let source = modified(url), let copy = modified(cached), copy >= source { return cached }
        do {
            try fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = cached.appendingPathExtension("partial")
            try? fm.removeItem(at: temporary)
            try streamOpen(url, to: temporary, key: key)
            #if !os(macOS)
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
            #endif
            try? fm.removeItem(at: cached)
            try fm.moveItem(at: temporary, to: cached)
            return cached
        } catch {
            return url
        }
    }

    /// The private folder holding plain copies. Emptied at launch, when the app goes to the background on iPhone,
    /// and when encryption is turned off.
    public static var cacheFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribe-open", isDirectory: true)
    }

    public static func clearCache() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }

    private static func cacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.deletingLastPathComponent().standardizedFileURL.path.utf8))
        let folder = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: Keys

    /// A new random library key.
    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// A short fingerprint of the key, stored in the library so a typed Recovery Key can be checked.
    public static func keyID(_ key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) } + Data("LocalScribe key id".utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The key as a Recovery Key: Crockford base32 in groups of four (`7KQ2-…`), easy to write down.
    public static func recoveryKey(_ key: SymmetricKey) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let bytes = key.withUnsafeBytes { Array($0) }
        var bits = 0, value = 0
        var characters: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                characters.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { characters.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// Parses a Recovery Key (case, dashes and spaces don't matter; O/I/L are read as 0/1/1).
    public static func key(fromRecoveryKey text: String) -> SymmetricKey? {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let cleaned = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
            .map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 }
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = ((value << 5) | index) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        guard bytes.count == 32 else { return nil }
        return SymmetricKey(data: bytes)
    }

    // MARK: Helpers

    private static func streamSeal(_ source: URL, to destination: URL, key: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: magic + uint32(UInt32(chunkSize)))
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        var index: UInt64 = 0
        var done = 0
        repeat {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            done += chunk.count
            let box = try ChaChaPoly.seal(chunk, using: key, authenticating: aad(index, last: done >= size))
            try output.write(contentsOf: uint32(UInt32(box.combined.count)) + box.combined)
            index += 1
        } while done < size
    }

    private static func streamOpen(_ source: URL, to destination: URL, key: SymmetricKey) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        guard try input.read(upToCount: 8)?.prefix(4) == magic else { throw LocalScribeError.damagedFile }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var offset = 8
        var index: UInt64 = 0
        while offset < size {
            guard let header = try input.read(upToCount: 4), header.count == 4 else { throw LocalScribeError.damagedFile }
            let length = Int(readUInt32(header, at: header.startIndex))
            guard length >= 28, let body = try input.read(upToCount: length), body.count == length else { throw LocalScribeError.damagedFile }
            offset += 4 + length
            do {
                let box = try ChaChaPoly.SealedBox(combined: body)
                try output.write(contentsOf: try ChaChaPoly.open(box, using: key, authenticating: aad(index, last: offset >= size)))
            } catch {
                throw LocalScribeError.wrongKey
            }
            index += 1
        }
    }

    private static func copyProtection(from source: URL, to destination: URL) throws {
        #if !os(macOS)
        if let protection = try? FileManager.default.attributesOfItem(atPath: source.path)[.protectionKey] {
            try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: destination.path)
        }
        #endif
    }

    private static func aad(_ index: UInt64, last: Bool) -> Data {
        var data = withUnsafeBytes(of: index.bigEndian) { Data($0) }
        data.append(last ? 1 : 0)
        return data
    }

    private static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    private static func readUInt32(_ data: Data, at offset: Data.Index) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
