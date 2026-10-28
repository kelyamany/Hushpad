import Foundation
import HushpadKit
import HushpadUI
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the meeting list shows: everything, Granola imports, or one folder.
enum LibrarySource: Hashable {
    case all, imported, folder(UUID)
}

/// One day in the meeting list.
struct MeetingSection: Identifiable, Equatable {
    var id: Date
    var title: String
    var recordings: [Recording]
}

@Observable
final class AppModel {
    let settings = AppSettings()
    let privacy = PrivacyState()
    let notes = NotesService()
    private(set) var recordings: [Recording] = []
    private(set) var summaries: [UUID: RecordingSummary] = [:]
    private(set) var session: RecordingSession?
    /// Transcription jobs and the speech models.
    private(set) var queue: TranscriptionQueue!
    /// Live permission state for every screen (re-checked when the app becomes active).
    let permissions = PermissionCenter()
    /// Meetings deleted in this session; queued jobs for them are skipped and their results discarded.
    @ObservationIgnored private var deleted: Set<UUID> = []
    /// Bumped per meeting whenever its files change (transcripts, screenshots, notes, sync), so only its open view reloads.
    private(set) var versions: [UUID: Int] = [:]
    func version(of id: UUID) -> Int { versions[id] ?? 0 }
    func touch(_ id: UUID) { versions[id, default: 0] += 1 }
    /// False until the first read of the library finishes, so the list shows progress instead of "no meetings".
    private(set) var hasLoaded = false
    /// This device doesn't have the key for an encrypted library, so its meetings can't be listed.
    private(set) var libraryLocked = false
    /// Errors that need an answer: shown as an alert.
    var errorMessage: String?
    /// Things worth knowing that don't block anything (a warning, a recovery): shown as a banner.
    var notice: Notice?
    struct Notice: Identifiable, Equatable {
        enum Action: Equatable { case permission(Permission), settings, undoScreenshotDelete }
        let id = UUID()
        var text: String
        var action: Action?
    }
    func post(_ text: String, action: Notice.Action? = nil) { notice = Notice(text: text, action: action) }
    /// The last screenshots deleted, kept in memory so "Undo" in the banner can put them back.
    @ObservationIgnored var removedScreenshots: (recordingID: UUID, shots: [ScreenshotStore.Removed])?
    var selection: UUID?
    /// Set to open Settings from anywhere (iPhone presents it as a sheet).
    var showSettings = false
    /// What you type while recording. Saved to notes/mine.md when the recording stops (and periodically).
    var liveNotes = "" { didSet { scheduleLiveNotesSave() } }

    /// The library: the app's private folder or a folder the user chose (e.g. ~/Documents/Hushpad in iCloud).
    private(set) var store: RecordingStore
    private(set) var libraryIsCustom: Bool
    private var notesSaveTask: Task<Void, Never>?
    #if os(iOS)
    private var watchLink: WatchLink?
    #endif

    init() {
        let location = LibraryLocation.resolve()
        let diarizer: SpeakerKitDiarizer
        var fellBack = false
        do {
            if location.isCustom, let custom = try? RecordingStore(root: location.url) {
                store = custom
                libraryIsCustom = true
            } else {
                // The chosen folder is unavailable (e.g. iCloud signed out): fall back to the private library.
                store = try RecordingStore()
                libraryIsCustom = false
                fellBack = location.isCustom
            }
            diarizer = try SpeakerKitDiarizer()
        } catch {
            fatalError("Cannot create the app's data folder: \(error)")
        }
        queue = makeQueue(diarizer: diarizer)
        // A crash or force-quit mid-meeting leaves audio in the staging area; finish and file it.
        let recovered = RecordingSession.recoverUnfinished(into: store)
        settings.attach(to: store.root)
        // Plain copies of encrypted files from the last run.
        LibraryCrypto.clearCache()
        activateEncryption()
        settings.onEncryptionChange = { [weak self] in
            self?.activateEncryption()
            self?.reload()
        }
        lockAtLaunch()
        reload()
        sealNewFiles()
        applyAudioRetention()
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["HUSHPAD_SELECT"].flatMap(UUID.init(uuidString:)) { selection = id }
        #endif
        if fellBack {
            post("Your library folder “\(location.url.lastPathComponent)” isn't available, so new meetings are saved on this device for now.",
                 action: .settings)
        }
        if !recovered.isEmpty {
            post(recovered.count == 1
                ? "Recovered “\(recovered[0].title)”, which was still recording when the app closed."
                : "Recovered \(recovered.count) recordings that were still recording when the app closed.")
        }
        chat.attach(self)
        #if os(iOS)
        setUpPhoneIntegrations()
        #else
        AppDelegate.attach(self)
        meetings.attach(self)
        #endif
    }

