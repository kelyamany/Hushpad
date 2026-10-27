import LocalScribeKit
import LocalScribeUI
import Observation
import SwiftUI

/// Everything one open meeting shows: transcripts, screenshots, both kinds of notes and the player.
/// Mac and iPhone detail screens share it; it reads the files off the main thread, so opening a meeting never
/// stalls the UI, and creates the audio players only when you press play.
@Observable
final class MeetingDetailModel {
    private(set) var transcripts: [Transcript] = []
    private(set) var screenshots: [Screenshot] = []
    private(set) var display: TranscriptDisplay?
    private(set) var myNotes = ""
    private(set) var enhancedNotes: String?
    /// False until the first read finishes, so views can show progress instead of an empty state.
    private(set) var isLoaded = false
    var selectedEngine: String? { didSet { if oldValue != selectedEngine { rebuildDisplay() } } }
    let player = PlaybackController()

    @ObservationIgnored private var loadedID: UUID?

    var transcript: Transcript? { transcripts.first { $0.engine == selectedEngine } ?? transcripts.last }

    func load(_ recording: Recording, store: RecordingStore, isLive: Bool) async {
        let id = recording.id
        if loadedID != id { reset() }
        let read = await Task.detached(priority: .userInitiated) {
            Snapshot(transcripts: store.transcripts(for: id),
                     screenshots: ScreenshotStore.list(in: store.folder(for: id)),
                     mine: store.notes(for: id, .mine) ?? "",
                     enhanced: store.notes(for: id, .enhanced))
        }.value
        guard !Task.isCancelled else { return }
        transcripts = read.transcripts
        screenshots = read.screenshots
        myNotes = read.mine
        enhancedNotes = read.enhanced
        if selectedEngine == nil || !transcripts.contains(where: { $0.engine == selectedEngine }) {
            selectedEngine = recording.activeEngine ?? transcripts.last?.engine
        }
        await buildDisplay()
        if recording.hasAudio && !isLive { player.prepare(recording, store: store) }
        loadedID = id
        isLoaded = true
    }

    func setMyNotes(_ text: String) { myNotes = text }

    /// While recording, automatic screenshots arrive without the meeting changing otherwise: re-list them.
    func refreshScreenshots(in folder: URL) async {
        let found = await Task.detached(priority: .utility) { ScreenshotStore.list(in: folder) }.value
        if found != screenshots { screenshots = found }
    }
    /// Bumped when the notes change from outside the editor (e.g. an answer added from Ask), so it reloads.
    private(set) var notesGeneration = 0
    func replaceMyNotes(_ text: String) {
        myNotes = text
        notesGeneration += 1
    }
    func setEnhancedNotes(_ text: String) { enhancedNotes = text }

    private func reset() {
        player.stop()
        transcripts = []
        screenshots = []
        display = nil
        myNotes = ""
        enhancedNotes = nil
        selectedEngine = nil
        isLoaded = false
    }

    private func rebuildDisplay() {
        Task { await buildDisplay() }
    }

    private func buildDisplay() async {
        guard let transcript, !transcripts.isEmpty else {
            display = nil
            return
        }
        let screenshots = self.screenshots
        let built = await Task.detached(priority: .userInitiated) { TranscriptDisplay(transcript, screenshots: screenshots) }.value
        // A newer selection may have arrived while building.
        if self.transcript?.engine == transcript.engine { display = built }
    }

    private nonisolated struct Snapshot: Sendable {
        var transcripts: [Transcript]
        var screenshots: [Screenshot]
        var mine: String
        var enhanced: String?
    }
}

/// Reloads a meeting's files when it, its files or its live state change.
struct LoadKey: Hashable {
    var id: UUID
    var version: Int
    var live: Bool
}

// MARK: - Shared pieces

/// Which model's version of the transcript is shown, and the way to make another one, right where the transcript is.
struct VersionBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var detail: MeetingDetailModel
    let recording: Recording
    let transcript: Transcript
    let isLive: Bool
    let transcribeAgain: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            if detail.transcripts.count > 1 {
                Picker("Version", selection: Binding(get: { transcript.engine }, set: { detail.selectedEngine = $0 })) {
                    ForEach(detail.transcripts, id: \.engine) { Text(model.engineLabel($0.engine)).tag($0.engine) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            } else {
                Text(model.engineLabel(transcript.engine)).font(.meta).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: Space.s)
            if recording.hasAudio && !isLive {
                Button("Transcribe Again…", systemImage: "waveform.badge.magnifyingglass", action: transcribeAgain)
                    .disabled(model.jobs[recording.id]?.isActive == true)
            }
        }
        .font(.small)
        .buttonStyle(.borderless)
    }
}

/// The meeting's screenshots and photos as a grid of thumbnails. Platform-specific actions go in `menu`.
struct ScreensGrid<Menu: View>: View {
    let screenshots: [Screenshot]
    var minimumWidth: CGFloat = 150
    var maxPixels: CGFloat = 500
    /// The time in the recording under each image; off when there's no audio for it to point into.
    var showsTime = true
    /// When set, clicks pick images (with a check mark) instead of opening them.
    var selection: Binding<Set<Screenshot.ID>>?
    let open: (Screenshot) -> Void
    @ViewBuilder var menu: (Screenshot) -> Menu

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: Space.m)], spacing: Space.m) {
            ForEach(screenshots) { shot in
                let picked = selection?.wrappedValue.contains(shot.id) == true
                Button {
                    if let selection {
                        if picked { selection.wrappedValue.remove(shot.id) } else { selection.wrappedValue.insert(shot.id) }
                    } else {
                        open(shot)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ScreenshotThumbnail(url: shot.url, maxPixels: maxPixels)
                            .overlay(alignment: .topTrailing) {
                                if selection != nil {
                                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                        .font(.heading)
                                        .foregroundStyle(picked ? Theme.accent : Color.white)
                                        .shadow(radius: 2)
                                        .padding(Space.s)
                                }
                            }
                            .overlay {
                                if picked { Radius.shape(Radius.m).strokeBorder(Theme.accent, lineWidth: 2) }
                            }
                        if showsTime {
                            Text(Exporter.clock(shot.time)).font(.label.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsTime ? "Screenshot at \(Exporter.clock(shot.time))" : "Screenshot")
                .accessibilityAddTraits(picked ? .isSelected : [])
                .contextMenu { menu(shot) }
            }
        }
    }
}

extension AppModel {
    /// A readable name for the engine that wrote a transcript.
    func engineLabel(_ engine: String) -> String {
        if engine.hasPrefix("openrouter:") { return "Cloud: " + engine.dropFirst("openrouter:".count) }
        if engine.hasPrefix("import:") { return "Imported" }
        if engine == "merged" { return "Merged" }
        return settings.allModels.first { $0.engineIdentifier == engine }?.displayName ?? engine
    }
}
