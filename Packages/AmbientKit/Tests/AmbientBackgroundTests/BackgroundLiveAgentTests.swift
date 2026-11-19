import AppKit
import XCTest
import AmbientContracts
@testable import AmbientBackground

/// Explicit opt-in because these tests spend the signed-in user's CLI subscription quota.
final class BackgroundLiveAgentTests: XCTestCase {
    func testLiveCodexSpawnAndResume() async throws { try await runLiveAgent(kind: "codex", resume: true) }
    func testLiveClaudeSpawn() async throws { try await runLiveAgent(kind: "claude", resume: false) }

    private func runLiveAgent(kind: String, resume: Bool) async throws {
        guard ProcessInfo.processInfo.environment["AMBIENT_RUN_LIVE_AGENTS"] == "1" else {
            throw XCTSkip("Set AMBIENT_RUN_LIVE_AGENTS=1 to spend CLI quota on live verification.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientLive-\(kind)-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Retain this tiny workspace and task journal so the integration owner can inspect the evidence.
        let manager = try BackgroundTaskManager(storageDirectory: directory.appendingPathComponent("tasks"), workspaceDirectory: directory.appendingPathComponent("workspaces"))
        let settings = BackgroundApprovalSettings(defaults: UserDefaults(suiteName: "AmbientLive-\(UUID())")!)
        let approvalCalls = LiveApprovalRecorder()
        let provider = BackgroundToolProvider(manager: manager, approvalSettings: settings) { _, _ in await approvalCalls.approve() }
        let tools = await provider.tools()
        let spawn = try XCTUnwrap(tools.first { $0.definition.name == "spawn_agent" })
        let desktop = await MainActor.run { DesktopObservation() }
        let started = await spawn.run(arguments: .object(["kind": .string(kind), "prompt": .string("Create a file named hello.txt containing the word ok, then reply done. Do not use subagents."),
                                                         "title": .string("Live \(kind) verification"), "working_directory": .string(directory.path)]))
        XCTAssertFalse(started.isError, started.content)
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(started.content.utf8))
        let taskID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(response["task_id"]?.stringValue)))
        let finished = try await waitUntilFinished(manager, taskID: taskID)
        print("LIVE \(kind): task=\(taskID), directory=\(directory.path), status=\(finished.status.rawValue), result=\(finished.result ?? "nil")")
        if finished.status != .succeeded { print("LIVE transcript: \(await manager.transcript(taskID: taskID))") }
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertTrue(finished.result?.lowercased().contains("done") == true, finished.result ?? "No final answer")
        let file = directory.appendingPathComponent("hello.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        if resume {
            // A fresh manager proves the CLI session id and original cwd survived persistence.
            let relaunchedManager = try BackgroundTaskManager(storageDirectory: directory.appendingPathComponent("tasks"))
            let resumedProvider = BackgroundToolProvider(manager: relaunchedManager, approvalSettings: settings) { _, _ in await approvalCalls.approve() }
            let resumeTools = await resumedProvider.tools()
            let continuation = try XCTUnwrap(resumeTools.first { $0.definition.name == "continue_agent" })
            let continued = await continuation.run(arguments: .object(["task_id": .string(taskID.uuidString), "message": .string("Read hello.txt, create continued.txt containing the same word, then reply resumed. Do not use subagents.")]))
            XCTAssertFalse(continued.isError, continued.content)
            let result = try await waitUntilFinished(relaunchedManager, taskID: taskID)
            XCTAssertEqual(result.status, .succeeded, result.result ?? "No result")
            XCTAssertTrue(result.result?.lowercased().contains("resumed") == true)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("continued.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            print("LIVE \(kind) resume: task=\(taskID), status=\(result.status.rawValue), result=\(result.result ?? "nil"), continued.txt=ok")
        }
        let calls = await approvalCalls.count
        XCTAssertEqual(calls, resume ? 2 : 1)
        let observation = await MainActor.run { desktop.finish() }
        XCTAssertTrue(observation.launchedAgentApps.isEmpty, "Unexpected app launches: \(observation.launchedAgentApps)")
        XCTAssertEqual(observation.frontmostAtEnd, observation.frontmostAtStart, "The focused app changed during the live run")
        XCTAssertTrue(observation.focusChanges.isEmpty, "Unexpected app activations: \(observation.focusChanges)")
        XCTAssertTrue(observation.newAgentWindows.isEmpty, "New agent/terminal windows: \(observation.newAgentWindows)")
        print("LIVE desktop: focused=\(observation.frontmostAtStart ?? "none"), focusUnchanged=\(observation.frontmostAtEnd == observation.frontmostAtStart), launchedAgentApps=\(observation.launchedAgentApps), newAgentWindows=\(observation.newAgentWindows)")
    }

    private func waitUntilFinished(_ manager: BackgroundTaskManager, taskID: UUID) async throws -> BackgroundTask {
        for _ in 0..<1200 {
            if let task = await manager.tasks().first(where: { $0.id == taskID }), task.status != .running { return task }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await manager.cancel(taskID: taskID)
        throw BackgroundExecutionError.message("Live task exceeded two minutes and was cancelled.")
    }
}

private actor LiveApprovalRecorder {
    var count = 0
    func approve() -> Bool { count += 1; return true }
}

@MainActor private final class DesktopObservation {
    struct Result {
        var frontmostAtStart: String?
        var frontmostAtEnd: String?
        var launchedAgentApps: [String]
        var newAgentWindows: [String]
        var focusChanges: [String]
    }
    private let frontmostAtStart = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private let initialWindows = DesktopObservation.agentWindows()
    private var launchedAgentApps: [String] = []
    private var launchObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var focusChanges: [String] = []

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if application.bundleIdentifier != self?.frontmostAtStart {
                    self?.focusChanges.append(application.bundleIdentifier ?? application.localizedName ?? "unknown")
                }
            }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let name = application.localizedName ?? ""
            MainActor.assumeIsolated {
                if Self.isAgentOrTerminal(name) { self?.launchedAgentApps.append(name) }
            }
        }
    }
    func finish() -> Result {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        return Result(frontmostAtStart: frontmostAtStart, frontmostAtEnd: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                      launchedAgentApps: launchedAgentApps, newAgentWindows: Array(Self.agentWindows().subtracting(initialWindows)).sorted(), focusChanges: focusChanges)
    }
    private static func isAgentOrTerminal(_ name: String) -> Bool {
        ["codex", "claude", "terminal", "iterm", "ghostty", "warp"].contains { name.lowercased().contains($0) }
    }
    private static func agentWindows() -> Set<String> {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, isAgentOrTerminal(owner),
                  let number = window[kCGWindowNumber as String] as? NSNumber else { return nil }
            return "\(owner):\(number)"
        })
    }
}
