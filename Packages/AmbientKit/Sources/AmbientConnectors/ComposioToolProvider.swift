import AmbientContracts
import Foundation

public actor ComposioToolProvider: ToolProvider {
    private let client: AmbientConnectorClient
    private let authorizationRequired: @Sendable (URL) async -> Void
    private var cachedSession: ConnectorRouterSession?
    private var cachedCredential: AICredential?
    private var cachedUntil = Date.distantPast
    private var sessionRequest: Task<ConnectorRouterSession, Error>?
    private var requestingCredential: AICredential?

    /// The callback should open the URL in a browser on the main actor. It need not wait for OAuth to finish.
    public init(client: AmbientConnectorClient, authorizationRequired: @escaping @Sendable (URL) async -> Void) {
        self.client = client
        self.authorizationRequired = authorizationRequired
    }

    public func tools() async -> [any AmbientTool] {
        do {
            let (session, credential) = try await currentSession()
            return session.tools.filter { $0.type == "function" }.map {
                ComposioMetaTool(
                    definition: ToolDefinition(name: $0.function.name, description: $0.function.description ?? "", parametersJSONSchema: $0.function.parameters),
                    sessionIdentifier: session.sessionId, credential: credential, client: client,
                    authorizationRequired: authorizationRequired
                )
            }
        } catch { return [UnavailableConnectorTool(message: error.localizedDescription)] }
    }

    public func systemPromptSection() async -> String? {
        do { return try await currentSession().0.systemPrompt }
        catch { return "App connections are currently unavailable: \(error.localizedDescription)" }
    }

    private func currentSession() async throws -> (ConnectorRouterSession, AICredential) {
        let credential = try await client.currentCredential()
        if let cachedSession, cachedCredential == credential, cachedUntil > Date() { return (cachedSession, credential) }
        // Coalesce tools() and systemPromptSection() when the agent requests both together.
        let pendingRequest: Task<ConnectorRouterSession, Error>
        if let sessionRequest, requestingCredential == credential {
            pendingRequest = sessionRequest
        } else {
            let client = self.client
            pendingRequest = Task { try await client.routerSession(credential: credential) }
            sessionRequest = pendingRequest
            requestingCredential = credential
        }
        do {
            let session = try await pendingRequest.value
            if requestingCredential == credential {
                cachedSession = session
                cachedCredential = credential
                cachedUntil = Date().addingTimeInterval(5 * 60)
                sessionRequest = nil
                requestingCredential = nil
            }
            return (session, credential)
        } catch {
            if requestingCredential == credential {
                sessionRequest = nil
                requestingCredential = nil
            }
            throw error
        }
    }
}

private struct UnavailableConnectorTool: AmbientTool {
    let message: String
    var definition: ToolDefinition {
        ToolDefinition(name: "ambient_connections_unavailable", description: "Reports why app connections are unavailable. Tell the person this error before trying connected app work.", parametersJSONSchema: .object(["type": .string("object"), "properties": .object([:])]))
    }
    func run(arguments: JSONValue) async -> ToolResult { ToolResult(content: message, isError: true) }
}

private struct ComposioMetaTool: AmbientTool {
    let definition: ToolDefinition
    let sessionIdentifier: String
    let credential: AICredential
    let client: AmbientConnectorClient
    let authorizationRequired: @Sendable (URL) async -> Void

    func activityLabel(arguments: JSONValue) -> String? {
        // These are argument fields, not a catalog of apps or allowed actions.
        let subjects = argumentSubjects(arguments)
        if !subjects.isEmpty { return String(subjects.prefix(3).joined(separator: ", ").prefix(100)) }
        return definition.name.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }

    func run(arguments: JSONValue) async -> ToolResult {
        do {
            // A retained tool must not execute for a previous sign-in after the account changes.
            guard try await client.currentCredential() == credential else {
                return ToolResult(content: "Your publik account changed. Retry so Ambient can refresh app connections.", isError: true)
            }
            let result = try await client.execute(sessionIdentifier: sessionIdentifier, name: definition.name, arguments: arguments, credential: credential)
            let authorizationURLs = authorizationLinks(in: result)
            for authorizationURL in authorizationURLs { await authorizationRequired(authorizationURL) }
            let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            // Bound UTF-8 bytes so one response cannot consume the context window.
            let maximumResultBytes = 48_000
            var content = text.utf8.count > maximumResultBytes
                ? String(decoding: text.utf8.prefix(maximumResultBytes), as: UTF8.self) + "\n[Result truncated by Ambient at 48,000 UTF-8 bytes. Use narrower queries or pagination for more.]"
                : text
            if !authorizationURLs.isEmpty {
                content += "\nThe authorization link was opened in the person's browser. Ask them to finish connecting, then retry the tool after they finish; do not repeatedly call it while they authorize."
            }
            let isError = result["error"] != nil && result["error"] != .null
                || result["successful"]?.boolValue == false || result["success"]?.boolValue == false
                || ["blocked", "failed"].contains(result["resultType"]?.stringValue ?? "")
            return ToolResult(content: content, isError: isError)
        } catch { return ToolResult(content: error.localizedDescription, isError: true) }
    }
}

private func argumentSubjects(_ value: JSONValue) -> [String] {
    switch value {
    case .array(let values): return values.flatMap(argumentSubjects)
    case .object(let fields):
        let subjectFields = ["tool_slug", "toolSlug", "tool_slugs", "toolSlugs", "use_case", "useCase", "query", "search", "search_query", "toolkits"]
        let subjects = subjectFields.compactMap { fields[$0] }.flatMap { subject -> [String] in
            if let text = subject.stringValue { return [text] }
            if let values = subject.arrayValue { return values.compactMap(\.stringValue) }
            return []
        }
        return subjects.isEmpty ? fields.keys.sorted().flatMap { argumentSubjects(fields[$0]!) } : subjects
    default: return []
    }
}

private func authorizationLinks(in value: JSONValue) -> [URL] {
    var links: [URL] = []
    func visit(_ value: JSONValue) {
        switch value {
        case .object(let fields):
            for key in fields.keys.sorted() {
                let child = fields[key]!
                let normalizedKey = key.replacingOccurrences(of: "_", with: "").lowercased()
                if ["redirecturl", "authorizationurl", "authurl", "connecturl", "connectlink"].contains(normalizedKey),
                   let text = child.stringValue, let url = URL(string: text), url.scheme == "https",
                   let host = url.host?.lowercased(), host == "composio.dev" || host.hasSuffix(".composio.dev") {
                    // Only Composio authorization links auto-open; arbitrary URLs in app data do not.
                    if !links.contains(url) { links.append(url) }
                } else { visit(child) }
            }
        case .array(let children): children.forEach(visit)
        default: break
        }
    }
    visit(value)
    return links
}
