import XCTest
@testable import AmbientAgent
import AmbientContracts

private struct FixedCredentialSource: AICredentialSource {
    var value: AICredential? = AICredential(baseURL: URL(string: "https://ambient.invalid/api/v1")!, apiKey: UUID().uuidString)
    func credential() async -> AICredential? { value }
}
private final class StubURLProtocol: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data]
        var hangs = false
    }
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> Response)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let response = try XCTUnwrap(handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
            for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
            if !response.hangs { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.lock.lock(); let stopped = Self.stopped; Self.lock.unlock(); stopped?() }
    static func install(_ handler: @escaping (URLRequest) throws -> Response, stopped: (() -> Void)? = nil) {
        lock.lock(); self.handler = handler; self.stopped = stopped; lock.unlock()
    }
}
private func requestData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }; result.append(buffer, count: count)
    }
    return result
}
private func requestJSON(_ request: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: requestData(request)) }
private func event(_ delta: [String: Any], finish: String? = nil) -> String {
    var choice: [String: Any] = ["index": 0, "delta": delta]
    if let finish { choice["finish_reason"] = finish }
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]], options: [.sortedKeys])
    return "data: " + String(decoding: data, as: UTF8.self) + "\r\n\r\n"
}
private func toolEvent(names: [String], arguments: [String]? = nil) -> String {
    event(["tool_calls": names.enumerated().map { index, name in
        ["index": index, "id": "call_\(index)", "type": "function", "function": ["name": name, "arguments": arguments?[index] ?? "{}"]] as [String: Any]
    }], finish: "tool_calls")
}
private func streamResponse(_ text: String) -> StubURLProtocol.Response {
    let bytes = Data((text + "data: [DONE]\r\n\r\n").utf8)
    // Split within UTF-8, CRLF, and JSON to exercise real transport fragmentation.
    return .init(chunks: stride(from: 0, to: bytes.count, by: 7).map { bytes.subdata(in: $0..<min($0 + 7, bytes.count)) })
}
private struct TestTool: AmbientTool {
    var name = "echo_tool"
    var operation: @Sendable (JSONValue) async -> ToolResult = { ToolResult(content: $0["value"]?.stringValue ?? "ok") }
    var definition: ToolDefinition { ToolDefinition(name: name, description: "Return the supplied value.", parametersJSONSchema: .object(["type": .string("object"), "properties": .object(["value": .object(["type": .string("string")])])])) }
    func activityLabel(arguments: JSONValue) -> String? { name == "echo_tool" ? "Echoing value" : nil }
    func run(arguments: JSONValue) async -> ToolResult { await operation(arguments) }
}
private actor TestProvider: ToolProvider {
    var suppliedTools: [any AmbientTool]
    var calls = 0
    init(_ tools: [any AmbientTool]) { suppliedTools = tools }
    func tools() async -> [any AmbientTool] { calls += 1; return suppliedTools }
    func systemPromptSection() async -> String? { "Provider instructions." }
}
private actor ExecutionTracker {
    var running = 0
    var maximum = 0
    func start() { running += 1; maximum = max(maximum, running) }
    func end() { running -= 1 }
}
private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []; for await event in stream { events.append(event) }; return events
}
private func finalText(_ events: [AgentEvent]) -> String? {
    for event in events { if case .finished(let text) = event { return text } }; return nil
}
private func failure(_ events: [AgentEvent]) -> AgentFailure? {
    for event in events { if case .failed(let failure) = event { return failure } }; return nil
}

