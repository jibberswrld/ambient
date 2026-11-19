import AmbientContracts
import Foundation
import XCTest
@testable import AmbientConnectors

private actor TestCredentialSource: AICredentialSource {
    var key: String?
    init(key: String? = "pk_fixture") { self.key = key }
    func credential() async -> AICredential? {
        key.map { AICredential(baseURL: URL(string: "https://publikhq.com/api/v1")!, apiKey: $0) }
    }
    func changeKey(_ key: String?) { self.key = key }
}

private actor AuthorizationRecorder {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AmbientConnectorsTests: XCTestCase {
    private func client(credentials: TestCredentialSource = TestCredentialSource()) -> AmbientConnectorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AmbientConnectorClient(origin: URL(string: "http://127.0.0.1:3019")!, credentialSource: credentials, urlSession: URLSession(configuration: configuration))
    }

    private func response(_ value: Any, status: Int = 200) throws -> (Int, Data) {
        (status, try JSONSerialization.data(withJSONObject: value))
    }

    private var toolsPayload: [String: Any] {
        ["sessionId": "session_fixture", "systemPrompt": "Use Composio's search first.", "tools": [[
            "type": "function", "function": ["name": "COMPOSIO_SEARCH_TOOLS", "description": "Search any connected app", "parameters": ["type": "object", "properties": ["queries": ["type": "array"]]]],
        ]]]
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        } else { data = Data() }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testClientListsEveryPageWithBearerAndPreservesAppFields() async throws {
        var requests = 0
        StubURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_fixture")
            XCTAssertEqual(request.url?.path, "/api/apps")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "query" })?.value, "unlisted & app")
            if requests == 1 {
                return try self.response(["apps": [["slug": "unlisted_app", "name": "Unlisted App", "logoURL": "https://example.com/logo.png", "isConnected": true]], "nextCursor": "next"])
            }
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, "next")
            return try self.response(["apps": [["slug": "other", "name": "Other", "logoURL": NSNull(), "isConnected": false]], "nextCursor": NSNull()])
        }
        let apps = try await client().apps(matching: "unlisted & app")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(apps.map(\.slug), ["unlisted_app", "other"])
        XCTAssertTrue(apps[0].isConnected)
        XCTAssertNotNil(apps[0].logoURL)
        XCTAssertNil(apps[1].logoURL)
    }

    func testEmptyQueryReturnsPopularPageWithoutLoadingWholeCatalog() async throws {
        var requestCount = 0
        StubURLProtocol.handler = { _ in
            requestCount += 1
            return try self.response(["apps": [["slug": "popular", "name": "Popular", "isConnected": false]], "nextCursor": "more"])
        }
        let applications = try await client().apps(matching: "")
        XCTAssertEqual(applications.map(\.slug), ["popular"])
        XCTAssertEqual(requestCount, 1)
    }

    func testConnectAndDisconnectPostAppSlug() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try self.requestBody(request)["appSlug"] as? String, "unlisted_app")
            if request.url?.path == "/api/connect" {
                return try self.response(["authorizationURL": "https://connect.composio.dev/link/fixture"])
            }
            XCTAssertEqual(request.url?.path, "/api/disconnect")
            return try self.response(["ok": true])
        }
        let client = client()
        let url = try await client.authorizationURL(forAppSlug: "unlisted_app")
        XCTAssertEqual(url.host, "connect.composio.dev")
        try await client.disconnect(appSlug: "unlisted_app")
    }

    func testProviderCachesDefinitionsAndGuidanceAndPostsSessionArguments() async throws {
        var fetchCount = 0
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/tools" {
                fetchCount += 1
                return try self.response(self.toolsPayload)
            }
            let body = try self.requestBody(request)
            XCTAssertEqual(request.url?.path, "/api/execute")
            XCTAssertEqual(body["sessionId"] as? String, "session_fixture")
            XCTAssertEqual(body["name"] as? String, "COMPOSIO_SEARCH_TOOLS")
            XCTAssertNotNil((body["arguments"] as? [String: Any])?["queries"])
            return try self.response(["result": ["resultType": "completed", "data": ["tools": ["DISCOVERED_TOOL"]], "error": NSNull()]])
        }
        let provider = ComposioToolProvider(client: client(), authorizationRequired: { _ in XCTFail("Unexpected authorization") })
        async let definitions = provider.tools()
        async let guidance = provider.systemPromptSection()
        let (tools, systemPrompt) = await (definitions, guidance)
        XCTAssertEqual(systemPrompt, "Use Composio's search first.")
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].definition.parametersJSONSchema["type"], .string("object"))
        _ = await provider.tools()
        XCTAssertEqual(fetchCount, 1)
        let arguments: JSONValue = .object(["queries": .array([.object(["use_case": .string("send an email")])])])
        XCTAssertEqual(tools[0].activityLabel(arguments: arguments), "send an email")
        let result = await tools[0].run(arguments: arguments)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("DISCOVERED_TOOL"))
    }

    func testGenericActivityLabelsUseToolSlugsAndBoundLength() async throws {
        StubURLProtocol.handler = { _ in try self.response(self.toolsPayload) }
        let provider = ComposioToolProvider(client: client(), authorizationRequired: { _ in })
        let tools = await provider.tools()
        let arguments: JSONValue = .object(["tools": .array([.object(["tool_slug": .string("SOME_APP_DO_WORK"), "arguments": .object([:])])])])
        XCTAssertEqual(tools[0].activityLabel(arguments: arguments), "SOME_APP_DO_WORK")
        XCTAssertLessThanOrEqual(tools[0].activityLabel(arguments: .object(["query": .string(String(repeating: "long ", count: 100))]))!.count, 100)
    }

    func testAuthorizationCallbackFindsNestedComposioLinksOnceBeforeTruncation() async throws {
        let recorder = AuthorizationRecorder()
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/tools" { return try self.response(self.toolsPayload) }
            return try self.response(["result": ["resultType": "completed", "error": NSNull(), "data": [
                "connections": [["redirect_url": "https://connect.composio.dev/link/fixture"], ["redirectUrl": "https://connect.composio.dev/link/fixture"]],
                "auth_url": "https://untrusted.example/should-not-open", "url": "https://example.com/article",
                "large": String(repeating: "🐈", count: 30_000),
            ]]])
        }
        let provider = ComposioToolProvider(client: client(), authorizationRequired: { await recorder.record($0) })
        let tools = await provider.tools()
        let result = await tools[0].run(arguments: .object([:]))
        let urls = await recorder.urls
        XCTAssertEqual(urls.map(\.absoluteString), ["https://connect.composio.dev/link/fixture"])
        XCTAssertTrue(result.content.contains("authorization link was opened"))
        XCTAssertTrue(result.content.contains("retry the tool after they finish"))
        XCTAssertTrue(result.content.contains("Result truncated"))
        XCTAssertLessThan(result.content.utf8.count, 49_000)
    }

    func testFailedResultWithoutErrorMessageStillMarksToolAsError() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/tools" { return try self.response(self.toolsPayload) }
            return try self.response(["result": ["resultType": "failed", "data": [:], "error": NSNull()]])
        }
        let tools = await ComposioToolProvider(client: client(), authorizationRequired: { _ in }).tools()
        let result = await tools[0].run(arguments: .object([:]))
        XCTAssertTrue(result.isError)
    }

    func testAccountChangesRefreshToolsAndInvalidatePreviouslyReturnedTools() async throws {
        let credentials = TestCredentialSource()
        var executions = 0
        var fetches = 0
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/tools" { fetches += 1; return try self.response(self.toolsPayload) }
            executions += 1
            return try self.response(["result": [:]])
        }
        let provider = ComposioToolProvider(client: client(credentials: credentials), authorizationRequired: { _ in })
        let previousTools = await provider.tools()
        await credentials.changeKey("pk_other")
        let result = await previousTools[0].run(arguments: .object([:]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("account changed"))
        XCTAssertEqual(executions, 0)
        _ = await provider.tools()
        XCTAssertEqual(fetches, 2)
    }

    func testUnreachableAndUnconfiguredServicesProduceReadableErrorTools() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let provider = ComposioToolProvider(client: client(), authorizationRequired: { _ in })
        var tools = await provider.tools()
        var result = await tools[0].run(arguments: .object([:]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("unreachable"))
        StubURLProtocol.handler = { _ in try self.response(["error": ["code": "connector_not_configured", "message": "App connections are not configured yet."]], status: 503) }
        tools = await provider.tools()
        result = await tools[0].run(arguments: .object([:]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("not configured"))
    }

    func testMissingCredentialDoesNotContactServer() async throws {
        StubURLProtocol.handler = { _ in XCTFail("A signed-out person should not contact the connector"); throw URLError(.badServerResponse) }
        let provider = ComposioToolProvider(client: client(credentials: TestCredentialSource(key: nil)), authorizationRequired: { _ in })
        let tools = await provider.tools()
        let result = await tools[0].run(arguments: .object([:]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Sign in with publik"))
    }

    func testExecutionHTTPErrorBecomesReadableResult() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/tools" { return try self.response(self.toolsPayload) }
            return try self.response(["error": ["message": "The connected app did not answer. Please try again."]], status: 502)
        }
        let tools = await ComposioToolProvider(client: client(), authorizationRequired: { _ in }).tools()
        let result = await tools[0].run(arguments: .object([:]))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.content, "The connected app did not answer. Please try again.")
    }

    func testClientRejectsInsecureRemoteOriginBeforeSendingCredential() async throws {
        let client = AmbientConnectorClient(origin: URL(string: "http://remote.example")!, credentialSource: TestCredentialSource())
        do {
            _ = try await client.apps(matching: "")
            XCTFail("Insecure remote connector accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
    }

    func testLiveConnector() async throws {
        guard ProcessInfo.processInfo.environment["AMBIENT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AMBIENT_LIVE_TESTS=1 with the local connector running to test real Composio responses.")
        }
        let credentialURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/publik/apps/looseends.json")
        let credentialObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: credentialURL)) as? [String: Any])
        let key = try XCTUnwrap(credentialObject["key"] as? String)
        let client = AmbientConnectorClient(credentialSource: TestCredentialSource(key: key))
        let apps = try await client.apps(matching: "gmail")
        XCTAssertTrue(apps.contains { $0.slug == "gmail" && $0.name == "Gmail" && $0.logoURL != nil })
        let authorizationURL = try await client.authorizationURL(forAppSlug: "gmail")
        XCTAssertEqual(authorizationURL.scheme, "https")
        XCTAssertEqual(authorizationURL.host, "connect.composio.dev")
        let provider = ComposioToolProvider(client: client, authorizationRequired: { _ in XCTFail("Read-only search should not open an authorization flow") })
        let tools = await provider.tools()
        XCTAssertGreaterThan(tools.count, 1)
        let prompt = await provider.systemPromptSection()
        XCTAssertFalse(prompt?.isEmpty ?? true)
        let search = try XCTUnwrap(tools.first { $0.definition.name == "COMPOSIO_SEARCH_TOOLS" })
        let result = await search.run(arguments: .object(["queries": .array([.object(["use_case": .string("send an email")])])]))
        XCTAssertFalse(result.isError)
        let decodedResult = try JSONDecoder().decode(JSONValue.self, from: Data(result.content.utf8))
        XCTAssertEqual(decodedResult["resultType"]?.stringValue, "completed")
        XCTAssertNotNil(decodedResult["data"]?["tool_schemas"])
        XCTAssertFalse(decodedResult["data"]?["results"]?.arrayValue?.isEmpty ?? true)
        print("Live Swift: \(apps.count) matching apps, HTTPS authorization URL (not opened), \(tools.count) meta tools, \(prompt?.count ?? 0) guidance characters, real search tool schemas received.")
    }
}
