import HushpadKit
import HushpadUI
import SwiftUI

@main
struct HushpadApp: App {
    @State private var model: AppModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // Before AppModel reads any settings or app data.
        var moveError: Error?
        do { try LegacyInstall.migrate() } catch { moveError = error }
        let model = AppModel()
        if let moveError {
            model.errorMessage = "Couldn't move the old LocalScribe folder in ~/Library/Application Support "
                + "(\(moveError.localizedDescription)). Nothing was deleted: quit Hushpad, then move that folder's contents "
                + "into the Hushpad folder next to it."
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        #if os(macOS)
        macScenes
        #else
        WindowGroup {
            PhoneRootView()
                .appLock()
                .environment(model)
                .tint(Theme.accent)
                .font(.base)
        }
        #endif
    }

    #if os(macOS)
    @SceneBuilder private var macScenes: some Scene {
        Window("Hushpad", id: "main") {
            MacRootView()
                .appLock()
                .environment(model)
                .tint(Theme.accent)
                .font(.base)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { RecordingCommands(model: model) }

        Settings {
            MacSettingsView()
                .environment(model)
                .tint(Theme.accent)
                .font(.base)
        }

        // Control the recording from the menu bar while you're in Zoom / Meet / Teams.
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            // The same icon whether or not you're recording: macOS draws menu bar icons itself, so they can't be hidden
            // from a full-screen share, and a changing icon would give the recording away. It's the app icon's ribbon,
            // not a waveform, so nothing here hints at recording.
            Image("MenuBarIcon")
                .background(MainWindowBridge())
        }
    }
    #endif
}

#if os(macOS)
/// Quitting during a recording stops and saves it first, instead of leaving it to crash recovery.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `AppModel` when it starts.
    static weak var model: AppModel?
    private static var nub: NubController?
    /// Opens (or brings back) the main window; captured from SwiftUI by `MainWindowBridge`.
    static var openMainWindow: (() -> Void)?

    static func attach(_ model: AppModel) {
        self.model = model
    }

    /// The nub is created once launch is done: AppModel is built while SwiftUI sets up its scenes, and a panel shown
    /// then would re-enter SwiftUI's update and keep the main window from opening.
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenSharePrivacy.start()
        DispatchQueue.main.async {
            guard let model = Self.model, Self.nub == nil else { return }
            Self.nub = NubController(model: model)
        }
    }

    static func showMainWindow() {
        openMainWindow?()
        NSApp.activate()
    }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isRecording else { return .terminateNow }
        Task { @MainActor in
            await model.stopRecording()
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct RecordingCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import from Granola…") { model.showGranolaImport = true }
            Button("Export All Meetings…") { model.export(nil) }
                .disabled(model.recordings.isEmpty || model.exportProgress != nil)
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Recording") {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                Task {
                    if model.isRecording {
                        await model.stopRecording()
                    } else {
                        await model.startRecording()
                    }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Take Screenshot") { Task { await model.captureScreenshot() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.isRecording || model.settings.screenshotMode == .off)
            Divider()
            Button("Transcribe All Waiting") { model.transcribeAllWaiting() }
                .disabled(model.waitingForTranscript.isEmpty)
        }
    }
}

/// Lets AppKit code (the nub) open the main SwiftUI window. Lives in the menu bar label, which always exists.
private struct MainWindowBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            AppDelegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let session = model.session {
            Text("Recording · \(Exporter.clock(session.elapsed))")
            if model.settings.screenshotMode != .off {
                Button("Take Screenshot") { Task { await model.captureScreenshot() } }
            }
            Button("Stop Recording") { Task { await model.stopRecording() } }
        } else {
            Button("Start Recording") {
                Task { await model.startRecording() }
            }
        }
        let active = model.jobs.values.filter(\.isActive).count
        if active > 0 { Text("Transcribing \(active) recording\(active == 1 ? "" : "s")…") }
        Divider()
        Button("Open Hushpad") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Hushpad") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
