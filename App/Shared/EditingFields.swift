import HushpadKit
import HushpadUI
import SwiftUI
import UniformTypeIdentifiers

/// A plain notes editor with a placeholder. Saves after a short pause, when it goes away, and when the app goes
/// to the background or quits, so typing never hits the disk on every keystroke and nothing is lost.
/// Notes that arrive from another device replace the text only while you have no unsaved edits.
struct NotesEditor: View {
    let initial: String
    var placeholder = "Write notes…"
    let save: (String) -> Void

    @State private var text = ""
    @State private var loaded = false
    /// What is on disk, as far as this editor knows; unsaved edits are `text != saved`.
    @State private var saved = ""
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextEditor(text: $text)
            .font(.base)
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.ink)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(placeholder)
            .onAppear {
                guard !loaded else { return }
                text = initial
                saved = initial
                loaded = true
            }
            .onChange(of: initial) { _, newValue in
                // The saved text arrived (or changed on another device) and nothing unsaved was typed.
                if loaded, text == saved {
                    text = newValue
                    saved = newValue
                }
            }
            .onChange(of: text) { _, newValue in
                guard loaded, newValue != saved else { return }
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    flush()
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { flush() } }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
            #endif
            .onDisappear(perform: flush)
    }

    /// Saves now if there is anything unsaved.
    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard loaded, text != saved else { return }
        saved = text
        save(text)
    }
}

/// A title field that saves when you press Return or click away.
struct TitleField: View {
    let recording: Recording
    var font: Font = .displayLarge
    let save: (String) -> Void

    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        #if os(macOS)
        // Single line on the Mac: a multi-line field leaves an empty gap under long titles.
        let field = TextField("Title", text: $title)
        #else
        let field = TextField("Title", text: $title, axis: .vertical)
        #endif
        field
            .font(font)
            .foregroundStyle(Theme.ink)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { commit(); focused = false }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onAppear { title = recording.title }
            .onChange(of: recording.title) { _, newValue in if !focused { title = newValue } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if trimmed.isEmpty { title = recording.title; return }
        if trimmed != recording.title { save(trimmed) }
    }
}
