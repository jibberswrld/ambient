import Foundation
import XCTest
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
        expectedEvents.expectedFulfillmentCount = 8
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
        analytics.commandCompleted(input: .voice, ok: false)
        analytics.commandCompleted(input: .text, ok: true)
        let relaunched = AmbientAnalytics(dataDirectory: directory, session: session, allowsSending: true)
        relaunched.launched()
        relaunched.commandSubmitted()
        relaunched.reached(.signinShown)
        await fulfillment(of: [expectedEvents], timeout: 3)
        XCTAssertEqual(bodies.filter { $0["event"] as? String == "ambient_first_launch" }.count, 1)
        XCTAssertEqual(bodies.filter { $0["event"] as? String == "ambient_first_command" }.count, 1)
        let common: Set<String> = ["distinct_id", "platform", "app_version", "os_version"]
        let ids = bodies.map { ($0["properties"] as! [String: Any])["distinct_id"] as! String }
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertNotNil(UUID(uuidString: ids[0]))
        for body in bodies {
            let event = body["event"] as! String, properties = body["properties"] as! [String: Any]
            let extras: Set<String> = event == "ambient_command" ? ["input", "ok"] : event == "ambient_onboarding_step" ? ["step"] : []
            XCTAssertEqual(Set(properties.keys), common.union(extras))
            XCTAssertEqual(properties["platform"] as? String, "mac")
        }
        relaunched.setEnabled(false)
        let optedOut = AmbientAnalytics(dataDirectory: directory, session: session, allowsSending: true)
        XCTAssertFalse(optedOut.isEnabled)
        optedOut.launched()
        optedOut.commandSubmitted()
        optedOut.commandCompleted(input: .text, ok: true)
        optedOut.reached(.tourStarted)
        // The mock fails the test if any extra request arrives after opt-out.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(bodies.count, 8)
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
