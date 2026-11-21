import Foundation
import AmbientContracts

public struct PublikCredentialSource: AICredentialSource {
    private let userCredential: AICredential?

    public init(userCredential: AICredential? = nil) {
        self.userCredential = userCredential
    }

    public func credential() async -> AICredential? {
        let userKey = userCredential.map { (baseURL: $0.baseURL.absoluteString, apiKey: $0.apiKey) }
        switch Publik.resolveProvider(userKey: userKey) {
        case .publik(let baseURL, let apiKey), .own(let baseURL, let apiKey):
            guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return AICredential(baseURL: url, apiKey: apiKey)
        case .needsOwnKey: return nil
        }
    }
}

struct ChatToolCall: Codable, Sendable {
    struct Function: Codable, Sendable {
        var name: String
        var arguments: String
    }
    var id: String
    var type = "function"
    var function: Function
}

struct ChatMessage: Codable, Sendable {
    var role: String
    var content: JSONValue
    var tool_calls: [ChatToolCall]?
    var tool_call_id: String?

    init(role: String, content: JSONValue, toolCalls: [ChatToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = toolCalls
        self.tool_call_id = toolCallID
    }

    static func user(text: String, images: [ImageAttachment]) -> Self {
        guard !images.isEmpty else { return Self(role: "user", content: .string(text)) }
        var parts: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for image in images {
            if !image.label.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(image.label)])) }
            parts.append(.object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:\(image.mimeType);base64,\(image.data.base64EncodedString())")])
            ]))
        }
        return Self(role: "user", content: .array(parts))
    }

    func removingImages() -> Self {
        guard case .array(let parts) = content else { return self }
        var result = self
        result.content = .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"))
        return result
    }
}

struct ChatReply: Sendable {
    var text = ""
    var toolCalls: [ChatToolCall] = []
}

/// Shared transport for chat, search and speech. The URLSession argument also allows isolated URLProtocol tests.
public struct PublikAIClient: TextCompletionService, Sendable {
    let credentialSource: any AICredentialSource
    let urlSession: URLSession
    static let maximumRequestBytes = 4_000_000
    static let historyRequestBudget = 3_800_000

    public init(credentialSource: any AICredentialSource, urlSession: URLSession = .shared) {
        self.credentialSource = credentialSource
        self.urlSession = urlSession
    }

    public func complete(systemPrompt: String, userPrompt: String, tier: ModelTier) async throws -> String {
        let messages = [ChatMessage(role: "system", content: .string(systemPrompt)), .user(text: userPrompt, images: [])]
        let body = try chatBody(messages: messages, tools: [], tier: tier, streaming: false)
        let response = try JSONDecoder().decode(JSONValue.self, from: await post(path: "chat/completions", body: body))
        guard let text = response["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue else {
            throw AgentFailure.other(message: "publik returned no completion text.")
        }
        return text
    }

    func chatBody(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier, reasoningEffort: String? = nil, streaming: Bool) throws -> Data {
        struct Request: Encodable {
            struct Tool: Encodable {
                struct Function: Encodable {
                    var name: String
                    var description: String
                    var parameters: JSONValue
                }
                var type = "function"
                var function: Function
            }
            var model: String
            var messages: [ChatMessage]
            var stream: Bool
            var tools: [Tool]?
            var reasoning_effort: String?
        }
        return try JSONEncoder().encode(Request(model: tier.rawValue, messages: messages, stream: streaming, tools: tools.isEmpty ? nil : tools.map {
            Request.Tool(function: .init(name: $0.name, description: $0.description, parameters: $0.parametersJSONSchema))
        }, reasoning_effort: reasoningEffort))
    }

