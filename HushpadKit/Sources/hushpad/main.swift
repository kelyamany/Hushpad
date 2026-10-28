import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import HushpadKit

/// Command-line front end for the same pipeline the app uses. Handy for comparing models on real recordings.
@main
struct HushpadCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hushpad",
        abstract: "Local meeting transcription with speaker labels.",
        subcommands: [Transcribe.self, Live.self, Record.self, ImportGranola.self, Notes.self, Merge.self, Models.self, DemoLibrary.self],
        defaultSubcommand: Transcribe.self
    )
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List built-in Whisper models.")
    func run() throws {
        for model in ModelCatalog.builtIn {
            let engine = try WhisperKitEngine(model: model)
            let mark = engine.isDownloaded ? "✓" : " "
            print("\(mark) \(model.variant.padding(toLength: 50, withPad: " ", startingAt: 0)) \(model.displayName)")
        }
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe a recording and label speakers.")

    @Option(help: "Room / microphone audio file.") var mic: String?
    @Option(help: "Call / system audio file.") var system: String?
    @Option(help: "auto, or an ISO code such as en, de, es, ar, ja.") var language: String = "auto"
    @Option(help: "Whisper model variant (see `hushpad models`).") var model: String = ModelCatalog.platformDefault.variant
    @Option(help: "Hugging Face repo for custom models.") var repo: String = ModelCatalog.argmaxRepo
    @Option(help: "Number of speakers in the room, if known.") var roomSpeakers: Int?
    @Option(help: "Number of remote speakers, if known.") var remoteSpeakers: Int?
    @Option(help: "txt, md or srt.") var format: String = "txt"
    @Flag(help: "Print raw words and speaker turns for debugging.") var debug = false

    func validate() throws {
        guard mic != nil || system != nil else { throw ValidationError("Pass --mic and/or --system.") }
        guard language == "auto" || TranscriptLanguage.whisperCodes.contains(language) else { throw ValidationError("Unknown language \(language)") }
        guard ExportFormat(rawValue: format) != nil else { throw ValidationError("Unknown format \(format)") }
    }

    func run() async throws {
        let whisper = WhisperModel(variant: model, repo: repo, displayName: model)
        let engine = try WhisperKitEngine(model: whisper)
        let diarizer = try SpeakerKitDiarizer()

        let loadStart = Date()
        try await engine.prepare { fraction in
            FileHandle.standardError.write("\rDownloading \(model): \(Int(fraction * 100))%".data(using: .utf8)!)
        }
        try await diarizer.prepare()
        let loadTime = Date().timeIntervalSince(loadStart)

        if debug, let url = mic.map(URL.init(fileURLWithPath:)) ?? system.map(URL.init(fileURLWithPath:)) {
            let output = try await engine.transcribe(audioURL: url, language: TranscriptLanguage(rawValue: language))
            for word in output.words {
                print(String(format: "%7.2f %7.2f p=%.2f %@", word.start, word.end, word.probability ?? -1, word.text))
            }
            for turn in try await diarizer.diarize(audioURL: url, expectedSpeakers: nil) {
                print(String(format: "turn %@ %.2f-%.2f", turn.speaker, turn.start, turn.end))
            }
            return
        }

        let tracks = AudioTracks(mic: mic.map(URL.init(fileURLWithPath:)), system: system.map(URL.init(fileURLWithPath:)))
        let options = PipelineOptions(language: TranscriptLanguage(rawValue: language),
                                      roomSpeakers: roomSpeakers, remoteSpeakers: remoteSpeakers)
        let start = Date()
        let transcript = try await TranscriptPipeline(engine: engine, diarizer: diarizer).run(tracks: tracks, options: options) { stage in
            FileHandle.standardError.write("\n\(stage)".data(using: .utf8)!)
        }
        let elapsed = Date().timeIntervalSince(start)

        print(Exporter.render(transcript, title: "Transcript", as: ExportFormat(rawValue: format)!))
        let audioSeconds = [tracks.mic, tracks.system].compactMap { $0 }.map(AudioInfo.duration(of:)).max() ?? 0
        FileHandle.standardError.write(String(
            format: "\n\nmodel=%@ load=%.1fs audio=%.1fs processing=%.1fs speed=%.1fx realtime speakers=%d detected=%@\n",
            model, loadTime, audioSeconds, elapsed, audioSeconds / max(elapsed, 0.001),
            transcript.speakers.count, transcript.detectedLanguage ?? "-").data(using: .utf8)!)
    }
}