    /// Re-reads the library off the main thread and publishes the result. Calls while a read is running are
    /// folded into one more read afterwards.
    func reload() {
        guard !reloading else {
            reloadAgain = true
            return
        }
        reloading = true
        let store = self.store, previous = snapshot
        Task {
            #if DEBUG
            let started = Date()
            #endif
            let next = await Task.detached(priority: .userInitiated) { LibraryIndex.read(store, previous: previous) }.value
            reloading = false
            // The library moved (or something was saved) while we were reading: this result may be stale.
            if store.root == self.store.root { apply(next) } else { reloadAgain = true }
            #if DEBUG
            PerfProbe.log("reload \(next.recordings.count) meetings", since: started)
            #endif
            if reloadAgain {
                reloadAgain = false
                reload()
            }
        }
    }

    @ObservationIgnored private var snapshot = LibrarySnapshot()
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false

    private func apply(_ read: LibrarySnapshot) {
        var read = read
        read.recordings.removeAll { deleted.contains($0.id) }
        for recording in read.recordings where snapshot.stamps[recording.id] != read.stamps[recording.id] { touch(recording.id) }
        snapshot = read
        recordings = read.recordings
        folders = read.folders
        summaries = read.summaries
        libraryLocked = read.locked
        settings.syncFromLibrary()
        hasLoaded = true
        rebuildSections()
    }