    func request(path: String, body: Data, contentType: String) async throws -> URLRequest {
        try Task.checkCancellation()
        guard body.count < Self.maximumRequestBytes else {
            throw AgentFailure.other(message: "This request is too large. Use fewer or smaller images, audio, or text.")
        }
        guard let credential = await credentialSource.credential(), !credential.apiKey.isEmpty else { throw AgentFailure.notSignedIn }
        var request = URLRequest(url: credential.baseURL.appendingPathComponent(path), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func post(path: String, body: Data, contentType: String = "application/json") async throws -> Data {
        let request = try await request(path: path, body: body, contentType: contentType)
        for attempt in 0...2 {
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AgentFailure.other(message: "publik returned an invalid HTTP response.") }
            if try await retryRateLimit(response, attempt: attempt) { continue }
            try validate(response, data: data)
            return data
        }
        throw AgentFailure.other(message: "publik is rate limited. Try again shortly.")
    }

    func stream(body: Data, onText: @escaping @Sendable (String) -> Void) async throws -> ChatReply {
        var request = try await request(path: "chat/completions", body: body, contentType: "application/json")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for attempt in 0...2 {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw AgentFailure.other(message: "publik returned an invalid HTTP response.") }
            if !(200..<300).contains(response.statusCode) {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    if data.count >= 65_536 { break }
                }
                if try await retryRateLimit(response, attempt: attempt) { continue }
                try validate(response, data: data)
            }
            var parser = ChatEventParser()
            var eventLines: [String] = []
            var lineParser = ServerSentEventLineParser()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let line = lineParser.append(byte) else { continue }
                if line.isEmpty {
                    if try parser.consume(eventLines.joined(separator: "\n"), onText: onText) { return try parser.reply() }
                    eventLines.removeAll(keepingCapacity: true)
                } else if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    eventLines.append(value)
                }
            }
            if !eventLines.isEmpty { _ = try parser.consume(eventLines.joined(separator: "\n"), onText: onText) }
            guard parser.receivedFinish else { throw AgentFailure.other(message: "The model's response ended unexpectedly. Try again.") }
            return try parser.reply()
        }
        throw AgentFailure.other(message: "publik is rate limited. Try again shortly.")
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let error = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]
        let message = error?["message"]?.stringValue ?? "publik API answered \(response.statusCode)."
        switch response.statusCode {
        case 401: throw AgentFailure.notSignedIn
        case 402: throw AgentFailure.paymentRequired(message: message, topUpURL: error?["top_up_url"]?.stringValue.flatMap(URL.init(string:)))
        default: throw AgentFailure.other(message: message)
        }
    }

    private func retryRateLimit(_ response: HTTPURLResponse, attempt: Int) async throws -> Bool {
        guard response.statusCode == 429, attempt < 2 else { return false }
        let header = response.value(forHTTPHeaderField: "Retry-After")
        let delay: TimeInterval
        if let header, let seconds = Double(header), seconds.isFinite { delay = max(0, seconds) }
        else if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: header) else { return false }
            delay = max(0, date.timeIntervalSinceNow)
        } else { delay = 1 }
        // A daily budget can also return 429. Never retry sooner than requested or wait all day.
        guard delay <= 5 else { return false }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return true
    }
}

private struct ChatEventParser {
    private var text = ""
    private var calls: [Int: ChatToolCall] = [:]
    var receivedFinish = false

    mutating func consume(_ event: String, onText: (String) -> Void) throws -> Bool {
        guard !event.isEmpty else { return false }
        if event == "[DONE]" { receivedFinish = true; return true }
        let chunk = try JSONDecoder().decode(JSONValue.self, from: Data(event.utf8))
        if let error = chunk["error"] {
            throw AgentFailure.other(message: error["message"]?.stringValue ?? "The model stream failed.")
        }
        for choice in chunk["choices"]?.arrayValue ?? [] {
            guard choice["index"]?.numberValue ?? 0 == 0 else { continue }
            if let reason = choice["finish_reason"]?.stringValue {
                guard ["stop", "tool_calls", "function_call"].contains(reason) else {
                    throw AgentFailure.other(message: "The model stopped before completing its reply (\(reason)).")
                }
                receivedFinish = true
            }
            let delta = choice["delta"]
            if let fragment = delta?["content"]?.stringValue { text += fragment; onText(fragment) }
            for fragment in delta?["tool_calls"]?.arrayValue ?? [] {
                guard let number = fragment["index"]?.numberValue, number >= 0, number < 128, number.rounded() == number else {
                    throw AgentFailure.other(message: "The model returned an invalid tool-call index.")
                }
                let index = Int(number)
                var call = calls[index] ?? ChatToolCall(id: "", function: .init(name: "", arguments: ""))
                if let id = fragment["id"]?.stringValue { call.id += id }
                if let name = fragment["function"]?["name"]?.stringValue { call.function.name += name }
                if let arguments = fragment["function"]?["arguments"]?.stringValue { call.function.arguments += arguments }
                calls[index] = call
            }
        }
        return false
    }

    func reply() throws -> ChatReply {
        let orderedCalls = calls.keys.sorted().compactMap { calls[$0] }
        guard orderedCalls.allSatisfy({ !$0.id.isEmpty }), Set(orderedCalls.map(\.id)).count == orderedCalls.count else {
            throw AgentFailure.other(message: "The model returned tool calls without unique IDs.")
        }
        return ChatReply(text: text, toolCalls: orderedCalls)
    }
}

// Foundation's AsyncBytes.lines drops blank lines on some macOS versions. SSE needs them as event boundaries.
private struct ServerSentEventLineParser {
    private var buffer = Data()
    private var previousWasCarriageReturn = false

    mutating func append(_ byte: UInt8) -> String? {
        if byte == 10 && previousWasCarriageReturn {
            previousWasCarriageReturn = false
            return nil
        }
        previousWasCarriageReturn = byte == 13
        if byte == 10 || byte == 13 {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            return line
        }
        buffer.append(byte)
        return nil
    }
}
