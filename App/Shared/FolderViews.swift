import LocalScribeKit
import LocalScribeUI
import SwiftUI
import UniformTypeIdentifiers

/// Asks the root view to show the folder editor (new or existing), optionally filing meetings into the result.
struct FolderEditorRequest: Identifiable {
    var id = UUID()
    var folder: Folder?
    var moving: [UUID] = []
}

/// "Move to Folder" with every folder, "No Folder", and "New Folder…".
struct MoveToFolderMenu: View {
    @Environment(AppModel.self) private var model
    let recordings: [Recording]

    var body: some View {
        Menu {
            let current = Set(recordings.map(\.folderID))
            ForEach(model.folders) { folder in
                Button { model.move(recordings.map(\.id), to: folder) } label: {
                    Label(folder.name, systemImage: current == [folder.id] ? "checkmark" : folder.symbol)
                }
            }
            if !model.folders.isEmpty { Divider() }
            if current != [nil] {
                Button("Remove from Folder", systemImage: "tray") { model.move(recordings.map(\.id), to: nil) }
            }
            Button("New Folder…", systemImage: "folder.badge.plus") {
                model.folderEditor = FolderEditorRequest(moving: recordings.map(\.id))
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
        .disabled(recordings.contains { !model.canMove($0) })
    }
}

/// Name, symbol and colour for a folder.
struct FolderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FolderEditorRequest

    @State private var name = ""
    @State private var symbol = "folder"
    @State private var colorIndex = 0
    @State private var notesPrompt: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Space.m) {
                        Image(systemName: symbol)
                            .font(.displaySmall)
                            .foregroundStyle(Theme.folderColor(colorIndex))
                            .frame(width: 36)
                        TextField("Folder name", text: $name)
                            .font(.heading)
                            .focused($nameFocused)
                            .onSubmit(save)
                    }
                }
                Section("Colour") {
                    HStack(spacing: Space.s) {
                        ForEach(Theme.speakerPalette.indices, id: \.self) { index in
                            Button { colorIndex = index } label: {
                                Circle().fill(Theme.folderColor(index))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().strokeBorder(Theme.ink.opacity(colorIndex == index ? 0.8 : 0), lineWidth: 2).padding(-4))
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(index + 1)")
                            .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                        }
                    }
                }
                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: Space.s) {
                        ForEach(Folder.symbols, id: \.self) { name in
                            Button { symbol = name } label: {
                                Image(systemName: name)
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(symbol == name ? Theme.folderColor(colorIndex) : Theme.inkSecondary)
                                    .background(symbol == name ? Theme.folderColor(colorIndex).opacity(0.14) : .clear,
                                                in: Radius.shape(Radius.s))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Folder.symbolName(name))
                            .accessibilityAddTraits(symbol == name ? .isSelected : [])
                        }
                    }
                }
                Section {
                    Toggle("Custom instructions for this folder", isOn: Binding(
                        get: { notesPrompt != nil },
                        set: { notesPrompt = $0 ? model.settings.notesInstructions(folder: nil).text : nil }))
                    if notesPrompt != nil {
                        TextEditor(text: Binding(get: { notesPrompt ?? "" }, set: { notesPrompt = $0 }))
                            .frame(minHeight: 160)
                    }
                } header: {
                    Text("Notes instructions")
                } footer: {
                    Text("How notes are written for meetings in this folder. Otherwise the app's instructions are used.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(request.folder == nil ? "New Folder" : "Edit Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.folder == nil ? "Create" : "Done", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let folder = request.folder {
                    name = folder.name
                    symbol = folder.symbol
                    colorIndex = folder.colorIndex
                    notesPrompt = folder.notesPrompt
                } else {
                    colorIndex = model.folders.count % Theme.speakerPalette.count
                }
                nameFocused = true
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if var folder = request.folder {
            folder.name = trimmed
            folder.symbol = symbol
            folder.colorIndex = colorIndex
            folder.notesPrompt = notesPrompt
            model.updateFolder(folder)
        } else {
            var folder = model.createFolder(name: trimmed, symbol: symbol, colorIndex: colorIndex)
            if notesPrompt != nil {
                folder.notesPrompt = notesPrompt
                model.updateFolder(folder)
            }
            if !request.moving.isEmpty { model.move(request.moving, to: folder) }
        }
        dismiss()
    }
}


extension Folder {
    /// "person.2.fill" → "Person 2", for VoiceOver.
    static func symbolName(_ symbol: String) -> String {
        symbol.split(separator: ".").filter { $0 != "fill" }.joined(separator: " ").capitalized
    }
}
