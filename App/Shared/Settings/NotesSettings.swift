import HushpadKit
import HushpadUI
import SwiftUI

/// Notes: which model writes them, in what language and shape, and the Ask recipes (Mac).
struct NotesSettings: View {
    var body: some View {
        NotesModelSection()
        NotesStyleSection()
        #if os(macOS)
        RecipesSection()
        #endif
    }
}

/// Language and shape of the notes. The long-form editors open in sheets, so the tab stays short.
struct NotesStyleSection: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @State private var editingTemplates = false
    @State private var editingInstructions = false
    #endif

    var body: some View {
        @Bindable var settings = model.settings
        Section("Writing") {
            LanguagePicker("Notes language", selection: $settings.notesLanguage, autoLabel: "Same as the meeting")
            TemplatePicker()
            #if os(macOS)
            LabeledContent("Templates") {
                Button("Edit Templates…") { editingTemplates = true }
            }
            LabeledContent {
                Button("Customize…") { editingInstructions = true }
            } label: {
                Text("Instructions")
                Text(settings.notesPrompt == nil ? "Default" : "Customized")
            }
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $editingTemplates) { TemplatesSheet() }
        .sheet(isPresented: $editingInstructions) { InstructionsSheet() }
        #endif
    }
}

#if os(macOS)
// MARK: - Instructions

private struct InstructionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Instructions").font(.heading)
            Text(SettingsCopy.instructions).font(.small).foregroundStyle(Theme.inkSecondary)
            TextEditor(text: Binding(
                get: { settings.notesPrompt ?? NotesGenerator.defaultInstructions },
                set: { settings.notesPrompt = $0 == NotesGenerator.defaultInstructions ? nil : $0 }))
                .font(.base)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .background(Theme.paperSunken, in: Radius.shape(Radius.m))
            HStack {
                Button("Reset to Default") { settings.notesPrompt = nil }
                    .disabled(settings.notesPrompt == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.l + Space.xs)
        .frame(width: 560, height: 480)
    }
}

// MARK: - Templates

private struct TemplatesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingTemplate: NoteTemplate?
    @State private var confirmRestore = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(settings.templates) { template in
                        HStack {
                            Text(template.name)
                            if template.id == settings.notesTemplateID {
                                Text("Default").font(.micro.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                            Spacer()
                            if template.id != settings.notesTemplateID {
                                Button("Make Default") { settings.notesTemplateID = template.id }.buttonStyle(.borderless)
                            }
                            Button("Edit…") { editingTemplate = template }.buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Templates")
                } footer: {
                    Text("A template lists the sections your notes should have.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("New Template…") {
                    // Only added to the list when saved, so Cancel leaves nothing behind.
                    editingTemplate = NoteTemplate(id: UUID().uuidString, name: "",
                                                   instructions: NoteTemplate.builtIn[0].instructions)
                }
                Button("Restore Built-in Templates…") { confirmRestore = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(Space.l)
        }
        .frame(width: 520, height: 440)
        .confirmationDialog("Restore the built-in templates?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) {
                let custom = settings.templates.filter { t in !NoteTemplate.builtIn.contains { $0.id == t.id } }
                settings.templates = NoteTemplate.builtIn + custom
            }
        } message: {
            Text("Your changes to the built-in templates are undone. Your own templates are kept.")
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditor(template: template, isNew: !settings.templates.contains { $0.id == template.id }) { updated in
                if let index = settings.templates.firstIndex(where: { $0.id == updated.id }) {
                    settings.templates[index] = updated
                } else {
                    settings.templates.append(updated)
                }
            } onDelete: {
                settings.templates.removeAll { $0.id == template.id }
                if settings.notesTemplateID == template.id { settings.notesTemplateID = settings.templates.first?.id ?? "" }
            }
        }
    }
}

private struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var template: NoteTemplate
    var isNew = false
    let onSave: (NoteTemplate) -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            TextField("Template name", text: $template.name).font(.heading).textFieldStyle(.plain)
            Text("Describe the sections you want. The model follows this structure.")
                .font(.small).foregroundStyle(.secondary)
            TextEditor(text: $template.instructions)
                .font(.mono)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .background(Theme.paperSunken, in: Radius.shape(Radius.m))
            HStack {
                if !isNew && !NoteTemplate.builtIn.contains(where: { $0.id == template.id }) {
                    Button("Delete Template…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSave(template); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.l + Space.xs)
        .frame(width: 560, height: 480)
        .confirmationDialog("Delete “\(template.name)”?", isPresented: $confirmDelete) {
            Button("Delete Template", role: .destructive) { onDelete(); dismiss() }
        }
    }
}

// MARK: - Recipes

/// "Ask anything" recipes: a summary row here, the list in a sheet.
struct RecipesSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        let mine = model.settings.recipes.count
        Section {
            LabeledContent {
                Button("Edit Recipes…") { editing = true }
            } label: {
                Text("Recipes")
                Text("\(Recipe.builtIn.count) built in\(mine > 0 ? ", \(mine) yours" : "")")
            }
        } header: {
            Text("Ask Anything")
        } footer: {
            Text(SettingsCopy.recipes)
        }
        .sheet(isPresented: $editing) { RecipesSheet() }
    }
}

private struct RecipesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var acrossMeetings = false
    /// The last deleted recipe and where it was, so it can be put back.
    @State private var lastDeleted: (recipe: Recipe, index: Int)?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            Form {
                Section("Built In") {
                    ForEach(Recipe.builtIn) { recipe in Text(recipe.name).help(recipe.prompt) }
                }
                Section("Yours") {
                    ForEach(settings.recipes) { recipe in
                        LabeledContent(recipe.name) {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(recipe) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                        .help(recipe.prompt)
                    }
                    if let lastDeleted {
                        Button("Undo Delete “\(lastDeleted.recipe.name)”") {
                            settings.recipes.insert(lastDeleted.recipe, at: min(lastDeleted.index, settings.recipes.count))
                            self.lastDeleted = nil
                        }
                    }
                    DisclosureGroup("New Recipe") {
                        TextField("Name", text: $name, prompt: Text("Prep for next week"))
                        TextField("Question", text: $prompt, prompt: Text("What did we agree to revisit next week?"), axis: .vertical)
                            .lineLimit(2...5)
                        Toggle("Ask across all meetings", isOn: $acrossMeetings)
                        Button("Add Recipe") {
                            settings.recipes.append(Recipe(name: name.trimmingCharacters(in: .whitespaces),
                                                           prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           scope: acrossMeetings ? .library : .meeting))
                            name = ""
                            prompt = ""
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(Space.l)
        }
        .frame(width: 520, height: 520)
    }

    private func delete(_ recipe: Recipe) {
        guard let index = model.settings.recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        model.settings.recipes.remove(at: index)
        lastDeleted = (recipe, index)
    }
}
#endif
