import Foundation
import LocalScribeKit
import Observation

/// User preferences. Device-specific ones live in UserDefaults; the ones that should follow you between devices
/// (language, cloud, notes setup and templates) are also written to `settings.json` in the library folder, so they
/// sync like meetings do. The OpenRouter key lives in the Keychain, synced through iCloud Keychain.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }
    var customModels: [WhisperModel] { didSet { defaults.set(try? JSONEncoder().encode(customModels), forKey: "customModels") } }
    var language: TranscriptLanguage { didSet { defaults.set(language.rawValue, forKey: "language"); sharedChanged() } }
    var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe"); sharedChanged() } }
    var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    var screenshotMode: ScreenshotMode { didSet { defaults.set(screenshotMode.rawValue, forKey: "screenshotMode") } }
    var cloudEnabled: Bool { didSet { defaults.set(cloudEnabled, forKey: "cloudEnabled"); sharedChanged() } }
    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }

    // Meetings (per device)
    /// Offer "Take notes" when a call app starts using the microphone (Mac).
    var detectMeetings: Bool { didSet { defaults.set(detectMeetings, forKey: "detectMeetings") } }
    /// Offer to stop when the call app releases the microphone (Mac).
    var stopWhenCallEnds: Bool { didSet { defaults.set(stopWhenCallEnds, forKey: "stopWhenCallEnds") } }
    /// Call apps that never trigger "Meeting detected", by name.
    var ignoredMeetingApps: [String] { didSet { defaults.set(ignoredMeetingApps, forKey: "ignoredMeetingApps") } }
    /// Show captions while recording, transcribed on this device.
    var liveTranscript: Bool { didSet { defaults.set(liveTranscript, forKey: "liveTranscript") } }

    // Meeting notes (Mac)
    var notesProvider: NotesProvider { didSet { defaults.set(notesProvider.rawValue, forKey: "notesProvider"); sharedChanged() } }
    var notesBaseURL: String { didSet { defaults.set(notesBaseURL, forKey: "notesBaseURL"); sharedChanged() } }
    var notesModel: String { didSet { defaults.set(notesModel, forKey: "notesModel"); sharedChanged() } }
    var notesTemplateID: String { didSet { defaults.set(notesTemplateID, forKey: "notesTemplateID"); sharedChanged() } }
    /// Your own recipes (questions you ask often); shown after the built-in ones.
    var recipes: [Recipe] { didSet { defaults.set(try? JSONEncoder().encode(recipes), forKey: "recipes") } }
    var allRecipes: [Recipe] { Recipe.builtIn + recipes }
    var templates: [NoteTemplate] { didSet { defaults.set(try? JSONEncoder().encode(templates), forKey: "templates"); sharedChanged() } }
    var notesIncludeTranscript: Bool { didSet { defaults.set(notesIncludeTranscript, forKey: "notesIncludeTranscript"); sharedChanged() } }
    /// Default language for new meetings' notes (`.auto` follows the meeting).
    var notesLanguage: TranscriptLanguage { didSet { defaults.set(notesLanguage.rawValue, forKey: "notesLanguage"); sharedChanged() } }
    /// App-wide notes instructions; nil uses `NotesGenerator.defaultInstructions`. Folders can override it.
    var notesPrompt: String? { didSet { defaults.set(notesPrompt, forKey: "notesPrompt"); sharedChanged() } }

    // Cloud privacy guard
    var cloudPrivateRouting: Bool { didSet { defaults.set(cloudPrivateRouting, forKey: "cloudPrivateRouting"); sharedChanged() } }
    var cloudMaskNames: Bool { didSet { defaults.set(cloudMaskNames, forKey: "cloudMaskNames"); sharedChanged() } }

    // On-device privacy (per device)
    /// Ask for Touch ID / Face ID (or the device password) to open the app.
    var lockEnabled: Bool { didSet { defaults.set(lockEnabled, forKey: "lockEnabled") } }
    /// Minutes in the background before the app locks again (0 = immediately).
    var lockAfterMinutes: Int { didSet { defaults.set(lockAfterMinutes, forKey: "lockAfterMinutes") } }
    /// Delete meeting audio older than this many days (0 = keep forever). Transcripts and notes stay.
    var audioRetentionDays: Int { didSet { defaults.set(audioRetentionDays, forKey: "audioRetentionDays") } }

    // Library encryption (synced through settings.json, which stays readable without the key)
    var libraryEncrypted: Bool { didSet { defaults.set(libraryEncrypted, forKey: "libraryEncrypted"); sharedChanged() } }
    var libraryKeyID: String? { didSet { defaults.set(libraryKeyID, forKey: "libraryKeyID"); sharedChanged() } }
    /// Called when another device turned encryption on or off.
    @ObservationIgnored var onEncryptionChange: (() -> Void)?

    /// The OpenRouter key (notes only).
    var apiKey: String {
        get { key(for: .openRouter) }
        set { setKey(newValue, for: .openRouter) }
    }

    /// Keys are read from the Keychain once, then kept in memory: views check `cloudReady` while rendering.
    func key(for provider: NotesProvider) -> String {
        access(keyPath: \.keyCache)
        guard let account = provider.keychainAccount else { return "" }
        if let cached = keyCache[account] { return cached }
        let key = KeychainStore.read(account) ?? ""
        keyCache[account] = key
        keyScopes[account] = KeychainStore.lastScope
        return key
    }

    func setKey(_ value: String, for provider: NotesProvider) {
        guard let account = provider.keychainAccount else { return }
        withMutation(keyPath: \.keyCache) {
            KeychainStore.write(value, for: account)
            keyCache[account] = value
            keyScopes[account] = KeychainStore.lastScope
        }
    }

    /// Whether a provider's key is in iCloud Keychain (true) or only on this device.
    func keyIsSynced(_ provider: NotesProvider) -> Bool {
        _ = key(for: provider)
        return provider.keychainAccount.flatMap { keyScopes[$0] } == .synced
    }

    @ObservationIgnored private var keyCache: [String: String] = [:]
    @ObservationIgnored private var keyScopes: [String: KeychainStore.Scope] = [:]

    init() {
        modelID = defaults.string(forKey: "modelID") ?? ModelCatalog.platformDefault.id
        customModels = (defaults.data(forKey: "customModels")).flatMap { try? JSONDecoder().decode([WhisperModel].self, from: $0) } ?? []
        language = defaults.string(forKey: "language").map(TranscriptLanguage.init(rawValue:)) ?? .auto
        // Off by default: the full transcription is heavy, so it runs when you ask (live captions cover you until then).
        autoTranscribe = defaults.object(forKey: "autoTranscribe") as? Bool ?? false
        captureSystemAudio = defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
        detectMeetings = defaults.object(forKey: "detectMeetings") as? Bool ?? true
        stopWhenCallEnds = defaults.object(forKey: "stopWhenCallEnds") as? Bool ?? true
        ignoredMeetingApps = defaults.stringArray(forKey: "ignoredMeetingApps") ?? []
        liveTranscript = defaults.object(forKey: "liveTranscript") as? Bool ?? true
        #if os(macOS)
        let defaultScreenshots = ScreenshotMode.automatic
        #else
        let defaultScreenshots = ScreenshotMode.manual
        #endif
        screenshotMode = defaults.string(forKey: "screenshotMode").flatMap(ScreenshotMode.init(rawValue:)) ?? defaultScreenshots
        cloudEnabled = defaults.bool(forKey: "cloudEnabled")
        onboarded = defaults.bool(forKey: "onboarded")
        let provider = defaults.string(forKey: "notesProvider").flatMap(NotesProvider.init(rawValue:)) ?? .lmStudio
        notesProvider = provider
        notesBaseURL = defaults.string(forKey: "notesBaseURL") ?? provider.defaultBaseURL
        notesModel = defaults.string(forKey: "notesModel") ?? ""
        notesTemplateID = defaults.string(forKey: "notesTemplateID") ?? NoteTemplate.builtIn[0].id
        recipes = defaults.data(forKey: "recipes").flatMap { try? JSONDecoder().decode([Recipe].self, from: $0) } ?? []
        templates = defaults.data(forKey: "templates").flatMap { try? JSONDecoder().decode([NoteTemplate].self, from: $0) }
            ?? NoteTemplate.builtIn
        notesIncludeTranscript = defaults.object(forKey: "notesIncludeTranscript") as? Bool ?? false
        notesLanguage = defaults.string(forKey: "notesLanguage").map(TranscriptLanguage.init(rawValue:)) ?? .auto
        notesPrompt = defaults.string(forKey: "notesPrompt")
        cloudPrivateRouting = defaults.object(forKey: "cloudPrivateRouting") as? Bool ?? true
        cloudMaskNames = defaults.object(forKey: "cloudMaskNames") as? Bool ?? true
        lockEnabled = defaults.bool(forKey: "lockEnabled")
        lockAfterMinutes = defaults.object(forKey: "lockAfterMinutes") as? Int ?? 5
        audioRetentionDays = defaults.integer(forKey: "audioRetentionDays")
        libraryEncrypted = defaults.bool(forKey: "libraryEncrypted")
        libraryKeyID = defaults.string(forKey: "libraryKeyID")
    }

    // MARK: Syncing through the library folder

    @ObservationIgnored private var libraryRoot: URL?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var lastStamp: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Uses the settings file in `root`: adopts it if it exists, otherwise creates it from this device's settings.
    func attach(to root: URL) {
        libraryRoot = root
        lastStamp = nil
        if SharedSettings.load(from: root) != nil {
            syncFromLibrary()
        } else {
            writeShared()
        }
    }

    /// Picks up changes made on another device. Only reads the file when its date changed.
    func syncFromLibrary() {
        guard let root = libraryRoot, let stamp = SharedSettings.stamp(in: root), stamp != lastStamp else { return }
        lastStamp = stamp
        guard let shared = SharedSettings.load(from: root) else { return }
        apply(shared)
    }

    var shared: SharedSettings {
        SharedSettings(language: language, autoTranscribe: autoTranscribe, cloudEnabled: cloudEnabled,
                       notesProvider: notesProvider, notesBaseURL: notesBaseURL, notesModel: notesModel,
                       notesTemplateID: notesTemplateID, templates: templates, notesIncludeTranscript: notesIncludeTranscript,
                       notesLanguage: notesLanguage, notesPrompt: notesPrompt, cloudPrivateRouting: cloudPrivateRouting,
                       cloudMaskNames: cloudMaskNames, libraryEncrypted: libraryEncrypted, libraryKeyID: libraryKeyID)
    }

    private func apply(_ shared: SharedSettings) {
        applying = true
        defer { applying = false }
        if let value = shared.language, value != language { language = value }
        if let value = shared.autoTranscribe, value != autoTranscribe { autoTranscribe = value }
        if let value = shared.cloudEnabled, value != cloudEnabled { cloudEnabled = value }
        if let value = shared.notesProvider, value != notesProvider { notesProvider = value }
        if let value = shared.notesBaseURL, value != notesBaseURL { notesBaseURL = value }
        if let value = shared.notesModel, value != notesModel { notesModel = value }
        if let value = shared.templates, !value.isEmpty, value != templates { templates = value }
        if let value = shared.notesTemplateID, value != notesTemplateID { notesTemplateID = value }
        if let value = shared.notesIncludeTranscript, value != notesIncludeTranscript { notesIncludeTranscript = value }
        if let value = shared.notesLanguage, value != notesLanguage { notesLanguage = value }
        if shared.notesPrompt != notesPrompt { notesPrompt = shared.notesPrompt }
        if let value = shared.cloudPrivateRouting, value != cloudPrivateRouting { cloudPrivateRouting = value }
        if let value = shared.cloudMaskNames, value != cloudMaskNames { cloudMaskNames = value }
        let encrypted = shared.libraryEncrypted ?? false
        if encrypted != libraryEncrypted || shared.libraryKeyID != libraryKeyID {
            libraryEncrypted = encrypted
            libraryKeyID = shared.libraryKeyID
            onEncryptionChange?()
        }
    }

    /// A synced setting changed here: write the file shortly after (typing a model name shouldn't write per key).
    private func sharedChanged() {
        guard !applying, libraryRoot != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.writeShared()
        }
    }

    private func writeShared() {
        guard let root = libraryRoot else { return }
        try? shared.save(to: root)
        lastStamp = SharedSettings.stamp(in: root)
    }

    /// Where the OpenRouter key is kept, for Settings.
    var apiKeyIsSynced: Bool { keyIsSynced(.openRouter) }

    var template: NoteTemplate { templates.first { $0.id == notesTemplateID } ?? templates.first ?? NoteTemplate.builtIn[0] }

    /// Why notes can't be written on this device right now, or nil when they can. One source for the error
    /// message and for the empty state that explains what to do.
    var notesUnavailableReason: String? {
        #if os(iOS)
        // A local model (LM Studio, Ollama) runs on the Mac; this phone can't reach it.
        if !notesProvider.isCloud {
            return "\(notesProvider.displayName) runs on your Mac. Choose a cloud notes model in Settings to write notes on this iPhone."
        }
        #endif
        if notesModel.isEmpty { return "Choose a notes model in Settings first." }
        if notesProvider.isCloud {
            if !cloudEnabled { return "Turn on cloud features in Settings to write notes with \(notesProvider.displayName)." }
            if key(for: notesProvider).isEmpty { return "Add your \(notesProvider.displayName) key in Settings to write notes with it." }
        }
        return nil
    }

    /// Notes from a cloud provider need the explicit cloud opt-in and that provider's key; on iPhone only cloud works.
    var notesProviderAllowed: Bool {
        #if os(iOS)
        guard notesProvider.isCloud else { return false }
        #endif
        return !notesProvider.isCloud || (cloudEnabled && !key(for: notesProvider).isEmpty)
    }

    func notesClient() -> LLMClient? {
        guard notesUnavailableReason == nil, let url = URL(string: notesBaseURL) else { return nil }
        return LLMClient.make(notesProvider, baseURL: url, apiKey: key(for: notesProvider), model: notesModel,
                              privateRouting: cloudPrivateRouting)
    }

    /// Switches the notes provider, resetting the server address and picking the provider's starting model.
    func chooseNotesProvider(_ provider: NotesProvider) {
        notesProvider = provider
        notesBaseURL = provider.defaultBaseURL
        notesModel = provider.defaultModel
    }

    /// The instructions for a meeting's notes: its folder's, else the app's, else the built-in ones.
    func notesInstructions(folder: Folder?) -> (text: String, source: String) {
        if let custom = folder?.notesPrompt, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let folder {
            return (custom, "Instructions from \(folder.name)")
        }
        if let custom = notesPrompt, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (custom, "Your instructions")
        }
        return (NotesGenerator.defaultInstructions, "Default instructions")
    }

    var allModels: [WhisperModel] { ModelCatalog.builtIn + customModels }

    var model: WhisperModel { ModelCatalog.model(withID: modelID, custom: customModels) ?? ModelCatalog.platformDefault }

    var cloudReady: Bool { cloudEnabled && !apiKey.isEmpty }
}
