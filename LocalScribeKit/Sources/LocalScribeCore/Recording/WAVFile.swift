import Foundation

/// Minimal 16-bit PCM mono WAV writer. The header is rewritten every few seconds,
/// so a crash or force-quit mid-meeting still leaves a playable file.
public final class WAVFile {
    let sampleRate: Int
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private var lastHeaderUpdate = Date()

    public init(url: URL, sampleRate: Int) throws {
        self.sampleRate = sampleRate
        #if !os(macOS)
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        FileManager.default.createFile(atPath: url.path, contents: nil)
        #endif
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    public func append(_ samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
        dataBytes &+= UInt32(samples.count * 2)
        if Date().timeIntervalSince(lastHeaderUpdate) > 5 { try updateHeader() }
    }

    public func close() throws {
        try updateHeader()
        try handle.close()
    }

    private func updateHeader() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
        try handle.seekToEnd()
        lastHeaderUpdate = Date()
    }

    static func header(sampleRate: Int, dataBytes: UInt32) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1)                                  // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)                                 // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return data
    }

    /// In-memory WAV, used to send audio chunks to OpenRouter.
    public static func encode(_ samples: [Int16], sampleRate: Int) -> Data {
        var data = header(sampleRate: sampleRate, dataBytes: UInt32(samples.count * 2))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
