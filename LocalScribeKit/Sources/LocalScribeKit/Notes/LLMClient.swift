import Foundation

/// Where meeting notes are generated. Local servers keep everything on the Mac; OpenRouter is opt-in.
public enum NotesProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case lmStudio, ollama, openRouter, openCodeGo, custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .openRouter: "OpenRouter (cloud)"
        case .openCodeGo: "OpenCode Go (cloud)"
        case .custom: "Custom server"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .lmStudio: "http://localhost:1234/v1"
        case .ollama: "http://localhost:11434/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openCodeGo: "https://opencode.ai/zen/go/v1"
        case .custom: "http://localhost:8080/v1"
        }
    }

    /// True when the transcript leaves the Mac.
    public var isCloud: Bool { self == .openRouter || self == .openCodeGo }

    /// The model picked the first time this provider is chosen.
    public var defaultModel: String {
        switch self {
        case .openRouter: "openrouter/free"
        case .openCodeGo: "deepseek-v4-flash"
        default: ""
        }
    }

    /// Where the provider's API key is kept (iCloud Keychain); nil for local servers.
    public var keychainAccount: String? {
        switch self {
        case .openRouter: "openrouter-api-key"
        case .openCodeGo: "opencode-go-api-key"
        default: nil
        }
    }

    /// Where to get a key, shown next to the key field.
    public var keyURL: URL? {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/keys")
        case .openCodeGo: URL(string: "https://opencode.ai/auth")
        default: nil
        }
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
}