/// Records mic (+ system audio on macOS) for a fixed time into a folder, for testing capture.
struct Live: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Caption an audio file with the live (on-device) recogniser, as if it were being recorded.")

    @Argument(help: "Audio file (any format AVFoundation reads).") var file: String
    @Option(help: "Language code, e.g. en or de (default: this Mac's language).") var language: String?
    @Option(help: "Playback speed; 1 is real time.") var speed: Double = 4

    @MainActor
    func run() async throws {
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: file))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let live = LiveTranscriber(language: TranscriptLanguage(code: language) ?? .auto, sources: [.microphone])
        let sink = live.sink(for: .microphone)
        live.start()
        // Wait for the recogniser (it may download Apple's speech model the first time).
        while live.transcript.status == .preparing || live.transcript.status == .downloading {
            try await Task.sleep(for: .milliseconds(100))
        }
        if case .unavailable(let reason) = live.transcript.status { throw ValidationError(reason) }

        let converter = AVAudioConverter(from: audio.processingFormat, to: format)!
        let chunk = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        let started = Date()
        var position = 0.0
        while audio.framePosition < audio.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk) else { break }
            try audio.read(into: input, frameCount: min(chunk, AVAudioFrameCount(audio.length - audio.framePosition)))
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_700)!
            nonisolated(unsafe) var supplied = false
            _ = converter.convert(to: output, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            sink(output, position)
            position += Double(output.frameLength) / 16_000
            try await Task.sleep(for: .seconds(0.1 / speed))
        }
        await live.stop()
        let elapsed = Date().timeIntervalSince(started)
        for line in live.transcript.lines {
            print("[\(Exporter.clock(line.start))] \(line.text)")
        }
        print(String(format: "%.1f s of audio in %.1f s (speed %.0fx), %d lines", position, elapsed, speed, live.transcript.finals.count))
    }
}

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record the mic and system audio for a few seconds.")

    @Option(help: "Output folder.") var output: String
    @Option(help: "Seconds to record.") var seconds: Double = 10
    @Flag(help: "Skip system audio.") var noSystem = false

    @MainActor
    func run() async throws {
        await Permissions.request(.microphone)
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        let store = try RecordingStore(root: folder)
        let session = try RecordingSession(library: store, options: RecordingOptions(
            title: "CLI test", captureSystemAudio: !noSystem, screenshots: .off))
        try session.start()
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try await Task.sleep(for: .milliseconds(500))
            let system = session.systemLevel.map { String(format: " system=%.2f", $0) } ?? ""
            FileHandle.standardError.write(Data(String(format: "\rmic=%.2f%@   ", session.micLevel, system).utf8))
        }
        let recording = await session.stop()
        session.warnings.forEach { FileHandle.standardError.write(Data("\nwarning: \($0)".utf8)) }
        print("\n\(store.folder(for: recording.id).path) duration=\(recording.duration) system=\(recording.hasSystemAudio)")
    }
}

/// Imports a Granola export (.zip or .csv) into a library folder.
struct ImportGranola: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-granola", abstract: "Import a Granola export.")

    @Argument(help: "Granola export (.zip or .csv).") var file: String
    @Option(help: "Library folder.") var library: String

    func run() async throws {
        let meetings = try GranolaImporter.meetings(from: URL(fileURLWithPath: file))
        let store = try RecordingStore(root: URL(fileURLWithPath: library, isDirectory: true))
        let count = try GranolaImporter.importMeetings(meetings, into: store)
        print("Imported \(count) of \(meetings.count) meetings into \(store.root.path)")
        for meeting in meetings {
            print("- \(meeting.title) · \(meeting.transcript?.speakers.map(\.name).joined(separator: ", ") ?? "no transcript")")
        }
    }
}

/// Generates meeting notes for one recording in a library with an OpenAI-compatible server (LM Studio by default).
struct Notes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate meeting notes with a local LLM.")

    @Option(help: "Library folder.") var library: String
    @Option(help: "Pick the recording whose title contains this text.") var title: String
    @Option(help: "Server base URL.") var server = NotesProvider.lmStudio.defaultBaseURL
    @Option(help: "Model id on the server.") var model: String
    @Option(help: "Template id: general, one-on-one, interview, standup.") var template = "general"

    func run() async throws {
        let store = try RecordingStore(root: URL(fileURLWithPath: library, isDirectory: true))
        guard let recording = store.loadAll().first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
            throw ValidationError("No recording matching “\(title)”.")
        }
        let transcripts = store.transcripts(for: recording.id)
        let input = NotesInput(recording: recording,
                               transcript: transcripts.first { $0.engine == recording.activeEngine } ?? transcripts.last,
                               myNotes: store.notes(for: recording.id, .mine) ?? "")
        let generator = NotesGenerator(client: LLMClient(baseURL: URL(string: server)!, model: model),
                                       template: NoteTemplate.builtIn.first { $0.id == template } ?? NoteTemplate.builtIn[0])
        let started = Date()
        let document = try await generator.generate(input) { progress in
            if case .condensing(let part, let total) = progress {
                FileHandle.standardError.write(Data("condensing part \(part)/\(total)\n".utf8))
            }
        }
        FileHandle.standardError.write(Data(String(format: "generated in %.1fs\n", Date().timeIntervalSince(started)).utf8))
        print(document.document)
    }
}

/// Merges two recordings of a library into a new one (originals kept).
struct Merge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Merge two meetings, in order, into a new one.")

    @Option(help: "Library folder.") var library: String
    @Option(help: "Title (part) of the meeting that comes first.") var first: String
    @Option(help: "Title (part) of the meeting that comes second.") var second: String
    @Option(help: "Title for the merged meeting.") var title: String?

    func run() async throws {
        let store = try RecordingStore(root: URL(fileURLWithPath: library, isDirectory: true))
        let all = store.loadAll()
        func find(_ text: String) throws -> Recording {
            guard let match = all.first(where: { $0.title.localizedCaseInsensitiveContains(text) }) else {
                throw ValidationError("No meeting matching “\(text)”.")
            }
            return match
        }
        let merged = try RecordingMerger.merge(.init(first: try find(first), second: try find(second), title: title), in: store)
        print("Merged into “\(merged.title)” at \(store.folder(for: merged.id).path)")
    }
}