    /// Re-reads one meeting (after a job saved something), without scanning the whole library.
    func refresh(_ id: UUID) {
        let store = self.store
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                store.recording(id: id).map { ($0, LibraryIndex.summarize($0, in: store), store.contentStamp(for: id)) }
            }.value
            guard let (recording, summary, stamp) = result, !deleted.contains(id), store.root == self.store.root else { return }
            if let index = recordings.firstIndex(where: { $0.id == id }) {
                recordings[index] = recording
            } else {
                recordings = (recordings + [recording]).sorted { $0.createdAt > $1.createdAt }
            }
            summaries[id] = summary
            snapshot.stamps[id] = stamp
            touch(id)
            rebuildSections()
        }
    }

    // MARK: - List (sources, search, day sections)

    private(set) var folders: [Folder] = []
    /// What the list shows. Changing it re-filters immediately.
    var source: LibrarySource = .all { didSet { if source != oldValue { rebuildSections() } } }
    /// The search field. Filtering is debounced so typing stays smooth in big libraries.
    var query = "" { didSet { scheduleSectionRebuild() } }
    /// The current list, grouped by day. Computed once per change, never inside a view's body.
    private(set) var sections: [MeetingSection] = []
    private(set) var folderCounts: [UUID: Int] = [:]
    var hasImported: Bool { recordings.contains { $0.source == .granola } }
    private var queryTask: Task<Void, Never>?

    var sourceTitle: String {
        switch source {
        case .all: "All Meetings"
        case .imported: "Imported"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    func folder(for recording: Recording) -> Folder? {
        recording.folderID.flatMap { id in folders.first { $0.id == id } }
    }

    private func scheduleSectionRebuild() {
        queryTask?.cancel()
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            rebuildSections()
        }
    }

    private func rebuildSections() {
        var counts: [UUID: Int] = [:]
        for recording in recordings { if let id = recording.folderID { counts[id, default: 0] += 1 } }
        folderCounts = counts
        if case .folder(let id) = source, !folders.contains(where: { $0.id == id }) { source = .all }
        if source == .imported && !hasImported { source = .all }

        let terms = query.lowercased().split(separator: " ").map(String.init)
        let visible = recordings.filter { recording in
            switch source {
            case .all: break
            case .imported: guard recording.source == .granola else { return false }
            case .folder(let id): guard recording.folderID == id else { return false }
            }
            guard !terms.isEmpty else { return true }
            let title = recording.title.lowercased()
            let attendees = recording.attendees.map { $0.lowercased() }
            let spoken = summaries[recording.id]?.searchText ?? ""
            return terms.allSatisfy { term in
                title.contains(term) || attendees.contains { $0.contains(term) } || spoken.contains(term)
            }
        }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.createdAt) }
        let next = grouped.keys.sorted(by: >).map { day in
            MeetingSection(id: day, title: Self.dayTitle(day, calendar: calendar),
                           recordings: grouped[day]!.sorted { $0.createdAt > $1.createdAt })
        }
        if next != sections { sections = next }
    }

    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: Date())).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
        }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    /// The one status a row shows, only when something needs attention (DESIGN.md › Show it when it matters).
    func status(for recording: Recording) -> StatusPill.Kind? {
        if session?.recording.id == recording.id { return .recording }
        switch jobs[recording.id] {
        case .queued?: return .queued
        case .failed?: return .failed("Transcription failed")
        case .downloading(let fraction)?: return .downloading(fraction)
        case .paused(let fraction)?: return .paused(fraction)
        case let job? where job.isActive: return .transcribing(job.fraction)
        default: break
        }
        switch notesJobs[recording.id] {
        case .failed?: return .failed("Notes failed")
        case let job? where job.isRunning: return .writingNotes
        default: return nil
        }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String, symbol: String = "folder", colorIndex: Int? = nil) -> Folder {
        let folder = Folder(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            symbol: symbol, colorIndex: colorIndex ?? folders.count)
        saveFolders(folders + [folder])
        return folder
    }

    func updateFolder(_ folder: Folder) {
        saveFolders(folders.map { $0.id == folder.id ? folder : $0 })
    }

    /// Deletes the folder only; its meetings go back to "All Meetings".
    func deleteFolder(_ folder: Folder) {
        for recording in recordings where recording.folderID == folder.id {
            do {
                patch(try store.move(recording.id, to: nil))
            } catch {
                // Keep the folder rather than leave meetings pointing at one that no longer exists.
                errorMessage = "Couldn't take “\(recording.title)” out of the folder, so the folder was kept: \(error.localizedDescription)"
                return
            }
        }
        if source == .folder(folder.id) { source = .all }
        saveFolders(folders.filter { $0.id != folder.id })
    }

    func moveFolder(from offsets: IndexSet, to destination: Int) {
        var reordered = folders
        reordered.move(fromOffsets: offsets, toOffset: destination)
        saveFolders(reordered)
    }

    private func saveFolders(_ updated: [Folder]) {
        do {
            try store.saveFolders(updated)
            folders = updated
            rebuildSections()
        } catch {
            errorMessage = "Couldn't save folders: \(error.localizedDescription)"
        }
    }

    /// A meeting being recorded lives outside the library until it stops, so it can't be filed yet.
    func canMove(_ recording: Recording) -> Bool { session?.recording.id != recording.id }

    func move(_ ids: [UUID], to folder: Folder?) {
        for id in ids {
            guard let recording = recordings.first(where: { $0.id == id }), canMove(recording) else { continue }
            do { patch(try store.move(id, to: folder?.id)) } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Replaces one recording in memory after it was saved, without re-reading the library.
    private func patch(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
        snapshot.stamps[recording.id] = store.contentStamp(for: recording.id)
        if reloading { reloadAgain = true }
        rebuildSections()
        touch(recording.id)
    }

    // MARK: - Recording

    var isRecording: Bool { session != nil }
    /// "Ask anything" about a meeting or all meetings.
    let chat = ChatService()
    #if os(macOS)
    /// "Meeting detected" and "call ended" for the nub.
    let meetings = MeetingWatcher()
    #endif
    var recordingStartedAt: Date? { session?.startDate }
    private(set) var isPaused = false

    func togglePause() {
        guard let session else { return }
        if isPaused { session.resume() } else { session.pause() }
        isPaused = session.isPaused
    }

    #if os(macOS)
    static let settingsName = "System Settings"
    #else
    static let settingsName = "Settings"
    #endif

    static func defaultTitle(at date: Date = Date()) -> String {
        "Meeting at " + date.formatted(date: .omitted, time: .shortened)
    }

    func startRecording(title: String? = nil) async {
        guard session == nil else { return }
        await permissions.refresh()
        if permissions.status(.microphone) != .granted {
            guard await permissions.request(.microphone) == .granted else {
                post("Hushpad needs the microphone to record. Allow it in \(Self.settingsName) › Privacy & Security › Microphone.",
                     action: .permission(.microphone))
                return
            }
        }
        #if os(macOS)
        var callAudioOff = false
        if settings.captureSystemAudio, permissions.status(.systemAudio) == .denied { callAudioOff = true }
        #endif
        let options = RecordingOptions(title: title ?? Self.defaultTitle(), language: settings.language, notesLanguage: settings.notesLanguage,
                                       captureSystemAudio: settings.captureSystemAudio, screenshots: settings.screenshotMode,
                                       liveTranscript: settings.liveTranscript)
        do {
            let session = try RecordingSession(library: store, options: options)
            try session.start()
            self.session = session
            queue.hold(true)
            liveNotes = ""
            var warnings = session.warnings
            #if os(macOS)
            if callAudioOff {
                warnings.append("Call audio is turned off, so only your microphone is recorded. Allow Hushpad in System Settings › Privacy & Security › Screen & System Audio Recording.")
            }
            #endif
            if !warnings.isEmpty {
                post(warnings.joined(separator: "\n"), action: callAudioOffAction(warnings))
            }
            watchForProblems(session)
            reload()
            selection = session.recording.id
            #if os(macOS)
            meetings.recordingStarted()
            #endif
            #if os(iOS)
            LiveActivityController.start(title: session.recording.title, startedAt: session.startDate)
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops and returns the finished recording (nil if nothing was recording).
    @discardableResult
    func stopRecording() async -> Recording? {
        guard let session else { return nil }
        notesSaveTask?.cancel()
        saveLiveNotes()
        self.session = nil
        isPaused = false
        queue.hold(false)
        #if os(macOS)
        meetings.recordingStopped()
        #endif
        let recording = await session.stop()
        #if os(iOS)
        await LiveActivityController.end()
        #endif
        problemWatch?.cancel()
        if !session.warnings.isEmpty { post(session.warnings.joined(separator: "\n")) }
        reload()
        sealNewFiles(recording.id)
        if settings.autoTranscribe {
            transcribe(recording)
        }
        return recording
    }

    @ObservationIgnored private var problemWatch: Task<Void, Never>?

    /// Checks every couple of seconds whether the recording is losing audio (disk full, call audio dropped) and says so.
    private func watchForProblems(_ session: RecordingSession) {
        problemWatch?.cancel()
        problemWatch = Task {
            var reported: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let problem = session.problem, problem != reported {
                    reported = problem
                    post(problem)
                }
            }
        }
    }

    private func callAudioOffAction(_ warnings: [String]) -> Notice.Action? {
        #if os(macOS)
        warnings.contains { $0.contains("Call audio") } ? .permission(.systemAudio)
            : warnings.contains { $0.hasPrefix("Screenshots are off") } ? .permission(.screenRecording) : nil
        #else
        nil
        #endif
    }

    func renameLiveRecording(_ title: String) {
        session?.rename(title)
        #if os(iOS)
        LiveActivityController.update(title: session?.recording.title)
        #endif
    }

    #if os(macOS)
    func captureScreenshot() async {
        guard let session else { return }
        if await session.captureScreenshot() != nil {
            touch(session.recording.id)
        } else if !CGPreflightScreenCaptureAccess() {
            post("Couldn't take a screenshot: Hushpad needs Screen & System Audio Recording.", action: .permission(.screenRecording))
        } else {
            post("Couldn't take a screenshot of the meeting.")
        }
    }
    #endif

    private(set) var livePhotoCount = 0

    func addPhoto(_ jpeg: Data) {
        guard let session else { return }
        do {
            try session.addPhoto(jpeg: jpeg)
            livePhotoCount = ScreenshotStore.list(in: session.folder).count
            touch(session.recording.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleLiveNotesSave() {
        guard session != nil else { return }
        notesSaveTask?.cancel()
        notesSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveLiveNotes()
        }
    }

    /// Notes are saved next to the in-progress audio and travel with it into the library.
    private func saveLiveNotes() {
        guard let session, !liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.saveNotes(liveNotes)
    }

    // MARK: - Transcription (the rest is in AppModel+Transcription.swift)

    private func makeQueue(diarizer: SpeakerKitDiarizer) -> TranscriptionQueue {
        TranscriptionQueue(diarizer: diarizer, hooks: .init(
            store: { [unowned self] in store },
            defaultModel: { [unowned self] in settings.model },
            isDeleted: { [unowned self] in deleted.contains($0) },
            willStart: { [unowned self] in unprotect($0) },
            didFinish: { [unowned self] recording in
                refresh(recording.id)
                sealNewFiles(recording.id)
                protectFinished(recording.id)
                #if os(iOS)
                Notifier.transcriptReady(for: recording)
                #endif
            },
            allowDownload: { [unowned self] model in
                #if os(iOS)
                await allowDownloadOnThisNetwork(megabytes: model.approxSizeMB)
                #else
                true
                #endif
            },
            downloadFailed: { [unowned self] in errorMessage = $0 }))
    }

    #if os(iOS)
    /// Set while a model download is waiting for you to allow it over cellular.
    var cellularPrompt: CellularPrompt?
    struct CellularPrompt: Identifiable {
        let id = UUID()
        let megabytes: Int?
    }
    @ObservationIgnored private var cellularAnswer: CheckedContinuation<Bool, Never>?

    /// On a metered connection, asks before a big download. Anywhere else, or on Wi-Fi, says yes straight away.
    func allowDownloadOnThisNetwork(megabytes: Int?) async -> Bool {
        guard NetworkGuard.shared.isExpensive else { return true }
        cellularAnswer?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            cellularAnswer = continuation
            cellularPrompt = CellularPrompt(megabytes: megabytes)
        }
    }

    func answerCellularPrompt(_ allow: Bool) {
        cellularPrompt = nil
        cellularAnswer?.resume(returning: allow)
        cellularAnswer = nil
    }
    #endif

    // MARK: - Requests from menus (handled in AppModel+Import.swift and the views)

    /// Set to show the merge sheet starting from this recording (from a menu anywhere in the app).
    var mergeRequest: Recording?
    /// Set to navigate to a recording (e.g. the result of a merge) on iPhone.
    var openRequest: UUID?
    /// Set to show the folder editor (new or edit) from any menu.
    var folderEditor: FolderEditorRequest?
    /// Set by File › Import from Granola… to show the file picker.
    var showGranolaImport = false

    // MARK: - Library location

    /// Points the library at a folder the user picked (nil = back to the private folder) and moves
    /// existing recordings there. Returns how many were moved.
    @discardableResult
    func setLibraryFolder(_ url: URL?, moveExisting: Bool) -> Int {
        do {
            try LibraryLocation.remember(url)
            let location = LibraryLocation.resolve()
            let destination = try RecordingStore(root: location.isCustom ? location.url : nil)
            let moved = moveExisting ? try LibraryLocation.migrate(from: store, to: destination) : 0
            store = destination
            libraryIsCustom = location.isCustom
            // A library that already has settings (from your other device) brings them along.
            settings.attach(to: destination.root)
            #if os(iOS)
            watchLink?.store = destination
            #endif
            reload()
            return moved
        } catch {
            // Don't leave the next launch pointing at a folder that didn't work.
            try? LibraryLocation.remember(libraryIsCustom ? store.root : nil)
            errorMessage = "Couldn't use that folder: \(error.localizedDescription)"
            return 0
        }
    }

    /// Where a deleted meeting ends up, for confirmation dialogs.
    var deleteMessage: String {
        #if os(macOS)
        "Its audio, transcript, notes and screenshots are deleted for good\(libraryIsCustom ? ", also from your other devices" : ""). This can't be undone."
        #else
        libraryIsCustom
            ? "Its audio, transcript, notes and photos are deleted for good, also from your other devices. This can't be undone."
            : "Its audio, transcript, notes and photos are deleted for good. This can't be undone."
        #endif
    }

    var libraryDisplayPath: String {
        guard libraryIsCustom else { return "On this device only" }
        return store.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Recordings (transcripts and notes are in AppModel+Transcripts.swift)

    /// The last speaker change, offered for undo for a few seconds.
    var speakerUndo: SpeakerUndo?

    func update(_ recording: Recording) {
        do {
            try store.save(recording)
            patch(recording)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes the meeting's whole folder for good (not via the Trash). Work still queued or running for it is dropped.
    func delete(_ recording: Recording) {
        guard session?.recording.id != recording.id else { return }
        let id = recording.id
        do {
            try store.delete(id)
        } catch {
            errorMessage = "Couldn't delete “\(recording.title)”: \(error.localizedDescription)"
            return
        }
        deleted.insert(id)
        notes.forget(id)
        queue.forget(id)
        ThumbnailCache.removeAll()
        if selection == recording.id { selection = nil }
        recordings.removeAll { $0.id == recording.id }
        summaries[recording.id] = nil
        snapshot.stamps[recording.id] = nil
        versions[recording.id] = nil
        rebuildSections()
    }

    // MARK: - Export

    /// Progress of the export in flight (0…1), nil when idle.
    private(set) var exportProgress: Double?

    #if os(iOS)
    struct ShareFile: Identifiable {
        let url: URL
        /// Settings is itself a sheet, so it presents its own share sheet.
        let fromSettings: Bool
        var id: URL { url }
    }

    /// A finished export waiting to be shared.
    var shareFile: ShareFile?
    #endif

    /// Exports meetings (nil = the whole library) as ordinary files: transcript, notes, audio, screenshots and data.
    /// Mac: asks for a folder and shows the result in Finder. iPhone: zips it and opens the share sheet.
    func export(_ selection: [Recording]?, fromSettings: Bool = false) {
        guard exportProgress == nil else { return }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = selection?.count == 1 ? "Choose where to save “\(selection![0].title)”." : "Choose where to save your meetings."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        #else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
        let exporter = MeetingExporter(store: store)
        let folders = self.folders
        let recordings = selection ?? self.recordings.filter { $0.id != session?.recording.id }
        exportProgress = 0
        Task {
            defer { exportProgress = nil }
            do {
                let result: URL
                if let selection, selection.count == 1 {
                    result = try await exporter.export(selection[0], into: directory)
                } else {
                    result = try await exporter.exportLibrary(recordings, folders: folders, into: directory) { fraction in
                        Task { @MainActor in self.exportProgress = fraction }
                    }
                }
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([result])
                #else
                let zip = try await Task.detached { try MeetingExporter.zip(result) }.value
                try? FileManager.default.removeItem(at: directory)
                shareFile = ShareFile(url: zip, fromSettings: fromSettings)
                #endif
            } catch {
                errorMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - iPhone integrations

    #if os(iOS)
    private func setUpPhoneIntegrations() {
        // Watch recordings arrive here and are transcribed like local ones.
        let link = WatchLink(store: store)
        link.onReceive = { [weak self] recording in
            guard let self else { return }
            reload()
            sealNewFiles(recording.id)
            if settings.autoTranscribe { transcribe(recording) }
        }
        link.activate()
        watchLink = link

        // Control Center / Lock Screen / Siri / Live Activity buttons.
        RecordingIntentBridge.start = { [weak self] in await self?.startRecording() }
        RecordingIntentBridge.stop = { [weak self] in await self?.stopRecording() }

        // A Live Activity left over from a crash would show a timer for a recording that no longer exists.
        if session == nil { Task { await LiveActivityController.end() } }
    }
    #endif
}
