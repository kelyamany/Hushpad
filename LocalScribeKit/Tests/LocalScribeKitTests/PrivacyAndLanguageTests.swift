import CryptoKit
import Foundation
import Testing
@testable import LocalScribeCore
@testable import LocalScribeKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
}

// MARK: Languages

@Suite struct LanguageTests {
    private func recording(_ language: String?, notes: String? = nil) throws -> Recording {
        var json = "{\"id\":\"\(UUID().uuidString)\""
        if let language { json += ",\"language\":\"\(language)\"" }
        if let notes { json += ",\"notesLanguage\":\"\(notes)\"" }
        json += "}"
        return try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
    }

    @Test func oldJSONDecodes() throws {
        #expect(try recording("de").language == .german)
        #expect(try recording("auto").language == .auto)
        #expect(try recording("ar").language == .arabic)
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(#"{"language":"de","engine":"x"}"#.utf8))
        #expect(transcript.language == .german)
    }

    @Test func missingNotesLanguageIsAuto() throws {
        let r = try recording("de")
        #expect(r.notesLanguage == .auto)
        #expect(try recording("de", notes: "es").notesLanguage.rawValue == "es")
    }

    @Test func unknownCodeRoundTrips() throws {
        var r = try recording("xx", notes: "yy")
        #expect(r.language.rawValue == "xx")
        r.audioRemovedAt = Date(timeIntervalSince1970: 1_000)
        let decoded = try JSONDecoder().decode(Recording.self, from: try JSONEncoder().encode(r))
        #expect(decoded.language.rawValue == "xx")
        #expect(decoded.notesLanguage.rawValue == "yy")
        #expect(decoded.audioRemovedAt == r.audioRemovedAt)
        let data = try JSONEncoder().encode([TranscriptLanguage(rawValue: "xx")])
        #expect(String(data: data, encoding: .utf8) == #"["xx"]"#)
    }

    @Test func lenientAudioRemovedAt() throws {
        let json = #"{"id":"\#(UUID().uuidString)","audioRemovedAt":"garbage","notesLanguage":5}"#
        let r = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        #expect(r.audioRemovedAt == nil)
        #expect(r.notesLanguage == .auto)
    }

    @Test func catalogue() {
        #expect(TranscriptLanguage.all.count >= 99)
        let all = Set(TranscriptLanguage.whisperCodes)
        #expect(TranscriptLanguage.common.allSatisfy { all.contains($0.rawValue) })
        #expect(TranscriptLanguage.auto.code == nil)
        #expect(TranscriptLanguage.german.code == "de")
    }

    @Test func rightToLeft() {
        for code in ["ar", "he", "fa", "ur"] { #expect(TranscriptLanguage(rawValue: code).isRightToLeft, "\(code)") }
        for code in ["en", "de", "auto"] { #expect(!TranscriptLanguage(rawValue: code).isRightToLeft, "\(code)") }
        #expect(TranscriptLanguage.isRightToLeft(code: "ar"))
        #expect(!TranscriptLanguage.isRightToLeft(code: nil))
    }

    @Test func englishNames() {
        #expect(TranscriptLanguage(rawValue: "de").englishName == "German")
        #expect(TranscriptLanguage(rawValue: "es").englishName == "Spanish")
    }

    @Test func folderPromptRoundTrips() throws {
        let folder = Folder(name: "Sales", notesPrompt: "Be brief")
        let decoded = try JSONDecoder().decode(Folder.self, from: try JSONEncoder().encode(folder))
        #expect(decoded.notesPrompt == "Be brief")
        let old = try JSONDecoder().decode(Folder.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        #expect(old.notesPrompt == nil)
    }
}

// MARK: Prompt

@Suite struct PromptTests {
    @Test func emptyInstructionsFallBack() {
        let prompt = NotesGenerator.systemPrompt(instructions: "  \n ", language: .auto)
        #expect(prompt.contains(NotesGenerator.defaultInstructions))
    }

    @Test func customInstructionsKeepFormatRules() {
        let prompt = NotesGenerator.systemPrompt(instructions: "Write like a pirate.", language: .auto)
        #expect(prompt.contains("Write like a pirate."))
        #expect(!prompt.contains(NotesGenerator.defaultInstructions))
        #expect(prompt.contains("GitHub-flavoured Markdown only"))
        #expect(prompt.contains("Do not add a top-level # title"))
    }

    @Test func languageRule() {
        let spanish = NotesGenerator.systemPrompt(instructions: "x", language: TranscriptLanguage(rawValue: "es"))
        #expect(spanish.contains("Write the notes in Spanish"))
        let auto = NotesGenerator.systemPrompt(instructions: "x", language: .auto)
        #expect(auto.contains("main language of the meeting"))
        #expect(!auto.contains("Write the notes in"))
    }

    @Test func interviewTemplateHasNoQuotes() throws {
        let interview = try #require(NoteTemplate.builtIn.first { $0.id == "interview" })
        #expect(!interview.instructions.lowercased().contains("quotes"))
    }

    @Test func messagesPassInstructionsThrough() {
        let input = NotesInput(recording: Recording(title: "Sync"), transcript: nil, myNotes: "")
        let template = NoteTemplate(id: "t", name: "T", instructions: "## Only")
        let messages = NotesGenerator.messages(template: template, input: input, transcript: "", condensed: false,
                                               instructions: "Custom rules here", language: TranscriptLanguage(rawValue: "fr"))
        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.contains("Custom rules here"))
        #expect(messages[0].content.contains("Write the notes in French"))
        #expect(messages[1].content.contains("## Only"))
    }
}

// MARK: Name masking

@Suite struct NameMaskerTests {
    @Test func masksFullAndFirstNames() {
        let masker = NameMasker(names: ["Anna Schmidt", "Bob Jones"])
        let masked = masker.mask("anna schmidt met BOB. Then Anna left; Jones stayed.")
        #expect(!masked.lowercased().contains("anna"))
        #expect(!masked.contains("BOB"))
        #expect(masked.contains("Person 1"))
        #expect(masked.contains("Person 2"))
        // Last names alone are not masked.
        #expect(masked.contains("Jones"))
    }

    @Test func wordBoundaries() {
        let masker = NameMasker(names: ["Anna"])
        #expect(masker.mask("Annabelle met Anna.") == "Annabelle met Person 1.")
    }

    @Test func ambiguousFirstNamesStay() {
        let masker = NameMasker(names: ["Anna Schmidt", "Anna Meyer"])
        let masked = masker.mask("Anna spoke. Anna Meyer agreed.")
        #expect(masked.hasPrefix("Anna spoke."))
        #expect(!masked.contains("Meyer"))
    }

    @Test func genericLabelsKept() {
        let masker = NameMasker(names: ["Speaker 2", "Remote 1", "Me", "Anna"])
        #expect(masker.names.count == 1)
        #expect(masker.mask("Speaker 2, Remote 1 and Me talked to Anna") == "Speaker 2, Remote 1 and Me talked to Person 1")
        #expect(NameMasker(names: ["Speaker 2", "Me"]).isEmpty)
    }

    @Test func unmaskRestores() {
        let masker = NameMasker(names: ["Anna Schmidt", "Bob Jones"])
        let original = "Anna Schmidt and Bob Jones agreed."
        let masked = masker.mask(original)
        #expect(masked != original)
        #expect(masker.unmask(masked) == original)
        // First names come back as the full name they stand for.
        #expect(masker.unmask(masker.mask("Anna agreed")) == "Anna Schmidt agreed")
    }

    @Test func person1VersusPerson12() {
        let names = (1...12).map { "Name\($0)x" }
        let masker = NameMasker(names: names)
        #expect(masker.names["Person 12"] == "Name12x")
        #expect(masker.unmask("Person 12 and Person 1 and Person 2") == "Name12x and Name1x and Name2x")
        #expect(masker.unmask(masker.mask("Name12x, Name1x")) == "Name12x, Name1x")
    }

    @Test func generatorMasksEverything() {
        var recording = Recording(title: "Call with Anna Schmidt", attendees: ["Anna Schmidt", "Bob"])
        recording.language = .english
        let transcript = Transcript(language: .english,
                                    speakers: [Speaker(key: "S1", name: "Anna Schmidt"), Speaker(key: "S2", name: "Speaker 2")],
                                    utterances: [Utterance(speaker: "S1", start: 0, end: 1, text: "Hi, I'm Anna, this is Bob.")],
                                    engine: "e")
        let input = NotesInput(recording: recording, transcript: transcript, myNotes: "Ask Bob about Anna Schmidt")
        let masker = NameMasker(names: NotesGenerator.participants(input))
        let out = NotesGenerator.masked(input, with: masker)
        let blob = [out.recording.title, out.recording.attendees.joined(), out.myNotes,
                    out.transcript!.speakers.map(\.name).joined(), out.transcript!.utterances.map(\.text).joined()].joined(separator: "|")
        #expect(!blob.contains("Anna"))
        #expect(!blob.contains("Bob"))
        #expect(out.transcript!.speakers[1].name == "Speaker 2")
        #expect(out.recording.title.contains("Person"))
        // Original untouched; empty masker is a no-op.
        #expect(input.recording.title == "Call with Anna Schmidt")
        #expect(NotesGenerator.masked(input, with: NameMasker(names: [])).myNotes == input.myNotes)
    }
}

// MARK: LLM client

@Suite struct LLMClientPrivacyTests {
    private let url = URL(string: "https://example.com/v1")!

    private func json(_ client: LLMClient) throws -> [String: Any] {
        let data = try JSONEncoder().encode(client.body([.user("hi")], temperature: 0.2))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func bodyRoutingOnlyWhenPrivate() throws {
        let on = try json(LLMClient(baseURL: url, model: "m", privateRouting: true))
        let routing = try #require(on["provider"] as? [String: Any])
        #expect(routing["data_collection"] as? String == "deny")
        #expect(routing["zdr"] as? Bool == true)
        let off = try json(LLMClient(baseURL: url, model: "m", privateRouting: false))
        #expect(off["provider"] == nil)
        #expect(off["stream"] as? Bool == true)
    }

    @Test func makeOpenCodeGo() {
        let client = LLMClient.make(.openCodeGo, baseURL: url, apiKey: "k", model: "m", privateRouting: true)
        #expect(client.privateRouting == false)
        #expect(client.apiKey == "k")
        let session = client.headers["x-opencode-session"]
        #expect(session != nil && !session!.isEmpty)
    }

    @Test func makeOpenRouterAndLocal() {
        let router = LLMClient.make(.openRouter, baseURL: url, apiKey: "k", model: "m", privateRouting: true)
        #expect(router.privateRouting)
        #expect(router.headers.isEmpty)
        #expect(!LLMClient.make(.openRouter, baseURL: url, apiKey: "k", model: "m", privateRouting: false).privateRouting)
        let local = LLMClient.make(.lmStudio, baseURL: url, apiKey: "secret", model: "m", privateRouting: true)
        #expect(local.apiKey == nil)
        #expect(!local.privateRouting)
    }

    @Test func providerDefaults() {
        #expect(NotesProvider.openRouter.defaultModel == "openrouter/free")
        #expect(NotesProvider.openCodeGo.isCloud)
        #expect(NotesProvider.openCodeGo.keychainAccount != nil)
        #expect(!NotesProvider.lmStudio.isCloud)
    }

    @Test func chatCompletionsFilter() {
        #expect(!LLMClient.speaksChatCompletions("gpt-5"))
        #expect(!LLMClient.speaksChatCompletions("grok-4"))
        #expect(!LLMClient.speaksChatCompletions("claude-sonnet"))
        #expect(LLMClient.speaksChatCompletions("deepseek-v4-flash"))
        #expect(LLMClient.speaksChatCompletions("qwen3"))
    }

    @Test func explainHints() {
        let privacy = LLMClient.explain("No endpoints found matching your data policy (Zero data retention)")
        #expect(privacy.contains("privacy guard"))
        #expect(privacy.hasPrefix("No endpoints found"))
        let credits = LLMClient.explain("This model requires at least $0.50 in balance")
        #expect(credits.contains("needs credit"))
        #expect(LLMClient.explain("something odd") == "something odd")
    }
}

// MARK: Shared settings

@Suite struct SharedSettingsPrivacyTests {
    @Test func roundTrip() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SharedSettings(notesProvider: .openCodeGo, notesLanguage: TranscriptLanguage(rawValue: "es"),
                                      notesPrompt: "Short", cloudPrivateRouting: true, cloudMaskNames: true,
                                      libraryEncrypted: true, libraryKeyID: "abc123")
        try settings.save(to: root)
        let loaded = try #require(SharedSettings.load(from: root))
        #expect(loaded == settings)
        #expect(loaded.notesLanguage?.rawValue == "es")
    }

    @Test func lenientWrongTypes() throws {
        let json = #"{"notesLanguage":5,"notesPrompt":["x"],"cloudPrivateRouting":"yes","cloudMaskNames":1,"libraryEncrypted":"no","libraryKeyID":3,"notesProvider":"bogus","autoTranscribe":true}"#
        let s = try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
        #expect(s.notesLanguage == nil)
        #expect(s.notesPrompt == nil)
        #expect(s.cloudPrivateRouting == nil)
        #expect(s.cloudMaskNames == nil)
        #expect(s.libraryEncrypted == nil)
        #expect(s.libraryKeyID == nil)
        #expect(s.notesProvider == nil)
        #expect(s.autoTranscribe == true)
    }
}

// MARK: Removing audio

@Suite struct RemoveAudioTests {
    @Test func removesAudioKeepsText() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let recording = Recording(title: "Audio", hasMic: true, hasSystemAudio: true)
        try store.save(recording)
        try store.save(Transcript(language: .english, speakers: [], utterances: [Utterance(speaker: "me", start: 0, end: 1, text: "hello")], engine: "whisperkit:a"), for: recording.id)
        try store.saveNotes("my notes", for: recording.id, .mine)
        try Data([1, 2, 3]).write(to: store.micURL(for: recording.id))
        try Data([4, 5, 6]).write(to: store.systemURL(for: recording.id))

        let when = Date(timeIntervalSince1970: 5_000)
        let updated = try store.removeAudio(recording, at: when)

        #expect(!FileManager.default.fileExists(atPath: store.micURL(for: recording.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.systemURL(for: recording.id).path))
        #expect(!updated.hasMic && !updated.hasSystemAudio && !updated.hasAudio)
        #expect(updated.audioRemovedAt == when)
        let reloaded = try #require(store.loadAll().first { $0.id == recording.id })
        #expect(!reloaded.hasMic && !reloaded.hasSystemAudio)
        #expect(reloaded.audioRemovedAt == when)
        #expect(store.transcripts(for: recording.id).first?.utterances.first?.text == "hello")
        #expect(store.notes(for: recording.id, .mine) == "my notes")
    }
}

// MARK: Encryption (touches global state: keep serialized and always reset)

extension CryptoGlobalState {
@Suite struct LibraryCryptoTests {
    private func reset() {
        LibraryCrypto.key = nil
        LibraryCrypto.encryptNewFiles = false
    }

    private func chunkRanges(_ sealed: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 8
        while offset < sealed.count {
            let length = sealed[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            ranges.append(offset..<(offset + 4 + length))
            offset += 4 + length
        }
        return ranges
    }

    @Test func roundTripSizes() throws {
        let key = LibraryCrypto.newKey()
        for size in [0, 5, LibraryCrypto.chunkSize, LibraryCrypto.chunkSize * 5 / 2] {
            let plain = pattern(size)
            let sealed = try LibraryCrypto.seal(plain, with: key)
            #expect(LibraryCrypto.isSealed(sealed))
            #expect(sealed.prefix(4) == Data("LSE1".utf8))
            #expect(try LibraryCrypto.open(sealed, with: key) == plain, "size \(size)")
        }
        // Chunk counts: empty and exactly one chunk are one chunk; 2.5 MiB is three.
        #expect(chunkRanges(try LibraryCrypto.seal(Data(), with: key)).count == 1)
        #expect(chunkRanges(try LibraryCrypto.seal(pattern(LibraryCrypto.chunkSize), with: key)).count == 1)
        #expect(chunkRanges(try LibraryCrypto.seal(pattern(LibraryCrypto.chunkSize * 5 / 2), with: key)).count == 3)
        // Plain data passes through.
        #expect(try LibraryCrypto.open(Data("hello".utf8), with: key) == Data("hello".utf8))
    }

    @Test func tamperAndWrongKey() throws {
        let key = LibraryCrypto.newKey()
        let sealed = try LibraryCrypto.seal(pattern(3000), with: key)
        var tampered = sealed
        tampered[tampered.count / 2] ^= 0x01
        #expect(throws: (any Error).self) { try LibraryCrypto.open(tampered, with: key) }
        do {
            _ = try LibraryCrypto.open(sealed, with: LibraryCrypto.newKey())
            Issue.record("expected wrongKey")
        } catch let error as LocalScribeError {
            guard case .wrongKey = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func truncation() throws {
        let key = LibraryCrypto.newKey()
        let sealed = try LibraryCrypto.seal(pattern(LibraryCrypto.chunkSize * 5 / 2), with: key)
        // Cut mid-chunk.
        #expect(throws: (any Error).self) { try LibraryCrypto.open(sealed.dropLast(100), with: key) }
        // Drop the whole last chunk: the new last chunk was sealed as "not last", so it must not verify.
        let ranges = chunkRanges(sealed)
        let cut = Data(sealed[0..<ranges[ranges.count - 1].lowerBound])
        #expect(throws: (any Error).self) { try LibraryCrypto.open(cut, with: key) }
    }

    @Test func recoveryKey() throws {
        let key = LibraryCrypto.newKey()
        let text = LibraryCrypto.recoveryKey(key)
        #expect(text.contains("-"))
        let parsed = try #require(LibraryCrypto.key(fromRecoveryKey: text))
        #expect(LibraryCrypto.keyID(parsed) == LibraryCrypto.keyID(key))
        #expect(parsed.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        let messy = text.lowercased().replacingOccurrences(of: "-", with: "  ")
        #expect(LibraryCrypto.key(fromRecoveryKey: messy) != nil)
        #expect(LibraryCrypto.keyID(try #require(LibraryCrypto.key(fromRecoveryKey: messy))) == LibraryCrypto.keyID(key))
        #expect(LibraryCrypto.key(fromRecoveryKey: "nonsense!") == nil)
        #expect(LibraryCrypto.key(fromRecoveryKey: "AAAA-BBBB") == nil)
        // O/I/L read as 0/1/1.
        let swapped = text.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "I")
        #expect(LibraryCrypto.keyID(try #require(LibraryCrypto.key(fromRecoveryKey: swapped))) == LibraryCrypto.keyID(key))
    }

    @Test func keyIDStableAndDistinct() {
        let a = LibraryCrypto.newKey(), b = LibraryCrypto.newKey()
        #expect(LibraryCrypto.keyID(a) == LibraryCrypto.keyID(a))
        #expect(LibraryCrypto.keyID(a) != LibraryCrypto.keyID(b))
        #expect(LibraryCrypto.keyID(a).count == 12)
    }

    @Test func streamingConvertRestoresBytes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = LibraryCrypto.newKey()
        let file = dir.appendingPathComponent("big.wav")
        let plain = pattern(3 * 1024 * 1024)
        try plain.write(to: file)

        #expect(try LibraryCrypto.convert(file: file, encrypt: true, key: key))
        #expect(LibraryCrypto.isSealed(file: file))
        #expect(try Data(contentsOf: file) != plain)
        #expect(try LibraryCrypto.open(Data(contentsOf: file), with: key) == plain)
        #expect(try LibraryCrypto.convert(file: file, encrypt: true, key: key) == false)

        #expect(try LibraryCrypto.convert(file: file, encrypt: false, key: key))
        #expect(try Data(contentsOf: file) == plain)
        #expect(try LibraryCrypto.convert(file: file, encrypt: false, key: key) == false)

        // Empty files and missing files.
        let empty = dir.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        #expect(try LibraryCrypto.convert(file: empty, encrypt: true, key: key))
        #expect(try LibraryCrypto.open(Data(contentsOf: empty), with: key).isEmpty)
        #expect(try LibraryCrypto.convert(file: dir.appendingPathComponent("nope"), encrypt: true, key: key) == false)
        // Wrong key on decrypt.
        #expect(throws: (any Error).self) { try LibraryCrypto.convert(file: empty, encrypt: false, key: LibraryCrypto.newKey()) }
    }

    @Test func readableCache() throws {
        defer { reset(); LibraryCrypto.clearCache() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = LibraryCrypto.newKey()
        let plainFile = dir.appendingPathComponent("plain.wav")
        let sealedFile = dir.appendingPathComponent("sealed.wav")
        let plain = pattern(1_500_000)
        try plain.write(to: plainFile)
        try plain.write(to: sealedFile)
        try LibraryCrypto.convert(file: sealedFile, encrypt: true, key: key)

        LibraryCrypto.key = key
        #expect(LibraryCrypto.readable(plainFile) == plainFile)
        let copy = LibraryCrypto.readable(sealedFile)
        #expect(copy != sealedFile)
        #expect(try Data(contentsOf: copy) == plain)
        #expect(LibraryCrypto.readable(sealedFile) == copy)
        #expect(LibraryCrypto.readable(dir.appendingPathComponent("missing")) == dir.appendingPathComponent("missing"))

        LibraryCrypto.key = nil
        #expect(LibraryCrypto.readable(sealedFile) == sealedFile)
    }

    @Test func fileCoordinationSeals() throws {
        defer { reset() }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = LibraryCrypto.newKey()
        let sealedURL = dir.appendingPathComponent("a.json")
        let plainURL = dir.appendingPathComponent("settings.json")
        let text = Data(#"{"hello":"world"}"#.utf8)

        LibraryCrypto.key = key
        LibraryCrypto.encryptNewFiles = true
        try FileCoordination.write(text, to: sealedURL)
        try FileCoordination.write(text, to: plainURL, sealed: false)
        let settingsRoot = dir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: settingsRoot, withIntermediateDirectories: true)
        try SharedSettings(libraryEncrypted: true, libraryKeyID: "k").save(to: settingsRoot)
        LibraryCrypto.encryptNewFiles = false

        #expect(try Data(contentsOf: sealedURL).prefix(4) == Data("LSE1".utf8))
        #expect(try FileCoordination.read(sealedURL) == text)
        #expect(try Data(contentsOf: plainURL) == text)
        #expect(!LibraryCrypto.isSealed(file: SharedSettings.url(in: settingsRoot)))
        #expect(SharedSettings.load(from: settingsRoot)?.libraryKeyID == "k")

        // Without the key, sealed data is locked.
        LibraryCrypto.key = nil
        do {
            _ = try FileCoordination.read(sealedURL)
            Issue.record("expected libraryLocked")
        } catch let error as LocalScribeError {
            guard case .libraryLocked = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(try FileCoordination.read(plainURL) == text)
    }

    @Test func libraryConverter() async throws {
        defer { reset() }
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let key = LibraryCrypto.newKey()

        var files: [URL] = []
        var ids: [UUID] = []
        for name in ["One", "Two"] {
            let recording = Recording(title: name, hasMic: true)
            try store.save(recording)
            ids.append(recording.id)
            try store.saveNotes("notes \(name)", for: recording.id, .mine)
            try Data("wav-\(name)".utf8).write(to: store.micURL(for: recording.id))
            let screens = store.folder(for: recording.id).appendingPathComponent("screens")
            try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
            try Data("jpg-\(name)".utf8).write(to: screens.appendingPathComponent("1000.jpg"))
            files += [store.folder(for: recording.id).appendingPathComponent("recording.json"), store.micURL(for: recording.id),
                      store.notesURL(for: recording.id, .mine), screens.appendingPathComponent("1000.jpg")]
        }
        try store.saveFolders([Folder(name: "F", notesPrompt: "p")])
        files.append(store.foldersURL)
        let before = try files.map { try Data(contentsOf: $0) }

        let converter = LibraryConverter(store: store)
        try await converter.convert(encrypt: true, key: key)
        for file in files { #expect(LibraryCrypto.isSealed(file: file), "\(file.lastPathComponent)") }

        LibraryCrypto.key = key
        #expect(Set(store.loadAll().map(\.id)) == Set(ids))
        #expect(store.folders().first?.notesPrompt == "p")
        #expect(store.notes(for: ids[0], .mine) == "notes One")

        // Resumable: running again changes nothing and doesn't fail.
        let sealedOnce = try files.map { try Data(contentsOf: $0) }
        try await converter.convert(encrypt: true, key: key)
        #expect(try files.map { try Data(contentsOf: $0) } == sealedOnce)

        try await converter.convert(encrypt: false, key: key)
        for (file, original) in zip(files, before) { #expect(try Data(contentsOf: file) == original, "\(file.lastPathComponent)") }
        #expect(Set(store.loadAll().map(\.id)) == Set(ids))
    }

    @Test func prepareForWriting() throws {
        defer { reset() }
        let data = Data("x".utf8)
        #expect(try LibraryCrypto.prepareForWriting(data) == data)
        LibraryCrypto.key = LibraryCrypto.newKey()
        #expect(try LibraryCrypto.prepareForWriting(data) == data)  // encryptNewFiles still false
    }
}
}