final class AmbientAgentTests: XCTestCase {
    private var urlSession: URLSession!
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
    }
    override func tearDown() { urlSession.invalidateAndCancel(); super.tearDown() }
    private func session(providers: [any ToolProvider] = []) -> AmbientAgentSession {
        AmbientAgentSession(credentialSource: FixedCredentialSource(), toolProviders: providers, tier: .fast, urlSession: urlSession)
    }
    func testModuleIdentityAndProviderOverride() async {
        XCTAssertEqual(Publik.appSlug, "ambient"); XCTAssertEqual(Publik.appVersion, "0.1.3")
        let generatedTestKey = UUID().uuidString
        let source = PublikCredentialSource(userCredential: .init(baseURL: URL(string: "https://own.invalid/v1")!, apiKey: generatedTestKey))
        let credential = await source.credential()
        // On a Mac that is signed in to Ambient, the stored publik install key wins over the user's own key.
        // Compared without XCTAssertEqual so a failure can never print a real key.
        let acceptableKeys = [ProcessInfo.processInfo.environment["PUBLIK_API_KEY"], Publik.readCredential()?.key, generatedTestKey].compactMap { $0 }
        XCTAssertTrue(credential.map { acceptableKeys.contains($0.apiKey) } ?? false, "The credential source returned a key from none of its three sources.")
    }
    func testSSEFragmentedArgumentsAndMultipleRounds() async {
        let provider = TestProvider([TestTool()]); var count = 0
        StubURLProtocol.install { request in
            count += 1; let body = try requestJSON(request)
            XCTAssertEqual(body["model"]?.stringValue, "publik-fast")
            XCTAssertTrue(body["messages"]?.arrayValue?.first?["content"]?.stringValue?.contains("Provider instructions.") == true)
            if count == 1 {
                return streamResponse(": keepalive\r\n\r\n" + event(["content": "Checking… ", "tool_calls": [["index": 0, "id": "call_0", "function": ["name": "echo_tool", "arguments": "{\"val"]]]]) + event(["tool_calls": [["index": 0, "function": ["arguments": "ue\":\"hello\"}"]]]], finish: "tool_calls"))
            }
            let messages = try XCTUnwrap(body["messages"]?.arrayValue)
            XCTAssertEqual(messages.last?["role"]?.stringValue, "tool")
            XCTAssertEqual(messages.last?["content"]?.stringValue, "hello")
            return streamResponse(event(["content": "Done."], finish: "stop"))
        }
        let events = await collect(session(providers: [provider]).send(.init(text: "Use the tool")))
        XCTAssertEqual(finalText(events), "Checking… \n\nDone."); XCTAssertEqual(count, 2); XCTAssertNil(failure(events))
        XCTAssertTrue(events.contains { if case .toolStarted(_, "echo_tool", "Echoing value") = $0 { return true }; return false })
    }
    func testParallelToolsAndResultImagesFollowAllToolMessages() async {
        let tracker = ExecutionTracker()
        let tool = TestTool(operation: { _ in
            await tracker.start(); try? await Task.sleep(nanoseconds: 40_000_000); await tracker.end()
            return ToolResult(content: "screenshot", images: [.init(data: Data([1, 2, 3]), mimeType: "image/png", label: "Screen")])
        })
        var count = 0
        StubURLProtocol.install { request in
            count += 1
            if count == 1 { return streamResponse(toolEvent(names: ["echo_tool", "echo_tool"])) }
            let messages = try XCTUnwrap(try requestJSON(request)["messages"]?.arrayValue)
            XCTAssertEqual(messages.suffix(3).compactMap { $0["role"]?.stringValue }, ["tool", "tool", "user"])
            let images = messages.last?["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "image_url" }
            XCTAssertEqual(images?.count, 2)
            XCTAssertEqual(images?.first?["image_url"]?["url"]?.stringValue, "data:image/png;base64,AQID")
            return streamResponse(event(["content": "I see it."], finish: "stop"))
        }
        let events = await collect(session(providers: [TestProvider([tool])]).send(.init(text: "Look twice")))
        XCTAssertEqual(finalText(events), "I see it.")
        let maximum = await tracker.maximum; XCTAssertEqual(maximum, 2)
    }
    func testUnknownToolsAndMalformedArgumentsBecomeReadableErrors() async {
        var count = 0
        StubURLProtocol.install { request in
            count += 1
            if count == 1 { return streamResponse(toolEvent(names: ["missing_tool", "echo_tool"], arguments: ["{}", "{bad"])) }
            let messages = try XCTUnwrap(try requestJSON(request)["messages"]?.arrayValue)
            XCTAssertTrue(messages[messages.count - 2]["content"]?.stringValue?.contains("Unknown tool") == true)
            XCTAssertTrue(messages.last?["content"]?.stringValue?.contains("Invalid arguments") == true)
            return streamResponse(event(["content": "Those calls failed."], finish: "stop"))
        }
        let events = await collect(session(providers: [TestProvider([TestTool()])]).send(.init(text: "Try")))
        XCTAssertEqual(finalText(events), "Those calls failed.")
        XCTAssertEqual(events.filter { if case .toolFinished(_, _, true) = $0 { return true }; return false }.count, 2)
    }
    func testPaymentRequiredAndNotSignedInMapping() async {
        for status in [402, 401] {
            StubURLProtocol.install { _ in .init(status: status, chunks: [Data("{\"error\":{\"message\":\"Top up first\",\"top_up_url\":\"https://publikhq.com/wallet\"}}".utf8)]) }
            let events = await collect(session().send(.init(text: "Hello")))
            let expected: AgentFailure = status == 401 ? .notSignedIn : .paymentRequired(message: "Top up first", topUpURL: URL(string: "https://publikhq.com/wallet"))
            XCTAssertEqual(failure(events), expected)
        }
    }
    func testMissingCredentialMakesNoNetworkRequest() async {
        StubURLProtocol.install { _ in XCTFail("No request should be sent"); return streamResponse("") }
        let agent = AmbientAgentSession(credentialSource: FixedCredentialSource(value: nil), toolProviders: [], urlSession: urlSession)
        let events = await collect(agent.send(.init(text: "Hello"))); XCTAssertEqual(failure(events), .notSignedIn)
    }
    func testRetryAfterIsBoundedAndHonoured() async {
        var count = 0
        StubURLProtocol.install { _ in count += 1; return .init(status: 429, headers: ["Retry-After": "0"], chunks: [Data("{}".utf8)]) }
        let events = await collect(session().send(.init(text: "Hello"))); XCTAssertEqual(count, 3); XCTAssertNotNil(failure(events))
        count = 0
        StubURLProtocol.install { _ in count += 1; return .init(status: 429, headers: ["Retry-After": "3600"], chunks: [Data("{}".utf8)]) }
        _ = await collect(session().send(.init(text: "Hello"))); XCTAssertEqual(count, 1)
    }
    func testCancellationStopsRequestAndTerminatesStream() async {
        let started = expectation(description: "Request began"), stopped = expectation(description: "Request cancelled")
        StubURLProtocol.install({ _ in started.fulfill(); return .init(chunks: [], hangs: true) }, stopped: { stopped.fulfill() })
        let agent = session()
        let running = Task { await collect(agent.send(.init(text: "Wait"))) }
        await fulfillment(of: [started], timeout: 2); await agent.cancel()
        let events = await running.value; XCTAssertEqual(failure(events), .cancelled)
        await fulfillment(of: [stopped], timeout: 2)
    }
    func testCancellationStopsRunningTools() async {
        let started = expectation(description: "Tool began"), cancelled = expectation(description: "Tool cancelled")
        let tool = TestTool(operation: { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled.fulfill() }
            return ToolResult(content: "cancelled", isError: true)
        })
        StubURLProtocol.install { _ in streamResponse(toolEvent(names: ["echo_tool"])) }
        let agent = session(providers: [TestProvider([tool])]); let task = Task { await collect(agent.send(.init(text: "Wait"))) }
        await fulfillment(of: [started], timeout: 2); await agent.cancel()
        let events = await task.value; XCTAssertEqual(failure(events), .cancelled)
        await fulfillment(of: [cancelled], timeout: 2)
    }
    func testOldImagesRemovedProvidersRefreshedAndResetClearsHistory() async {
        var bodies: [JSONValue] = []
        StubURLProtocol.install { request in bodies.append(try requestJSON(request)); return streamResponse(event(["content": "Done"], finish: "stop")) }
        let provider = TestProvider([])
        let refreshedAgent = session(providers: [provider])
        _ = await collect(refreshedAgent.send(.init(text: "First", images: [.init(data: Data([1]), mimeType: "image/jpeg", label: "Screenshot")])))
        _ = await collect(refreshedAgent.send(.init(text: "Second")))
        XCTAssertNotNil(bodies[0]["messages"]?.arrayValue?[1]["content"]?.arrayValue)
        XCTAssertNil(bodies[1]["messages"]?.arrayValue?[1]["content"]?.arrayValue)
        let calls = await provider.calls; XCTAssertEqual(calls, 2)
        await refreshedAgent.reset(); _ = await collect(refreshedAgent.send(.init(text: "Third")))
        XCTAssertEqual(bodies[2]["messages"]?.arrayValue?.count, 2)
    }
    func testHistoryTrimsOldestWholeTurnsBeforeFourMegabytes() async {
        var bodies: [JSONValue] = []
        StubURLProtocol.install { request in
            let bytes = requestData(request); XCTAssertLessThan(bytes.count, 4_000_000)
            bodies.append(try JSONDecoder().decode(JSONValue.self, from: bytes))
            return streamResponse(event(["content": "Done"], finish: "stop"))
        }
        let agent = session()
        _ = await collect(agent.send(.init(text: "Oldest " + String(repeating: "a", count: 1_500_000))))
        _ = await collect(agent.send(.init(text: "Middle " + String(repeating: "b", count: 1_500_000))))
        let events = await collect(agent.send(.init(text: "Newest " + String(repeating: "c", count: 1_500_000))))
        XCTAssertNotNil(finalText(events))
        let messages = bodies.last?["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.count, 4)
        XCTAssertTrue(messages[1]["content"]?.stringValue?.hasPrefix("Middle") == true)
        XCTAssertTrue(messages.last?["content"]?.stringValue?.hasPrefix("Newest") == true)
    }
    func testOversizedNewestTurnRejectedWithoutNetwork() async {
        StubURLProtocol.install { _ in XCTFail("Oversized payload sent"); return streamResponse("") }
        let events = await collect(session().send(.init(text: "Large image", images: [.init(data: Data(repeating: 1, count: 3_000_000), mimeType: "image/jpeg", label: "Large")])))
        XCTAssertNotNil(failure(events))
    }
    func testToolRoundLimitAndFailedTurnsDoNotPoisonHistory() async {
        var count = 0
        StubURLProtocol.install { _ in count += 1; return streamResponse(toolEvent(names: ["echo_tool"])) }
        let agent = session(providers: [TestProvider([TestTool()])]); let events = await collect(agent.send(.init(text: "Loop")))
        XCTAssertEqual(count, 32); XCTAssertNotNil(failure(events))
        StubURLProtocol.install { request in
            XCTAssertEqual(try requestJSON(request)["messages"]?.arrayValue?.count, 2)
            return streamResponse(event(["content": "Recovered"], finish: "stop"))
        }
        let recovered = await collect(agent.send(.init(text: "Hello"))); XCTAssertEqual(finalText(recovered), "Recovered")
    }
    func testTruncatedStreamFailsInsteadOfClaimingSuccess() async {
        StubURLProtocol.install { _ in .init(chunks: [Data(event(["content": "Partial"]).utf8)]) }
        let events = await collect(session().send(.init(text: "Hello"))); XCTAssertNil(finalText(events)); XCTAssertNotNil(failure(events))
    }
    func testNonStreamingCompletionAndHTTPMapping() async throws {
        StubURLProtocol.install { request in
            let body = try requestJSON(request); XCTAssertEqual(body["stream"]?.boolValue, false); XCTAssertNil(body["tools"])
            return .init(chunks: [Data("{\"choices\":[{\"message\":{\"content\":\"A title\"}}]}".utf8)])
        }
        let client = PublikAIClient(credentialSource: FixedCredentialSource(), urlSession: urlSession)
        let text = try await client.complete(systemPrompt: "Title", userPrompt: "A chat", tier: .balanced); XCTAssertEqual(text, "A title")
        StubURLProtocol.install { _ in .init(status: 401, chunks: [Data("{}".utf8)]) }
        do { _ = try await client.complete(systemPrompt: "", userPrompt: "", tier: .fast); XCTFail("Expected 401") }
        catch { XCTAssertEqual(error as? AgentFailure, .notSignedIn) }
    }
    func testSearchToolAndSpeechPayloads() async throws {
        var routes: [String] = []; let wav = Data("RIFFxxxxWAVEaudio".utf8)
        StubURLProtocol.install { request in
            let path = request.url!.path; routes.append(path)
            if path.hasSuffix("/search") {
                XCTAssertEqual(try requestJSON(request)["q"]?.stringValue, "Swift")
                return .init(chunks: [Data("{\"results\":[{\"url\":\"https://swift.org\",\"title\":\"Swift\",\"snippet\":\"Language\",\"site\":\"swift.org\"}]}".utf8)])
            }
            if path.hasSuffix("/speech") {
                let body = try requestJSON(request); XCTAssertEqual(body["model"]?.stringValue, "tts-1"); XCTAssertEqual(body["voice"]?.stringValue, "coral"); XCTAssertEqual(body["response_format"]?.stringValue, "wav")
                return .init(chunks: [wav])
            }
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            let body = requestData(request); XCTAssertNotNil(body.range(of: wav)); XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("gpt-4o-mini-transcribe"))
            return .init(chunks: [Data("{\"text\":\"Ambient ready\"}".utf8)])
        }
        let search = PublikWebSearchProvider(credentialSource: FixedCredentialSource(), urlSession: urlSession), tools = await search.tools()
        let result = await tools[0].run(arguments: .object(["q": .string("Swift")]))
        XCTAssertFalse(result.isError); XCTAssertTrue(result.content.contains("swift.org"))
        let speech = PublikSpeechClient(credentialSource: FixedCredentialSource(), urlSession: urlSession)
        let audio = try await speech.synthesize(text: "Ambient ready"), transcript = try await speech.transcribe(wavData: audio)
        XCTAssertEqual(transcript, "Ambient ready"); XCTAssertEqual(routes, ["/api/v1/search", "/api/v1/audio/speech", "/api/v1/audio/transcriptions"])
    }
    func testTextArrivesBeforeConnectionCloses() async {
        let receivedText = expectation(description: "Text streamed while connection remained open")
        StubURLProtocol.install { _ in .init(chunks: [Data(event(["content": "Already streaming"]).utf8)], hangs: true) }
        let agent = session()
        let task = Task {
            var events: [AgentEvent] = []
            for await event in agent.send(.init(text: "Stream now")) {
                if case .textDelta(let text) = event { XCTAssertEqual(text, "Already streaming"); receivedText.fulfill() }
                events.append(event)
            }
            return events
        }
        await fulfillment(of: [receivedText], timeout: 2)
        await agent.cancel()
        let events = await task.value
        XCTAssertEqual(failure(events), .cancelled)
    }

    func testInterleavedToolArgumentFragmentsPreserveCallOrder() async {
        var count = 0
        StubURLProtocol.install { request in
            count += 1
            if count == 1 {
                return streamResponse(event(["tool_calls": [
                    ["index": 1, "id": "second", "function": ["name": "echo_tool", "arguments": "{\"value\":"]],
                    ["index": 0, "id": "first", "function": ["name": "echo_tool", "arguments": "{\"value\":"]]
                ]]) + event(["tool_calls": [
                    ["index": 0, "function": ["arguments": "\"one\"}"]],
                    ["index": 1, "function": ["arguments": "\"two\"}"]]
                ]], finish: "tool_calls"))
            }
            let replies = try XCTUnwrap(try requestJSON(request)["messages"]?.arrayValue).suffix(2)
            XCTAssertEqual(replies.compactMap { $0["tool_call_id"]?.stringValue }, ["first", "second"])
            XCTAssertEqual(replies.compactMap { $0["content"]?.stringValue }, ["one", "two"])
            return streamResponse(event(["content": "Both complete"], finish: "stop"))
        }
        let events = await collect(session(providers: [TestProvider([TestTool()])]).send(.init(text: "Run both")))
        XCTAssertEqual(finalText(events), "Both complete")
    }

    func testRetryAfterDelayBeforeSuccessfulRetry() async {
        var count = 0
        var firstRequestTime: TimeInterval = 0
        StubURLProtocol.install { _ in
            count += 1
            if count == 1 {
                firstRequestTime = ProcessInfo.processInfo.systemUptime
                return .init(status: 429, headers: ["Retry-After": "0.03"], chunks: [Data("{}".utf8)])
            }
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - firstRequestTime, 0.025)
            return streamResponse(event(["content": "Retried"], finish: "stop"))
        }
        let events = await collect(session().send(.init(text: "Retry")))
        XCTAssertEqual(finalText(events), "Retried")
        XCTAssertEqual(count, 2)
    }

    func testNewTurnCancelsPreviousTurnWithoutLeakingHistory() async {
        let began = expectation(description: "First turn began")
        var count = 0
        StubURLProtocol.install { request in
            count += 1
            if count == 1 { began.fulfill(); return .init(chunks: [], hangs: true) }
            let messages = try XCTUnwrap(try requestJSON(request)["messages"]?.arrayValue)
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.last?["content"]?.stringValue, "Second")
            return streamResponse(event(["content": "Second finished"], finish: "stop"))
        }
        let agent = session()
        let first = Task { await collect(agent.send(.init(text: "First"))) }
        await fulfillment(of: [began], timeout: 2)
        let second = await collect(agent.send(.init(text: "Second")))
        let firstEvents = await first.value
        XCTAssertEqual(failure(firstEvents), .cancelled)
        XCTAssertEqual(finalText(second), "Second finished")
    }

    func testSearchErrorsAreReadableAndInvalidCountDoesNotSend() async {
        let provider = PublikWebSearchProvider(credentialSource: FixedCredentialSource(), urlSession: urlSession)
        let tool = await provider.tools()[0]
        StubURLProtocol.install { _ in XCTFail("Invalid count reached the network"); return .init(chunks: []) }
        let invalid = await tool.run(arguments: .object(["q": .string("Swift"), "count": .string("bad")]))
        XCTAssertTrue(invalid.isError)
        for status in [401, 402] {
            StubURLProtocol.install { _ in .init(status: status, chunks: [Data("{\"error\":{\"message\":\"Top up first\",\"top_up_url\":\"https://publikhq.com/wallet\"}}".utf8)]) }
            let result = await tool.run(arguments: .object(["q": .string("Swift")]))
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.content.contains(status == 401 ? "Sign in" : "https://publikhq.com/wallet"))
        }
    }

    func testLivePublikRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["AMBIENT_LIVE_TESTS"] == "1" else { throw XCTSkip("Set AMBIENT_LIVE_TESTS=1 to spend real publik credits.") }
        let source = PublikCredentialSource()
        guard await source.credential() != nil else { XCTFail("The live test needs PUBLIK_API_KEY."); return }
        let direct = AmbientAgentSession(credentialSource: source, toolProviders: [], tier: .fast)
        let directEvents = await collect(direct.send(.init(text: "Reply with exactly: Ambient ready")))
        XCTAssertNil(failure(directEvents)); XCTAssertTrue(finalText(directEvents)?.contains("Ambient ready") == true)
        XCTAssertTrue(directEvents.contains { if case .textDelta(let text) = $0 { return !text.isEmpty }; return false })
        let toolAgent = AmbientAgentSession(credentialSource: source, toolProviders: [TestProvider([TestTool()])], baseSystemPrompt: "Call echo_tool once with value AMBIENT_TOOL_OK, then report the returned value. Always call the tool before answering.", tier: .fast)
        let toolEvents = await collect(toolAgent.send(.init(text: "Run the required echo check.")))
        XCTAssertNil(failure(toolEvents)); XCTAssertTrue(toolEvents.contains { if case .toolFinished(_, "echo_tool", false) = $0 { return true }; return false })
        XCTAssertTrue(finalText(toolEvents)?.contains("AMBIENT_TOOL_OK") == true)
        let results = try await PublikWebSearchProvider(credentialSource: source).search(query: "Swift programming language official", count: 1)
        XCTAssertFalse(results.isEmpty); XCTAssertTrue(results.first?.url.hasPrefix("https://") == true)
        let speech = PublikSpeechClient(credentialSource: source), audio = try await speech.synthesize(text: "Ambient is ready.")
        XCTAssertGreaterThan(audio.count, 44)
        let transcript = try await speech.transcribe(wavData: audio)
        XCTAssertTrue(transcript.lowercased().contains("ambient"), "Unexpected transcription: \(transcript)")
        print("Ambient live checks: streamed reply, tool round trip, search, WAV synthesis (\(audio.count) bytes), and transcription passed.")
    }
}
