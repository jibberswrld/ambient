import Foundation
import XCTest
import AmbientContracts
@testable import AmbientMemory

private actor LivePublikTextCompletionService: TextCompletionService {
    var diagnostic = "No completion received."
    func complete(systemPrompt: String, userPrompt: String, tier: ModelTier) async throws -> String {
        guard let apiKey = ProcessInfo.processInfo.environment["PUBLIK_API_KEY"], !apiKey.isEmpty else {
            throw AmbientMemoryError.invalidInput("The live test requires PUBLIK_API_KEY in its process environment.")
        }
        var request = URLRequest(url: URL(string: "https://publikhq.com/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "publik-fast",
            "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": userPrompt]],
            "temperature": 0,
            "max_tokens": 600
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        diagnostic = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            // Never include response/request bodies or credentials in failures.
            throw AmbientMemoryError.invalidInput("The live completion request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else {
            throw AmbientMemoryError.invalidInput("The live response had no text choice.")
        }
        diagnostic = "Completion: " + content.replacingOccurrences(of: apiKey, with: "[redacted]")
        return content
    }
}

final class LiveLearningTests: XCTestCase {
    func testAmbientMemoryTestsLiveLearning() async throws {
        guard ProcessInfo.processInfo.environment["AMBIENT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set AMBIENT_LIVE_TESTS=1 and PUBLIK_API_KEY to run the paid live learning check.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientLiveLearning-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let completionService = LivePublikTextCompletionService()
        let store = try PersistentMemoryStore(directory: directory, completionService: completionService)

        await store.learn(fromUserText: "For future chats, I prefer short replies without an introductory preamble.", assistantText: "Understood. I'll keep replies short and direct.")
        await store.finishPendingLearning()
        let first = await store.items()
        let diagnostic = await completionService.diagnostic
        XCTAssertEqual(first.count, 1, "A clear durable preference should be learned. \(diagnostic)")
        let preferenceID = try XCTUnwrap(first.first?.id)

        await store.learn(fromUserText: "What is 19 times 7? I just need it for this calculation.", assistantText: "133. You are probably an accountant.")
        await store.finishPendingLearning()
        let afterCalculation = await store.items()
        XCTAssertEqual(afterCalculation, first, "One-off math and assistant speculation should not become memories.")

        await store.learn(fromUserText: "Thanks! For this one task, remind me to buy bananas at 3 PM. The temporary password in this example is not-a-real-credential; do not keep it.", assistantText: "I can help with that task.")
        await store.finishPendingLearning()
        let afterChatter = await store.items()
        XCTAssertEqual(afterChatter, first, "Chatter, temporary details and credentials should be discarded.")

        await store.learn(fromUserText: "Correction: I no longer prefer short replies. In general I prefer detailed explanations with a brief summary first.", assistantText: "I'll use a short summary followed by detail.")
        await store.finishPendingLearning()
        let afterCorrection = await store.items()
        XCTAssertEqual(afterCorrection.count, 1, "The new preference should replace the old preference.")
        XCTAssertEqual(afterCorrection.first?.id, preferenceID, "Corrections should rewrite an existing memory.")
        XCTAssertTrue(afterCorrection.first?.text.localizedCaseInsensitiveContains("summary") == true)
        XCTAssertTrue(afterCorrection.first?.text.localizedCaseInsensitiveContains("detail") == true)

        await store.learn(fromUserText: "My ongoing side project Harbor lives at ~/Projects/Harbor. That's the repo to use when I ask about Harbor.", assistantText: "I'll use that path for Harbor.")
        await store.finishPendingLearning()
        let final = await store.items()
        XCTAssertTrue(final.contains { $0.text.contains("~/Projects/Harbor") })
        XCTAssertTrue((2...3).contains(final.count), "Only the durable preference and project facts should remain.")
        XCTAssertFalse(final.contains { $0.text.localizedCaseInsensitiveContains("banana") || $0.text.contains("133") || $0.text.contains("not-a-real-credential") || $0.text.localizedCaseInsensitiveContains("accountant") })
        // The fixtures contain no real personal data or credentials; this makes instruction behavior inspectable.
        print("Live learning kept: \(final.map(\.text).joined(separator: " | "))")
        print("Live learning discarded: one-off calculation, assistant speculation, chatter, temporary reminder and example credential; rewrote the superseded reply preference.")
    }
}
