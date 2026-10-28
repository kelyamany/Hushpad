import HushpadKit
import HushpadUI
import SwiftUI

/// The floating "Ask anything" bar: an optional control on the left (the transcript toggle on a meeting),
/// the question field, and recipes. Type "/" for recipes.
struct AskBar<Leading: View>: View {
    @Environment(AppModel.self) private var model
    let scope: ChatService.Scope
    var placeholder = "Ask anything"
    @ViewBuilder var leading: () -> Leading

    @State private var text = ""
    @FocusState private var focused: Bool

    private var recipes: [Recipe] {
        let wanted: Recipe.Scope = scope == .library ? .library : .meeting
        return model.settings.allRecipes.filter { $0.scope == wanted || wanted == .library }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            leading()
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
                .onChange(of: text) { _, value in if value == "/" { text = ""; showRecipes = true } }
                .accessibilityLabel(scope == .library ? "Ask about all meetings" : "Ask about this meeting")
            Menu {
                ForEach(recipes) { recipe in
                    Button(recipe.name) { model.chat.ask(recipe.prompt, label: recipe.name, scope: scope) }
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize()
            .help("Recipes (type /)")
            .popover(isPresented: $showRecipes, arrowEdge: .bottom) { recipeList }
            if model.chat.isRunning(scope) {
                Button { model.chat.cancel(scope) } label: { Image(systemName: "stop.circle.fill").font(.heading) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkSecondary)
                    .help("Stop")
                    .accessibilityLabel("Stop answering")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.heading) }
                    .buttonStyle(.plain)
                    .foregroundStyle(text.isEmpty ? Theme.inkTertiary : Theme.accent)
                    .disabled(text.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Ask")
                    .accessibilityLabel("Ask")
            }
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.s + 2)
        .frame(minHeight: 44)
        .background(Theme.paperRaised, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.hairline) }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .frame(maxWidth: 560)
    }

    @State private var showRecipes = false

    private var recipeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recipes").font(.label.weight(.medium)).foregroundStyle(Theme.inkSecondary).padding(.horizontal, Space.s)
            ForEach(recipes) { recipe in
                Button {
                    showRecipes = false
                    model.chat.ask(recipe.prompt, label: recipe.name, scope: scope)
                } label: {
                    Text(recipe.name).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.s).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.s)
        .frame(width: 260)
    }

    private func send() {
        guard !text.isEmpty else { return }
        model.chat.ask(text, scope: scope)
        text = ""
    }
}

/// The answers above the bar. Each can be copied, or added to your notes on a meeting.
struct ChatThread: View {
    @Environment(AppModel.self) private var model
    let scope: ChatService.Scope
    var addToNotes: ((String) -> Void)?

    var body: some View {
        let turns = model.chat.turns(scope)
        if !turns.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(scope == .library ? "Ask your meetings" : "Ask this meeting")
                        .font(.label.weight(.medium)).foregroundStyle(Theme.inkSecondary)
                    if model.settings.notesProvider.isCloud { StatusPill(.cloud) }
                    Spacer()
                    Button("Clear", systemImage: "xmark") { model.chat.clear(scope) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSecondary)
                        .help("Clear this chat")
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.l) {
                            ForEach(turns) { turn in
                                TurnView(turn: turn, addToNotes: addToNotes).id(turn.id)
                            }
                        }
                        .padding(Space.l)
                    }
                    .onChange(of: turns.last?.answer) { if let id = turns.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .frame(maxWidth: 640, maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.paperRaised, in: Radius.shape(Radius.l))
            .overlay { Radius.shape(Radius.l).strokeBorder(Theme.hairline) }
            .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
            .environment(\.openURL, OpenURLAction { url in
                if let id = MeetingChat.meetingID(from: url) {
                    model.selection = id
                    return .handled
                }
                return .systemAction
            })
        }
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    let addToNotes: ((String) -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(turn.label)
                .font(.small.weight(.medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xs + 2)
                .background(Theme.paperSunken, in: Radius.shape(Radius.m))
                .frame(maxWidth: .infinity, alignment: .trailing)
            switch turn.state {
            case .thinking:
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(Theme.inkSecondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger).font(.small)
            case .writing, .done:
                MarkdownView(turn.answer, hidesTitle: false)
                    .textSelection(.enabled)
                if turn.state == .done {
                    HStack(spacing: Space.m) {
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            Clipboard.copy(turn.answer)
                            copied = true
                        }
                        if let addToNotes {
                            Button("Add to My Notes", systemImage: "text.badge.plus") { addToNotes(turn.answer) }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.label)
                    .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }
}
