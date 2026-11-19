import XCTest
import AmbientContracts
@testable import AmbientBackground

final class BackgroundToolProviderTests: XCTestCase {
    private func provider(approval: @escaping BackgroundToolProvider.Approval) throws -> BackgroundToolProvider {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientToolsTests-\(UUID())")
        let suiteName = "AmbientBackgroundTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        return BackgroundToolProvider(manager: try BackgroundTaskManager(storageDirectory: directory.appendingPathComponent("tasks"), workspaceDirectory: directory.appendingPathComponent("workspaces")),
                                      approvalSettings: BackgroundApprovalSettings(defaults: defaults), approval: approval)
    }

    func testApprovalDenialDoesNotStartAnything() async throws {
        let prompts = ApprovalRecorder()
        let provider = try provider { title, detail in await prompts.record(title, detail); return false }
        let tools = await provider.tools()
        let arguments: [String: JSONValue] = [
            "spawn_agent": .object(["kind": .string("codex"), "prompt": .string("Do not run this"), "title": .string("Denied")]),
            "continue_agent": .object(["task_id": .string(UUID().uuidString), "message": .string("Do not resume")]),
            "run_shell_command": .object(["command": .string("exit 99")]),
            "run_applescript": .object(["source": .string("error \"should never run\"")])
        ]
        for tool in tools where arguments[tool.definition.name] != nil {
            let result = await tool.run(arguments: arguments[tool.definition.name]!)
            XCTAssertFalse(result.isError)
            XCTAssertTrue(result.content.contains("denied"))
        }
        let tasks = await provider.manager.tasks()
        XCTAssertTrue(tasks.isEmpty)
        let count = await prompts.count
        XCTAssertEqual(count, 4)
    }

    func testAllowWithoutAskingPersistsAndBypassesApproval() async throws {
        let provider = try provider { _, _ in XCTFail("Approval should be skipped"); return false }
        XCTAssertFalse(provider.approvalSettings.allowWithoutAsking)
        provider.approvalSettings.allowWithoutAsking = true
        XCTAssertTrue(provider.approvalSettings.allowWithoutAsking)
        let tools = await provider.tools()
        let shell = try XCTUnwrap(tools.first { $0.definition.name == "run_shell_command" })
        let result = await shell.run(arguments: .object(["command": .string("printf ok")]))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.hasPrefix("ok"))
        XCTAssertTrue(result.content.contains("Exit code: 0"))
    }

    func testApprovalSettingSurvivesNewAccessor() {
        let suiteName = "AmbientApprovalPersistence.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = BackgroundApprovalSettings(defaults: defaults)
        first.allowWithoutAsking = true
        let second = BackgroundApprovalSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(second.allowWithoutAsking)
        second.allowWithoutAsking = false
        XCTAssertFalse(first.allowWithoutAsking)
    }

    func testSchemasLabelsAndInvalidArguments() async throws {
        let provider = try provider { _, _ in XCTFail("Invalid arguments should not request approval"); return false }
        let tools = await provider.tools()
        XCTAssertEqual(tools.count, 11)
        for tool in tools {
            XCTAssertEqual(tool.definition.parametersJSONSchema["type"], .string("object"))
            XCTAssertEqual(tool.definition.parametersJSONSchema["additionalProperties"], .bool(false))
            XCTAssertNotNil(tool.activityLabel(arguments: .object([:])))
        }
        let shell = try XCTUnwrap(tools.first { $0.definition.name == "run_shell_command" })
        for arguments in [JSONValue.array([]), .object([:]), .object(["command": .number(3)]), .object(["command": .string("true"), "run_in_background": .string("yes")]), .object(["command": .string("true"), "extra": .bool(true)])] {
            let result = await shell.run(arguments: arguments)
            XCTAssertTrue(result.isError)
        }
        let spawn = try XCTUnwrap(tools.first { $0.definition.name == "spawn_agent" })
        let invalidKind = await spawn.run(arguments: .object(["kind": .string("other"), "prompt": .string("hello"), "title": .string("test")]))
        XCTAssertTrue(invalidKind.isError)
        let open = try XCTUnwrap(tools.first { $0.definition.name == "open_url" })
        XCTAssertEqual(open.definition.parametersJSONSchema["properties"]?["activate"]?["default"], .bool(false))
        let invalidURL = await open.run(arguments: .object(["url": .string("relative-path")]))
        XCTAssertTrue(invalidURL.isError)
    }

    func testToolsStartBackgroundCommandAndRetrieveResult() async throws {
        let provider = try provider { _, _ in true }
        let tools = await provider.tools()
        let shell = try XCTUnwrap(tools.first { $0.definition.name == "run_shell_command" })
        let started = await shell.run(arguments: .object(["command": .string("printf 'background ok'"), "run_in_background": .bool(true)]))
        XCTAssertFalse(started.isError)
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(started.content.utf8))
        let taskID = try XCTUnwrap(response["task_id"]?.stringValue)
        let id = try XCTUnwrap(UUID(uuidString: taskID))
        for _ in 0..<200 {
            if let task = await provider.manager.tasks().first(where: { $0.id == id }), task.status != .running { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let getResult = try XCTUnwrap(tools.first { $0.definition.name == "get_task_result" })
        let result = await getResult.run(arguments: .object(["task_id": .string(taskID)]))
        let final = try JSONDecoder().decode(JSONValue.self, from: Data(result.content.utf8))
        XCTAssertEqual(final["status"], .string("succeeded"))
        XCTAssertEqual(final["result"], .string("background ok"))
        XCTAssertTrue(final["transcript_tail"]?.stringValue?.contains("background ok") == true)
        let missing = await getResult.run(arguments: .object(["task_id": .string(UUID().uuidString)]))
        XCTAssertTrue(missing.isError)
    }

    func testAppleScriptRunsHeadlesslyAndReturnsOutput() async throws {
        let provider = try provider { _, _ in true }
        let tools = await provider.tools()
        let appleScript = try XCTUnwrap(tools.first { $0.definition.name == "run_applescript" })
        let result = await appleScript.run(arguments: .object(["source": .string("return \"ambient ok\"")]))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("ambient ok"))
    }
}

private actor ApprovalRecorder {
    var count = 0
    func record(_ title: String, _ detail: String) { count += 1 }
}
