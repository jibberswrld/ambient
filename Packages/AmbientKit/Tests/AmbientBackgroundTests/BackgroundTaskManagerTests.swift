import XCTest
import AmbientContracts
@testable import AmbientBackground

final class BackgroundTaskManagerTests: XCTestCase {
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientBackgroundTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func manager(in directory: URL) throws -> BackgroundTaskManager {
        try BackgroundTaskManager(storageDirectory: directory.appendingPathComponent("tasks"), workspaceDirectory: directory.appendingPathComponent("workspaces"))
    }

    private func waitUntilFinished(_ manager: BackgroundTaskManager, taskID: UUID) async throws -> BackgroundTask {
        for _ in 0..<250 {
            if let task = await manager.tasks().first(where: { $0.id == taskID }), task.status != .running { return task }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await manager.cancel(taskID: taskID)
        throw BackgroundExecutionError.message("Test task did not finish in five seconds.")
    }

    func testLifecycleUpdatesPersistenceAndDismissal() async throws {
        let directory = try scratchDirectory()
        let manager = try manager(in: directory)
        var updates = manager.updates().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial, [])
        var completions = await manager.completions().makeAsyncIterator()
        let task = try await manager.runShellCommand(command: "printf 'hello\\n'; /bin/sleep 0.1; printf 'done\\n'", workingDirectory: directory.path)
        let running = await updates.next()
        XCTAssertEqual(running?.first?.id, task.id)
        XCTAssertEqual(running?.first?.status, .running)
        let finished = try await waitUntilFinished(manager, taskID: task.id)
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertEqual(finished.result, "hello\ndone\n")
        XCTAssertNotNil(finished.finishedAt)
        let notification = await completions.next()
        XCTAssertEqual(notification?.id, task.id)
        let transcript = await manager.transcript(taskID: task.id)
        XCTAssertTrue(transcript.contains("hello\ndone"))
        let relaunched = try self.manager(in: directory)
        let restored = await relaunched.tasks()
        XCTAssertEqual(restored.first, finished)
        let restoredTranscript = await relaunched.transcript(taskID: task.id)
        XCTAssertEqual(restoredTranscript, transcript)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("tasks/\(task.id).json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        await relaunched.dismiss(taskID: task.id)
        let remaining = await relaunched.tasks()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tasks/\(task.id).log").path))
    }

    func testRelaunchMarksInterruptedWorkFailed() async throws {
        let directory = try scratchDirectory()
        let manager = try manager(in: directory)
        let task = try await manager.runShellCommand(command: "sleep 30", workingDirectory: directory.path)
        let recordURL = directory.appendingPathComponent("tasks/\(task.id).json")
        let interruptedRecord = try Data(contentsOf: recordURL)
        await manager.cancel(taskID: task.id)
        // Reproduce the on-disk state left by an abrupt app exit with a now-gone child.
        try interruptedRecord.write(to: recordURL)
        let recovered = try self.manager(in: directory)
        let restored = await recovered.tasks()
        XCTAssertEqual(restored.first?.status, .failed)
        XCTAssertTrue(restored.first?.result?.contains("could not be verified") == true)
        let recoveredTranscript = await recovered.transcript(taskID: task.id)
        XCTAssertTrue(recoveredTranscript.contains("Ambient restarted"))
    }

    func testFailureFreshWorkspaceAndMissingDirectory() async throws {
        let directory = try scratchDirectory()
        let manager = try manager(in: directory)
        let task = try await manager.runShellCommand(command: "printf 'bad\\n' >&2; exit 7")
        XCTAssertTrue(task.workingDirectory!.hasPrefix(directory.appendingPathComponent("workspaces").path))
        let finished = try await waitUntilFinished(manager, taskID: task.id)
        XCTAssertEqual(finished.status, .failed)
        XCTAssertTrue(finished.result?.contains("bad") == true)
        XCTAssertTrue(finished.latestActivity.contains("7"))
        do {
            _ = try await manager.runShellCommand(command: "true", workingDirectory: directory.appendingPathComponent("missing").path)
            XCTFail("Missing directory should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("does not exist")) }
    }

    func testCancelKillsProcessTreeAndDoesNotDismissRunningTask() async throws {
        let directory = try scratchDirectory()
        let manager = try manager(in: directory)
        let task = try await manager.runShellCommand(command: "sleep 60 & child=$!; echo $child > child.pid; wait", workingDirectory: directory.path)
        await manager.dismiss(taskID: task.id)
        let before = await manager.tasks()
        XCTAssertEqual(before.first?.status, .running)
        let pidFile = directory.appendingPathComponent("child.pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(childPID, 0), 0)
        await manager.cancel(taskID: task.id)
        for _ in 0..<100 {
            if kill(childPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(kill(childPID, 0), 0, "Grandchild must not survive cancellation")
        let cancelled = await manager.tasks().first
        XCTAssertEqual(cancelled?.status, .cancelled)
        await manager.cancel(taskID: task.id)
        let after = await manager.tasks().first
        XCTAssertEqual(after, cancelled)
    }

    func testConcurrentProcessesDoNotHoldEachOthersPipesOpen() async throws {
        let directory = try scratchDirectory()
        let manager = try manager(in: directory)
        let long = try await manager.runShellCommand(command: "sleep 30", workingDirectory: directory.path)
        let short = try await manager.runShellCommand(command: "printf short", workingDirectory: directory.path)
        let finished = try await waitUntilFinished(manager, taskID: short.id)
        XCTAssertEqual(finished.result, "short")
        let list = await manager.tasks()
        XCTAssertEqual(list.map(\.id), [short.id, long.id])
        await manager.cancel(taskID: long.id)
    }

    func testForegroundTimeoutKillsChildrenAndOutputIsCapped() async throws {
        let directory = try scratchDirectory()
        let timeoutResult = try await HeadlessProcess.run(executable: "/bin/zsh", arguments: ["-c", "sleep 60 & echo $! > child.pid; wait"], directory: directory,
            environment: AgentExecutableResolver.environment, timeout: 0.15)
        XCTAssertTrue(timeoutResult.timedOut)
        XCTAssertNotEqual(timeoutResult.exitCode, 0)
        let childPID = try XCTUnwrap(Int32(String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<100 {
            if kill(childPID, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(kill(childPID, 0), 0)
        let outputResult = try await HeadlessProcess.run(executable: "/bin/zsh", arguments: ["-c", "head -c 400000 /dev/zero | tr '\\0' x"], directory: directory,
            environment: AgentExecutableResolver.environment, outputLimit: 256 * 1024)
        XCTAssertEqual(outputResult.exitCode, 0)
        XCTAssertEqual(outputResult.output.count, 256 * 1024)
        XCTAssertTrue(outputResult.outputWasTruncated)
    }

    func testStandardErrorCannotCorruptJSONOutput() async throws {
        let directory = try scratchDirectory()
        let process = try HeadlessProcess(executable: "/bin/zsh", arguments: ["-c",
            "(head -c 100000 /dev/zero | tr '\\0' x >&2) & printf '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}\\n'; wait"],
            directory: directory, environment: AgentExecutableResolver.environment)
        var standardOutput = Data()
        var standardError = Data()
        for await event in process.events {
            if case .output(let data, let isStandardError) = event {
                if isStandardError { standardError.append(data) } else { standardOutput.append(data) }
            }
        }
        XCTAssertEqual(standardError.count, 100000)
        let parsed = AgentEventParser.parse(String(decoding: standardOutput, as: UTF8.self), kind: .codexAgent)
        XCTAssertEqual(parsed.result, "done")
    }

    func testNoTerminalWorkingDirectoryAndClosedInput() async throws {
        let directory = try scratchDirectory()
        let result = try await HeadlessProcess.run(executable: "/bin/zsh", arguments: ["-c", "test ! -t 0 && test ! -t 1 && test ! -t 2 && ! read reply && pwd"],
            directory: directory, environment: AgentExecutableResolver.environment)
        XCTAssertEqual(result.exitCode, 0)
        let reportedDirectory = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reportedDirectory)[.systemFileNumber] as? NSNumber,
                       try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber)
    }
}
