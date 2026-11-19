import AmbientContracts
import Foundation

public enum AmbientConnectorError: Error, LocalizedError, Sendable {
    case notSignedIn
    case unavailable
    case invalidResponse
    case service(message: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in with publik to use app connections."
        case .unavailable: return "App connections are unreachable. Check your connection and try again."
        case .invalidResponse: return "App connections returned an unreadable response. Please try again."
        case .service(let message): return message
        }
    }
}

/// The hosted connector keeps Composio credentials out of the Mac app.
public struct AmbientConnectorClient: ConnectorService, Sendable {
    public let origin: URL
    private let credentialSource: any AICredentialSource
    private let urlSession: URLSession

    /// An explicit origin wins over AMBIENT_CONNECTOR_ORIGIN, then the loopback default.
    public init(origin: URL? = nil, credentialSource: any AICredentialSource, urlSession: URLSession = .shared) {
        self.origin = origin
            ?? ProcessInfo.processInfo.environment["AMBIENT_CONNECTOR_ORIGIN"].flatMap(URL.init(string:))
            ?? URL(string: "http://127.0.0.1:3019")!
        self.credentialSource = credentialSource
        self.urlSession = urlSession
    }

    public func apps(matching query: String) async throws -> [ConnectorApp] {
        let credential = try await currentCredential()
        var applications: [ConnectorApp] = []
        var cursor: String?
        var visitedCursors = Set<String>()
        repeat {
            var queryItems = [URLQueryItem(name: "query", value: query)]
            if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: ApplicationsResponse = try await request(path: "api/apps", queryItems: queryItems, credential: credential)
            applications.append(contentsOf: page.apps.map {
                ConnectorApp(slug: $0.slug, name: $0.name, logoURL: $0.logoURL, isConnected: $0.isConnected)
            })
            // The settings screen asks for popular apps when no search is entered.
            cursor = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : page.nextCursor
            if let cursor, !visitedCursors.insert(cursor).inserted { throw AmbientConnectorError.invalidResponse }
        } while cursor != nil
        return applications
    }

    public func authorizationURL(forAppSlug slug: String) async throws -> URL {
        let response: AuthorizationResponse = try await request(
            path: "api/connect", body: .object(["appSlug": .string(slug)]), credential: currentCredential()
        )
        guard response.authorizationURL.scheme == "https", response.authorizationURL.host != nil else {
            throw AmbientConnectorError.invalidResponse
        }
        return response.authorizationURL
    }

    public func disconnect(appSlug slug: String) async throws {
        let response: DisconnectionResponse = try await request(
            path: "api/disconnect", body: .object(["appSlug": .string(slug)]), credential: currentCredential()
        )
        guard response.ok else { throw AmbientConnectorError.invalidResponse }
    }

    func currentCredential() async throws -> AICredential {
        guard let credential = await credentialSource.credential(), credential.apiKey.hasPrefix("pk_"),
              !credential.apiKey.contains(where: { $0.isWhitespace }) else {
            throw AmbientConnectorError.notSignedIn
        }
        return credential
    }

    func routerSession(credential: AICredential) async throws -> ConnectorRouterSession {
        try await request(path: "api/tools", credential: credential)
    }

    func execute(sessionIdentifier: String, name: String, arguments: JSONValue, credential: AICredential) async throws -> JSONValue {
        let response: ExecutionResponse = try await request(path: "api/execute", body: .object([
            "sessionId": .string(sessionIdentifier), "name": .string(name), "arguments": arguments,
        ]), credential: credential)
        return response.result
    }

    private func request<ResponseBody: Decodable>(
        path: String, queryItems: [URLQueryItem] = [], body: JSONValue? = nil, credential: AICredential
    ) async throws -> ResponseBody {
        var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "")) else {
            throw AmbientConnectorError.service(message: "App connections need an HTTPS connector address, or a local development server.")
        }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 45 : 300)
        request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await urlSession.data(for: request) }
        catch { throw AmbientConnectorError.unavailable }
        guard let httpResponse = response as? HTTPURLResponse else { throw AmbientConnectorError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 { throw AmbientConnectorError.notSignedIn }
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw AmbientConnectorError.service(message: message ?? "App connections could not complete this request. Please try again.")
        }
        do { return try JSONDecoder().decode(ResponseBody.self, from: data) }
        catch { throw AmbientConnectorError.invalidResponse }
    }
}

struct ConnectorRouterSession: Decodable, Sendable {
    let sessionId: String
    let tools: [ConnectorFunctionTool]
    let systemPrompt: String?
}
struct ConnectorFunctionTool: Decodable, Sendable {
    struct Function: Decodable, Sendable {
        let name: String
        let description: String?
        let parameters: JSONValue
    }
    let type: String
    let function: Function
}
private struct ApplicationsResponse: Decodable {
    struct Application: Decodable {
        let slug: String
        let name: String
        let logoURL: URL?
        let isConnected: Bool
    }
    let apps: [Application]
    let nextCursor: String?
}
private struct AuthorizationResponse: Decodable { let authorizationURL: URL }
private struct DisconnectionResponse: Decodable { let ok: Bool }
private struct ExecutionResponse: Decodable { let result: JSONValue }
private struct ErrorResponse: Decodable {
    struct Failure: Decodable { let message: String }
    let error: Failure
}
