// The seams between Ambient's subsystems. Each subsystem target depends on this file only.
// Changing a declaration here changes the agreement for every target: keep it small.
import Foundation

// MARK: - JSON

/// Untyped JSON, for tool arguments and JSON Schema.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dictionary) = self { return dictionary[key] }
        return nil
    }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
}

// MARK: - Tools

/// One function the model can call. `parametersJSONSchema` is a JSON Schema object.
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersJSONSchema: JSONValue
    public init(name: String, description: String, parametersJSONSchema: JSONValue) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

public struct ToolResult: Sendable, Equatable {
    /// What the model reads back. Plain text or JSON text.
    public var content: String
    public var isError: Bool
    /// Images the model should see next (a screenshot tool returns them here).
    public var images: [ImageAttachment]
    public init(content: String, isError: Bool = false, images: [ImageAttachment] = []) {
        self.content = content
        self.isError = isError
        self.images = images
    }
}

public protocol AmbientTool: Sendable {
    var definition: ToolDefinition { get }
    /// A few words for the flow bar while this call runs, such as "Searching Gmail". Nil shows the tool name.
    func activityLabel(arguments: JSONValue) -> String?
    func run(arguments: JSONValue) async -> ToolResult
}

public extension AmbientTool {
    func activityLabel(arguments: JSONValue) -> String? { nil }
}

/// A subsystem's contribution to the agent: its tools, and what the model must know to use them.
/// The agent asks again at the start of every user turn, so both may change over time.
public protocol ToolProvider: Sendable {
    func tools() async -> [any AmbientTool]
    func systemPromptSection() async -> String?
}

// MARK: - Agent

public struct ImageAttachment: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    /// Shown to the model beside the image, such as "screen 1 of 2 (primary), 1512x982 points".
    public var label: String
    public init(data: Data, mimeType: String, label: String) {
        self.data = data
        self.mimeType = mimeType
        self.label = label
    }
}

public struct UserTurn: Sendable {
    public var text: String
    public var images: [ImageAttachment]
    public init(text: String, images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }
}

public enum AgentEvent: Sendable {
    case textDelta(String)
    case toolStarted(callID: String, toolName: String, activityLabel: String)
    case toolFinished(callID: String, toolName: String, isError: Bool)
    /// The turn ended normally. `finalText` is the whole assistant reply.
    case finished(finalText: String)
    case failed(AgentFailure)
}

public enum AgentFailure: Error, Sendable, Equatable {
    /// publik answered 402. Show `message` and the one link, nothing else.
    case paymentRequired(message: String, topUpURL: URL?)
    case notSignedIn
    case cancelled
    case other(message: String)
}

/// One running conversation. `send` runs the model and its tool calls to completion and streams what happens.
public protocol AgentSession: Sendable {
    func send(_ turn: UserTurn) -> AsyncStream<AgentEvent>
    /// Stops the turn in flight; its stream ends with `.failed(.cancelled)`.
    func cancel() async
    /// Forgets the conversation so far.
    func reset() async
}

public enum ModelTier: String, Sendable { case fast = "publik-fast", balanced = "publik-balanced", smart = "publik-smart" }

/// A single model call with no tools, for subsystems that need one (memory extraction, titles).
public protocol TextCompletionService: Sendable {
    func complete(systemPrompt: String, userPrompt: String, tier: ModelTier) async throws -> String
}

/// Where the model key comes from. Nil means the person has not signed in.
public struct AICredential: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

public protocol AICredentialSource: Sendable {
    func credential() async -> AICredential?
}

// MARK: - Background tasks (agents and commands that run without a window)

public struct BackgroundTask: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case codexAgent, claudeAgent, shellCommand, ambientAgent }
    public enum Status: String, Sendable, Codable { case running, succeeded, failed, cancelled }
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var status: Status
    public var workingDirectory: String?
    public var startedAt: Date
    public var finishedAt: Date?
    /// The newest thing it did, one line, for the flow bar.
    public var latestActivity: String
    /// Its final answer, once it has one.
    public var result: String?
    public init(id: UUID, kind: Kind, title: String, status: Status, workingDirectory: String?, startedAt: Date, finishedAt: Date?, latestActivity: String, result: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.latestActivity = latestActivity
        self.result = result
    }
}

public protocol BackgroundTaskStore: Sendable {
    func tasks() async -> [BackgroundTask]
    /// The whole list, sent again on every change. Newest first.
    func updates() -> AsyncStream<[BackgroundTask]>
    func cancel(taskID: UUID) async
    /// Removes a finished task from the list.
    func dismiss(taskID: UUID) async
    /// Everything the task printed so far, readable by a person.
    func transcript(taskID: UUID) async -> String
}

// MARK: - Memory (ambient learning)

public struct MemoryItem: Identifiable, Sendable, Equatable, Codable {
    public var id: UUID
    /// One durable fact or preference, as a sentence.
    public var text: String
    public var createdAt: Date
    /// True when Ambient learned it from a conversation; false when the person or the model saved it on purpose.
    public var wasLearnedAutomatically: Bool
    public init(id: UUID, text: String, createdAt: Date, wasLearnedAutomatically: Bool) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.wasLearnedAutomatically = wasLearnedAutomatically
    }
}

public protocol MemoryStore: Sendable {
    func items() async -> [MemoryItem]
    func updates() -> AsyncStream<[MemoryItem]>
    func add(text: String) async
    func delete(itemID: UUID) async
    var isAutomaticLearningEnabled: Bool { get async }
    func setAutomaticLearningEnabled(_ isEnabled: Bool) async
    /// Called after each finished exchange. Decides on its own whether anything in it is worth keeping.
    func learn(fromUserText userText: String, assistantText: String) async
}

// MARK: - Skills

public struct SkillSummary: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var isBuiltIn: Bool
    public var directory: URL
    public init(name: String, description: String, isBuiltIn: Bool, directory: URL) {
        self.name = name
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.directory = directory
    }
}

public protocol SkillStore: Sendable {
    func skills() async -> [SkillSummary]
    func updates() -> AsyncStream<[SkillSummary]>
    /// Copies a skill folder (one that holds a SKILL.md) into the person's skills.
    func install(fromDirectory directory: URL) async throws
    func delete(skillName: String) async throws
}

// MARK: - Connectors (Composio)

public struct ConnectorApp: Identifiable, Sendable, Equatable {
    public var id: String { slug }
    public var slug: String
    public var name: String
    public var logoURL: URL?
    public var isConnected: Bool
    public init(slug: String, name: String, logoURL: URL?, isConnected: Bool) {
        self.slug = slug
        self.name = name
        self.logoURL = logoURL
        self.isConnected = isConnected
    }
}

public protocol ConnectorService: Sendable {
    /// Apps matching `query`, or the popular ones when it is empty, each with whether this person connected it.
    func apps(matching query: String) async throws -> [ConnectorApp]
    /// The page where the person authorises the app. Open it in the browser.
    func authorizationURL(forAppSlug slug: String) async throws -> URL
    func disconnect(appSlug slug: String) async throws
}
