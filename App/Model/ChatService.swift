import Foundation
import LocalScribeKit
import Observation

/// One question and its (streaming) answer.
struct ChatTurn: Identifiable, Equatable {
    enum State: Equatable { case thinking, writing, done, failed(String) }

    let id = UUID()
    var question: String
    /// What the button or recipe said, shown instead of a long recipe prompt.
    var label: String
    var answer = ""
    var state = State.thinking

    var isRunning: Bool { state == .thinking || state == .writing }
}

/// "Ask anything": questions about the meeting you're in (even while it's still going) or across
/// all meetings. Uses the same notes model as meeting notes, with the same privacy rules: a local model by default, a
/// cloud model only if you chose one (text only, names hidden if you asked). Chats last until the app quits.
@MainActor @Observable
final class ChatService {
    enum Scope: Hashable {
        case meeting(UUID)
        case library
    }

    private(set) var threads: [Scope: [ChatTurn]] = [:]
    @ObservationIgnored private var tasks: [Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private weak var model: AppModel?

    func attach(_ model: AppModel) { self.model = model }

    func turns(_ scope: Scope) -> [ChatTurn] { threads[scope] ?? [] }
    func isRunning(_ scope: Scope) -> Bool { turns(scope).last?.isRunning == true }

    func clear(_ scope: Scope) {
        tasks[scope]?.cancel()
        threads[scope] = nil
    }

    func cancel(_ scope: Scope) { tasks[scope]?.cancel() }

    func ask(_ question: String, label: String? = nil, scope: Scope) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let model, !isRunning(scope) else { return }
        let history = turns(scope).filter { $0.state == .done }
        threads[scope, default: []].append(ChatTurn(question: question, label: label ?? question))
        guard let client = model.settings.notesClient() else {
            update(scope) { $0.state = .failed(model.settings.notesUnavailableReason ?? "Set up a notes model in Settings › Notes.") }
            return
        }
        let request = Request(question: question, history: history, scope: scope, client: client,
                              masking: model.settings.notesProvider.isCloud && model.settings.cloudMaskNames,
                              language: model.settings.notesLanguage)
        let material = model.chatMaterial(for: scope)
        tasks[scope] = Task { [weak self] in
            do {
                let answer = try await Self.answer(request, material: material) { text in
                    Task { @MainActor in self?.update(scope) { $0.answer = text; $0.state = .writing } }
                }
                self?.update(scope) { $0.answer = answer; $0.state = .done }
            } catch is CancellationError {
                self?.update(scope) { $0.state = $0.answer.isEmpty ? .failed("Stopped.") : .done }
            } catch {
                self?.update(scope) { $0.state = .failed(error.localizedDescription) }
            }
            self?.tasks[scope] = nil
        }
    }

    private func update(_ scope: Scope, _ change: (inout ChatTurn) -> Void) {
        guard var list = threads[scope], !list.isEmpty else { return }
        change(&list[list.count - 1])
        threads[scope] = list
    }

    // MARK: Answering (off the main actor)

    struct Request: Sendable {
        var question: String
        var history: [ChatTurn]
        var scope: Scope
        var client: LLMClient
        var masking: Bool
        var language: TranscriptLanguage
    }

    /// What to answer from: one meeting (loaded lazily, so disk reads happen off the main actor), or the library's
    /// candidates and a loader for the chosen ones.
    enum Material: Sendable {
        case meeting(live: Bool, load: @Sendable () -> MeetingChat.Meeting)
        case library(candidates: [MeetingChat.Candidate], load: @Sendable ([UUID]) -> [MeetingChat.Meeting])
    }

    nonisolated private static func answer(_ request: Request, material: Material,
                                           onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let contextTokens = await request.client.loadedContextLength() ?? 32_000
        let budget = min(NotesGenerator.transcriptBudget(contextTokens: contextTokens), 150_000)
        let system: String, context: String, meetings: [MeetingChat.Meeting]
        switch material {
        case .meeting(let live, let load):
            let meeting = load()
            meetings = [meeting]
            system = MeetingChat.systemPrompt(live: live, library: false, language: request.language)
            context = MeetingChat.context(meeting, budget: budget, live: live)
        case .library(let candidates, let load):
            meetings = load(MeetingChat.rank(candidates, question: request.question))
            system = MeetingChat.systemPrompt(live: false, library: true, language: request.language)
            context = MeetingChat.libraryContext(meetings, budget: budget)
        }
        try Task.checkCancellation()

        // Cloud models: people's names become placeholders, and are put back in the answer.
        let masker = request.masking ? NameMasker(names: meetings.flatMap(Self.names)) : nil
        let mask: (String) -> String = { masker?.mask($0) ?? $0 }
        let history = request.history.flatMap { [ChatMessage.user(mask($0.question)), ChatMessage(role: "assistant", content: mask($0.answer))] }
        let messages = MeetingChat.messages(system: system, context: mask(context), history: history, question: mask(request.question))
        let reply = try await request.client.complete(messages, temperature: 0.3, onText: { text in
            onText(masker?.unmask(text) ?? text)
        })
        return masker?.unmask(reply) ?? reply
    }

    nonisolated private static func names(_ meeting: MeetingChat.Meeting) -> [String] {
        (meeting.transcript?.speakers.map(\.name) ?? []).filter { !["You", "Them", "Me", "Unknown"].contains($0) }
    }
}

extension AppModel {
    /// Snapshot of what a question in `scope` can see, gathered on the main actor; file reads happen later, off it.
    func chatMaterial(for scope: ChatService.Scope) -> ChatService.Material {
        let store = self.store
        switch scope {
        case .meeting(let id):
            guard let recording = recordings.first(where: { $0.id == id }) else {
                return .meeting(live: false) { MeetingChat.Meeting(id: id, title: "Meeting", date: Date()) }
            }
            if let session, session.recording.id == id {
                // The meeting in progress: what you've typed and the live captions so far.
                let meeting = MeetingChat.Meeting(id: id, title: session.recording.title, date: session.startDate, myNotes: liveNotes,
                                                  transcript: session.live?.transcript.transcript(language: recording.language))
                return .meeting(live: true) { meeting }
            }
            return .meeting(live: false) {
                let transcripts = store.transcripts(for: id)
                return MeetingChat.Meeting(
                    id: id, title: recording.title, date: recording.createdAt,
                    myNotes: store.notes(for: id, .mine) ?? "", enhancedNotes: store.notes(for: id, .enhanced),
                    transcript: transcripts.first { $0.engine == recording.activeEngine } ?? transcripts.last)
            }
        case .library:
            let candidates = recordings.map { recording in
                MeetingChat.Candidate(id: recording.id, date: recording.createdAt,
                                      text: recording.title.lowercased() + " " + (summaries[recording.id]?.searchText ?? ""))
            }
            let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
            return .library(candidates: candidates) { ids in
                ids.compactMap { byID[$0] }.map { recording in
                    let enhanced = store.notes(for: recording.id, .enhanced)
                    // Notes are the dense summary; the transcript is only needed when there are none.
                    let transcript = enhanced == nil ? store.transcripts(for: recording.id).last : nil
                    return MeetingChat.Meeting(id: recording.id, title: recording.title, date: recording.createdAt,
                                               myNotes: store.notes(for: recording.id, .mine) ?? "", enhancedNotes: enhanced,
                                               transcript: transcript)
                }
            }
        }
    }
}
