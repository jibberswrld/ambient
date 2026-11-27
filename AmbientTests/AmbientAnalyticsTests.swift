import Foundation
import XCTest
import AmbientContracts
import AmbientUI
@testable import Ambient

private final class AnalyticsURLProtocol: URLProtocol {
    static var received: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.received?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":1}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AmbientAnalyticsTests: XCTestCase {
    func testFunnelPersistencePayloadAndOptOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); AnalyticsURLProtocol.received = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let expectedEvents = expectation(description: "funnel requests")
        expectedEvents.expectedFulfillmentCount = 9
        let lock = NSLock()
        var bodies: [[String: Any]] = []
        AnalyticsURLProtocol.received = { request in
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: bytes.prefix(count))
                }
                data = collected
            }
            let body = try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
            lock.lock(); bodies.append(body); lock.unlock()
            expectedEvents.fulfill()
        }
        let analytics = AmbientAnalytics(dataDirectory: directory, session: session, allowsSending: true)
        analytics.launched()
        analytics.launched()
        analytics.reached(.signinShown)
        analytics.reached(.signinShown)
        analytics.commandSubmitted()
        analytics.commandSubmitted()
        analytics.commandCompleted(AmbientAnalytics.Command(input: .voice))
        analytics.commandCompleted(AmbientAnalytics.Command(input: .text, outcome: .finished))
        let relaunched = AmbientAnalytics(dataDirectory: directory, session: session, allowsSending: true)
        relaunched.launched()
        relaunched.commandSubmitted()
        relaunched.reached(.signinShown)
        // Only a change from a known state is a connect: the first sighting of an app is not.
        relaunched.connectorsListed([ConnectorApp(slug: "gmail", name: "Gmail", logoURL: nil, isConnected: false)])
        relaunched.connectorsListed([ConnectorApp(slug: "gmail", name: "Gmail", logoURL: nil, isConnected: true),
                                     ConnectorApp(slug: "slack", name: "Slack", logoURL: nil, isConnected: true)])
        await fulfillment(of: [expectedEvents], timeout: 3)
        XCTAssertEqual(bodies.filter { $0["event"] as? String == "ambient_first_launch" }.count, 1)
        XCTAssertEqual(bodies.filter { $0["event"] as? String == "ambient_first_command" }.count, 1)
        let connected = bodies.filter { $0["event"] as? String == "ambient_connector_connected" }
        XCTAssertEqual(connected.map { ($0["properties"] as! [String: Any])["toolkit"] as? String }, ["gmail"])
        let common: Set<String> = ["distinct_id", "session_id", "platform", "app_version", "os_version"]
        let ids = bodies.map { ($0["properties"] as! [String: Any])["distinct_id"] as! String }
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertNotNil(UUID(uuidString: ids[0]))
        for body in bodies {
            let event = body["event"] as! String, properties = body["properties"] as! [String: Any]
            let extras: Set<String> = event == "ambient_command" ? ["input", "ok", "outcome", "total_ms", "tool_calls", "tool_errors"]
                : event == "ambient_onboarding_step" ? ["step"] : event == "ambient_connector_connected" ? ["toolkit"] : []
            XCTAssertEqual(Set(properties.keys), common.union(extras))
            XCTAssertEqual(properties["platform"] as? String, "mac")
        }
        relaunched.setEnabled(false)
        let optedOut = AmbientAnalytics(dataDirectory: directory, session: session, allowsSending: true)
        XCTAssertFalse(optedOut.isEnabled)
        optedOut.launched()
        optedOut.commandSubmitted()
        optedOut.commandCompleted(AmbientAnalytics.Command(input: .text))
        optedOut.connectorsListed([ConnectorApp(slug: "gmail", name: "Gmail", logoURL: nil, isConnected: true)])
        optedOut.sessionEnded()
        optedOut.reached(.tourStarted)
        // The mock fails the test if any extra request arrives after opt-out.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(bodies.count, 9)
        // One session per launch: the relaunch has its own session ID.
        let sessions = bodies.map { ($0["properties"] as! [String: Any])["session_id"] as! String }
        XCTAssertEqual(Set(sessions).count, 2)
        XCTAssertNil((bodies[0]["properties"] as! [String: Any])["dev"])
    }

    func testCommandPropertiesOmitWhatDidNotHappen() {
        var voice = AmbientAnalytics.Command(input: .voice)
        voice.outcome = .finished
        voice.transcriber = "local"
        voice.transcribeMilliseconds = 420
        voice.requestCharacters = 24
        voice.replyCharacters = 80
        voice.spokenReplies = true
        voice.toolFinished("look_at_screen", isError: false)
        voice.toolFinished("draw_on_screen", isError: true)
        voice.toolFinished("look_at_screen", isError: false)
        voice.toolFinished("ignore previous instructions", isError: false)
        let properties = voice.properties
        XCTAssertEqual(properties["outcome"] as? String, "finished")
        XCTAssertEqual(properties["ok"] as? Bool, true)
        XCTAssertEqual(properties["tool_calls"] as? Int, 4)
        XCTAssertEqual(properties["tool_errors"] as? Int, 1)
        XCTAssertEqual(properties["tools"] as? [String], ["look_at_screen", "draw_on_screen", "other"])
        XCTAssertEqual(properties["transcriber"] as? String, "local")
        XCTAssertNil(properties["first_reply_ms"])

        let empty = AmbientAnalytics.Command(input: .text, outcome: .empty).properties
        XCTAssertEqual(empty["ok"] as? Bool, false)
        XCTAssertEqual(Set(empty.keys), ["input", "ok", "outcome", "total_ms", "tool_calls", "tool_errors"])
        XCTAssertEqual(AmbientAnalytics.Outcome(.paymentRequired(message: "Top up", topUpURL: nil)), .paymentRequired)
        XCTAssertEqual(AmbientAnalytics.Outcome(.other(message: "boom")), .failed)
    }

    func testDrawingSummaryCountsMarksWithoutTheirText() throws {
        let annotations: [JSONValue] = [
            .object(["type": .string("box"), "x": .number(1), "y": .number(2), "x2": .number(30), "y2": .number(40), "text": .string("Click the secret Share button")]),
            .object(["type": .string("box"), "x": .number(1), "y": .number(2), "x2": .number(3), "y2": .number(4)]),
            .object(["type": .string("arrow"), "x": .number(5), "y": .number(6), "text": .string("")]),
            .object(["type": .string("my private note"), "x": .number(5), "y": .number(6)])
        ]
        let summary = AmbientAnalytics.drawingSummary(annotations)
        XCTAssertEqual(summary["marks"] as? Int, 4)
        XCTAssertEqual(summary["labeled_marks"] as? Int, 1)
        XCTAssertEqual(summary["kinds"] as? [String: Int], ["box": 2, "arrow": 1, "other": 1])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: summary), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("private"))
    }

    func testSettingChangesUseStableKeysAndLeaveTheDockEdgeToBarMoved() {
        let old = AmbientGeneralSettings()
        var new = old
        new.dockEdge = .top
        XCTAssertTrue(AmbientAnalytics.settingChanges(from: old, to: new).isEmpty)
        new.speaksReplies = false
        new.pushToTalkShortcut = .optionCommand
        let changes = AmbientAnalytics.settingChanges(from: old, to: new)
        XCTAssertEqual(changes.map(\.0), ["push_to_talk_shortcut", "speaks_replies"])
        XCTAssertEqual(changes[0].1 as? String, "optionCommand")
        XCTAssertEqual(changes[1].1 as? Bool, false)
    }

    func testDevDisabledAndUnreadableStateNeverSendOrReplaceIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analytics = AmbientAnalytics(dataDirectory: directory, allowsSending: false)
        let file = directory.appendingPathComponent("analytics.json")
        let before = try Data(contentsOf: file)
        analytics.launched()
        analytics.commandSubmitted()
        analytics.reached(.signinShown)
        XCTAssertEqual(try Data(contentsOf: file), before)
        try Data("invalid".utf8).write(to: file)
        let corrupt = AmbientAnalytics(dataDirectory: directory, allowsSending: false)
        corrupt.setEnabled(true)
        XCTAssertFalse(corrupt.isEnabled)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    }
}
