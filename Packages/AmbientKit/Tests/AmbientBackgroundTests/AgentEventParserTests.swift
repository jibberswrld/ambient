import XCTest
import AmbientContracts
@testable import AmbientBackground

final class AgentEventParserTests: XCTestCase {
    // Recorded from this Mac's installed CLIs on 2026-11-18. Usage and account/tool inventory omitted.
    func testRecordedCodexEvents() {
        let start = AgentEventParser.parse(#"{"type":"thread.started","thread_id":"01a1f15d-62fe-7f33-8408-14d5a32cca45"}"#, kind: .codexAgent)
        XCTAssertEqual(start.sessionID, "01a1f15d-62fe-7f33-8408-14d5a32cca45")
        let answer = AgentEventParser.parse(#"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"done"}}"#, kind: .codexAgent)
        XCTAssertEqual(answer.result, "done")
        XCTAssertEqual(answer.activity, "done")
        XCTAssertNil(AgentEventParser.parse(#"{"type":"turn.completed","usage":{"input_tokens":31051,"output_tokens":5}}"#, kind: .codexAgent).failure)
    }

    func testRecordedClaudeEvents() {
        let assistant = AgentEventParser.parse(#"{"type":"assistant","message":{"model":"claude-fable-5-2","role":"assistant","content":[{"type":"text","text":"done"}]},"session_id":"e4cd7206-656e-4110-9b40-a45d60bcc6ce","parent_tool_use_id":null}"#, kind: .claudeAgent)
        XCTAssertEqual(assistant.transcript, "done")
        XCTAssertNil(assistant.result)
        let result = AgentEventParser.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"e4cd7206-656e-4110-9b40-a45d60bcc6ce"}"#, kind: .claudeAgent)
        XCTAssertEqual(result.result, "done")
        XCTAssertEqual(result.sessionID, "e4cd7206-656e-4110-9b40-a45d60bcc6ce")
        XCTAssertNil(result.failure)
    }

    func testCodexCommandAndFileProgress() {
        let command = AgentEventParser.parse(#"{"type":"item.completed","item":{"type":"command_execution","command":"swift test\n--filter Example","aggregated_output":"passed\n","exit_code":0}}"#, kind: .codexAgent)
        XCTAssertEqual(command.activity, "Running: swift test --filter Example")
        XCTAssertTrue(command.transcript?.contains("passed") == true)
        let edit = AgentEventParser.parse(#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"hello.txt","kind":"add"}]}}"#, kind: .codexAgent)
        XCTAssertEqual(edit.activity, "Editing hello.txt")
    }

    func testClaudeToolActivityAndOutput() {
        let tool = AgentEventParser.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"hello.txt","content":"ok"}}]}}"#, kind: .claudeAgent)
        XCTAssertEqual(tool.activity, "Write: hello.txt")
        let output = AgentEventParser.parse(#"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"File created"}]}]}}"#, kind: .claudeAgent)
        XCTAssertEqual(output.transcript, "File created")
    }

    func testFailuresAndUnrecognizedOutput() {
        XCTAssertEqual(AgentEventParser.parse(#"{"type":"turn.failed","error":{"message":"Authentication required"}}"#, kind: .codexAgent).failure, "Authentication required")
        XCTAssertEqual(AgentEventParser.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Not logged in"]}"#, kind: .claudeAgent).failure, "Not logged in")
        XCTAssertEqual(AgentEventParser.parse("fatal: CLI missing", kind: .codexAgent).transcript, "fatal: CLI missing")
        XCTAssertNil(AgentEventParser.parse(#"{"type":"future_event"}"#, kind: .codexAgent).failure)
        XCTAssertEqual(AgentEventParser.parse(#"{"type":"item.completed","item":{"type":"error","message":"Configuration warning"}}"#, kind: .codexAgent).transcript, "Configuration warning")
        XCTAssertEqual(AgentEventParser.singleLine("  editing\n\tfile  "), "editing file")
    }
}
