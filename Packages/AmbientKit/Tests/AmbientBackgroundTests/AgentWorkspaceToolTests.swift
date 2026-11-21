import XCTest
import AmbientContracts
@testable import AmbientBackground

final class AgentWorkspaceToolTests: XCTestCase {
    func testShellWritesInsideTheWorkingDirectoryAndNowhereElseInHome() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let workingDirectory = home.appendingPathComponent("Library/Application Support/Ambient/workspaces/test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let outsideFile = home.appendingPathComponent("ambient-agent-escape-\(UUID().uuidString).txt")
        let tool = AgentShellTool(workingDirectory: workingDirectory)

        let inside = await tool.run(arguments: .object(["command": .string("echo ok > note.txt && cat note.txt")]))
        XCTAssertFalse(inside.isError, inside.content)
        XCTAssertTrue(inside.content.hasPrefix("ok"))

        let outside = await tool.run(arguments: .object(["command": .string("echo no > '\(outsideFile.path)'")]))
        XCTAssertTrue(outside.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}