/// Minimal OpenAI-compatible chat client (LM Studio, Ollama, OpenRouter, llama.cpp server, vLLM…), with streaming.
public struct LLMClient: Sendable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    /// Extra request headers (OpenCode Go wants a stable session id per conversation).
    public var headers: [String: String]
    /// OpenRouter only: route only to providers that don't store prompts or train on them.
    public var privateRouting: Bool

    public init(baseURL: URL, apiKey: String? = nil, model: String, headers: [String: String] = [:], privateRouting: Bool = false) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.headers = headers
        self.privateRouting = privateRouting
    }

    /// A client for a provider, with what that provider needs (session header, private routing).
    public static func make(_ provider: NotesProvider, baseURL: URL, apiKey: String?, model: String, privateRouting: Bool) -> LLMClient {
        var headers: [String: String] = [:]
        if provider == .openCodeGo { headers["x-opencode-session"] = UUID().uuidString.lowercased() }
        return LLMClient(baseURL: baseURL, apiKey: provider.isCloud ? apiKey : nil, model: model, headers: headers,
                         privateRouting: provider == .openRouter && privateRouting)
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Hushpad/\(version)"
    }()

    /// No disk cache or cookies, same as the transcription cloud client.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    /// Models the server offers (LM Studio / Ollama list what's downloaded).
    public func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try check(response, data)
        struct Models: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
        return try JSONDecoder().decode(Models.self, from: data).data.map(\.id).filter(Self.speaksChatCompletions).sorted()
    }

    /// OpenCode Go also lists models that only work through its `/responses` or `/messages` endpoints.
    static func speaksChatCompletions(_ id: String) -> Bool {
        !["gpt-", "grok-", "claude-"].contains { id.hasPrefix($0) }
    }

    /// The context window the model is loaded with, when the server says (LM Studio, Ollama). nil if unknown.
    public func loadedContextLength() async -> Int? {
        // LM Studio: GET /api/v0/models/<id> → loaded_context_length (the server's root, not /v1).
        let root = baseURL.path.hasSuffix("/v1") ? baseURL.deletingLastPathComponent() : baseURL
        var request = URLRequest(url: root.appendingPathComponent("api/v0/models").appendingPathComponent(model))
        request.timeoutInterval = 5
        if let (data, response) = try? await Self.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let length = json["loaded_context_length"] as? Int ?? json["max_context_length"] as? Int {
            return length
        }
        // Ollama: POST /api/show → model_info["<arch>.context_length"] (the trained maximum; num_ctx may be lower).
        var show = URLRequest(url: root.appendingPathComponent("api/show"))
        show.httpMethod = "POST"
        show.timeoutInterval = 5
        show.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        if let (data, response) = try? await Self.session.data(for: show), (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = json["model_info"] as? [String: Any],
           let length = info.first(where: { $0.key.hasSuffix(".context_length") })?.value as? Int {
            return min(length, 8192)
        }
        return nil
    }

    /// Streams the reply; `onText` receives the full text so far after each chunk.
    /// `onThinking` is called while a reasoning model is thinking (before any answer text).
    @discardableResult
    public func complete(_ messages: [ChatMessage], temperature: Double = 0.2,
                         onThinking: @Sendable () -> Void = {},
                         onText: @Sendable (String) -> Void = { _ in }) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Hushpad", forHTTPHeaderField: "X-Title")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(body(messages, temperature: temperature))

        let (bytes, response) = try await Self.session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes.prefix(2000) { body.append(byte) }
            try check(response, body)
        }
        var text = ""
        var parser = StreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch parser.consume(line) {
            case .delta(let piece):
                text += piece
                onText(text)
            case .reasoning:
                if text.isEmpty { onThinking() }
            case .error(let message):
                throw LocalScribeError.llm(Self.explain(message))
            case .done:
                return try nonEmpty(text)
            case .none:
                continue
            }
        }
        return try nonEmpty(text)
    }

    struct Body: Encodable {
        struct Routing: Encodable, Equatable {
            var data_collection = "deny"
            var zdr = true
        }
        var model: String
        var messages: [ChatMessage]
        var temperature: Double
        var stream: Bool
        var provider: Routing?
    }

    func body(_ messages: [ChatMessage], temperature: Double) -> Body {
        Body(model: model, messages: messages, temperature: temperature, stream: true, provider: privateRouting ? Body.Routing() : nil)
    }

    private func nonEmpty(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalScribeError.llm("The model finished without writing anything. Try again, or try another model.")
        }
        return text
    }

    /// Server errors are terse; add what to do about the common ones.
    static func explain(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("context") || lower.contains("compute error") || lower.contains("too long") {
            return "\(message)\nThe meeting may be too long for the model's context window. In LM Studio, load the model with a larger context length (16k or more), or choose a smaller template."
        }
        if lower.contains("input audio") {
            return "\(message)\nThis model can't listen to audio. Choose an audio model such as google/gemini-2.5-flash for transcription."
        }
        if lower.contains("credits") || lower.contains("balance") {
            return "\(message)\nYour OpenRouter account needs credit for this (audio always needs some, even with free models). Add credits at openrouter.ai, or use a local model."
        }
        if lower.contains("data policy") || lower.contains("zero data retention") {
            return "\(message)\nNo model matches the privacy guard (providers that keep no data). Pick another model, or turn off \"Only providers that keep no data\" in Settings › Cloud."
        }
        if lower.contains("no model") || lower.contains("not loaded") || lower.contains("not found") {
            return "\(message)\nLoad the model in LM Studio (or pull it in Ollama) and try again."
        }
        return message
    }

    private func authorize(_ request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LocalScribeError.llm("No response from \(baseURL.host() ?? "server")") }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw LocalScribeError.llm("\(baseURL.host() ?? "Server") returned \(http.statusCode): \(message)")
        }
    }
}

/// Parses OpenAI-style server-sent events: `data: {json}` lines, ending with `data: [DONE]`.
struct StreamParser {
    enum Event: Equatable { case delta(String), reasoning, error(String), done }

    mutating func consume(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        // Errors arrive inside the stream with HTTP 200 (LM Studio, OpenRouter).
        if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "Unknown error"
            return .error(message)
        }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { var content: String?; var reasoning_content: String?; var reasoning: String? }
                var delta: Delta?
                var finish_reason: String?
            }
            var choices: [Choice]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)), let delta = chunk.choices.first?.delta else {
            return nil
        }
        if let content = delta.content, !content.isEmpty { return .delta(content) }
        if (delta.reasoning_content ?? delta.reasoning).map({ !$0.isEmpty }) == true { return .reasoning }
        return nil
    }
}
