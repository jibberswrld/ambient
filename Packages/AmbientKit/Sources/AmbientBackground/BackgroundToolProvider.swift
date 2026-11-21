import AppKit
import Foundation
import AmbientContracts

/// Shared with Settings. Off by default; changing it affects the next tool call immediately.
public final class BackgroundApprovalSettings: @unchecked Sendable {
    public static let allowWithoutAskingKey = "ambient.background.allowWithoutAsking"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var allowWithoutAsking: Bool {
        get { defaults.bool(forKey: Self.allowWithoutAskingKey) }
        set { defaults.set(newValue, forKey: Self.allowWithoutAskingKey) }
    }
}

public struct BackgroundToolProvider: ToolProvider {
    public typealias Approval = @Sendable (_ title: String, _ detail: String) async -> Bool
    public let manager: BackgroundTaskManager
    public let approvalSettings: BackgroundApprovalSettings
    private let approval: Approval
    private let ambientAgent: BackgroundTaskManager.InProcessAgent?

    /// `ambientAgent` runs one background agent that has Ambient's own tools. Nil leaves only the coding agents.
    public init(manager: BackgroundTaskManager, approvalSettings: BackgroundApprovalSettings = BackgroundApprovalSettings(),
                ambientAgent: BackgroundTaskManager.InProcessAgent? = nil, approval: @escaping Approval) {
        self.manager = manager
        self.approvalSettings = approvalSettings
        self.ambientAgent = ambientAgent
        self.approval = approval
    }

    public func tools() async -> [any AmbientTool] {
        BackgroundToolOperation.allCases.map {
            BackgroundTool(operation: $0, manager: manager, settings: approvalSettings, approval: approval, ambientAgent: ambientAgent)
        }
    }

    public func systemPromptSection() async -> String? {
        """
        Work without interrupting the person's desktop. Use spawn_agent for any multi-step job that can run
        while the person does something else: coding, fixing or building a project, research, and work in
        their connected apps. Start several at once when the jobs are independent. An agent runs on the
        person's publik account with a stronger model than this conversation. It has a working directory
        with shell access (writes are confined to that directory), web search, the app connections, memory,
        and skills; it cannot see the screen. Brief it with the goal, relevant context and files, constraints,
        and a concrete definition of done; it knows nothing of this conversation. Pass working_directory when
        the job is about an existing project. Leave kind omitted. Set kind to codex or claude only when the
        person asks for Codex or Claude Code by name; those need the person's own CLI and subscription.
        Use run_shell_command for a specific known command; set
        run_in_background for lengthy work. Foreground commands time out after 30 seconds and output is capped
        at 256 KiB. Agents and background commands continue after your reply. After starting one, say in a few
        words that it is running and stop; never read a task id aloud, and do not wait or poll for it in the
        same turn. Use list_background_tasks and get_task_result when the person asks about progress or results. continue_agent
        resumes a finished Codex or Claude agent in its original directory and conversation. Agents run without
        a terminal or a window: Codex is confined to its workspace; Claude auto-accepts edits and denies
        anything that would need another permission prompt. Report permission failures honestly.
        Shell commands, AppleScript, spawning, and continuing agents require the person's confirmation unless
        they enabled Allow without asking. A denial means stop that action; do not retry it another way.
        Use AppleScript for app control without activating the app. Never include activate, open UI, or bring
        an app forward unless the person explicitly asked to see it. open_url and open_application keep the
        current app focused by default; set activate=true only when the person asked to see the destination.
        """
    }
}

private enum BackgroundToolOperation: String, CaseIterable, Sendable {
    case spawnAgent = "spawn_agent", continueAgent = "continue_agent", list = "list_background_tasks"
    case result = "get_task_result", cancel = "cancel_task", shell = "run_shell_command"
    case appleScript = "run_applescript", readClipboard = "read_clipboard", writeClipboard = "write_clipboard"
    case openURL = "open_url", openApplication = "open_application"

    var description: String {
        switch self {
        case .spawnAgent: return "Start a background agent for coding, research, or work in connected apps, and return its task id immediately. No window opens."
        case .continueAgent: return "Resume a finished coding agent with a follow-up message. Returns the same task id immediately."
        case .list: return "List background tasks, newest first, with status and latest activity."
        case .result: return "Get task status, latest activity, final result, and the last 8,000 characters of its readable transcript."
        case .cancel: return "Cancel a task and kill its entire process group. Finished tasks remain unchanged."
        case .shell: return "Run a zsh command after approval. Foreground: 30-second timeout, combined output capped at 256 KiB. Background: return a task id immediately."
        case .appleScript: return "Run AppleScript after approval, without activating apps unless the script explicitly asks. 30-second timeout; 256 KiB output cap."
        case .readClipboard: return "Read plain text from the macOS clipboard."
        case .writeClipboard: return "Replace the macOS clipboard with plain text."
        case .openURL: return "Open a URL while keeping the current app focused by default. Activate only if the person asked to see it."
        case .openApplication: return "Open an installed macOS application by name, bundle id, or absolute .app path, without activating by default."
        }
    }

    var properties: [String: JSONValue] {
        let directory = string("Existing absolute working directory. Omit for a new private Ambient workspace.")
        let taskID = JSONValue.object(["type": .string("string"), "format": .string("uuid"), "description": .string("The task id returned by spawn_agent or run_shell_command.")])
        let activation = JSONValue.object(["type": .string("boolean"), "default": .bool(false), "description": .string("Bring the destination to the front only when the person explicitly asked to see it.")])
        switch self {
        case .spawnAgent:
            return ["kind": .object(["type": .string("string"), "enum": .array([.string("ambient"), .string("codex"), .string("claude")]),
                                      "description": .string("Omit for Ambient's own agent. codex or claude only when the person asked for that tool by name.")]),
                    "prompt": string("Goal, context, constraints, and definition of done for the agent."),
                    "title": string("Short readable task title."), "working_directory": directory,
                    "model": string("Optional model explicitly requested by the person; otherwise the CLI default applies.")]
        case .continueAgent: return ["task_id": taskID, "message": string("Follow-up instructions for the original agent session.")]
        case .result, .cancel: return ["task_id": taskID]
        case .shell:
            return ["command": string("The exact zsh command to execute."), "working_directory": directory,
                    "run_in_background": .object(["type": .string("boolean"), "default": .bool(false)])]
        case .appleScript: return ["source": string("AppleScript source. Avoid activate and UI-opening commands unless explicitly requested.")]
        case .writeClipboard: return ["text": string("Plain text to place on the clipboard.")]
        case .openURL: return ["url": string("Absolute URL to open."), "activate": activation]
        case .openApplication: return ["application": string("Installed app name, bundle identifier, or absolute .app path."), "activate": activation]
        case .list, .readClipboard: return [:]
        }
    }
    var required: [String] {
        switch self {
        case .spawnAgent: return ["prompt", "title"]
        case .continueAgent: return ["task_id", "message"]
        case .result, .cancel: return ["task_id"]
        case .shell: return ["command"]
        case .appleScript: return ["source"]
        case .writeClipboard: return ["text"]
        case .openURL: return ["url"]
        case .openApplication: return ["application"]
        case .list, .readClipboard: return []
        }
    }
    var activity: String {
        switch self {
        case .spawnAgent: return "Starting background agent"
        case .continueAgent: return "Continuing background agent"
        case .list: return "Checking background tasks"
        case .result: return "Reading task result"
        case .cancel: return "Cancelling background task"
        case .shell: return "Running shell command"
        case .appleScript: return "Running AppleScript"
        case .readClipboard: return "Reading clipboard"
        case .writeClipboard: return "Writing clipboard"
        case .openURL: return "Opening link"
        case .openApplication: return "Opening application"
        }
    }
    private func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
}

private struct BackgroundTool: AmbientTool {
    let operation: BackgroundToolOperation
    let manager: BackgroundTaskManager
    let settings: BackgroundApprovalSettings
    let approval: BackgroundToolProvider.Approval
    let ambientAgent: BackgroundTaskManager.InProcessAgent?

    var definition: ToolDefinition {
        ToolDefinition(name: operation.rawValue, description: operation.description, parametersJSONSchema: .object([
            "type": .string("object"), "properties": .object(operation.properties),
            "required": .array(operation.required.map(JSONValue.string)), "additionalProperties": .bool(false)
        ]))
    }
    func activityLabel(arguments: JSONValue) -> String? { operation.activity }

    func run(arguments: JSONValue) async -> ToolResult {
        do {
            try validate(arguments)
            switch operation {
            case .spawnAgent:
                let kindName = arguments["kind"]?.stringValue ?? "ambient"
                let prompt = try text("prompt", arguments)
                if kindName == "ambient" {
                    guard let ambientAgent else { throw BackgroundExecutionError.message("Ambient agents are not available. Choose codex or claude.") }
                    guard await approved("Start agent?", detail: "\(prompt)\nDirectory: \(arguments["working_directory"]?.stringValue ?? "new Ambient workspace")") else { return denied() }
                    return taskResult(try await manager.spawnInProcessAgent(prompt: prompt, workingDirectory: arguments["working_directory"]?.stringValue,
                                                                              title: try text("title", arguments), run: ambientAgent))
                }
                guard kindName == "codex" || kindName == "claude" else { throw BackgroundExecutionError.message("kind must be codex, claude, or ambient.") }
                guard await approved("Start \(kindName == "codex" ? "Codex" : "Claude") agent?", detail: "\(prompt)\nDirectory: \(arguments["working_directory"]?.stringValue ?? "new Ambient workspace")") else { return denied() }
                return taskResult(try await manager.spawnAgent(kind: kindName == "codex" ? .codexAgent : .claudeAgent,
                    prompt: prompt, workingDirectory: arguments["working_directory"]?.stringValue,
                    title: try text("title", arguments), model: arguments["model"]?.stringValue))
            case .continueAgent:
                let message = try text("message", arguments)
                guard await approved("Continue agent?", detail: message) else { return denied() }
                return taskResult(try await manager.continueAgent(taskID: taskID(arguments), message: message))
            case .list: return jsonResult(.array(await manager.tasks().map(taskJSON)))
            case .result:
                let id = try taskID(arguments)
                guard let task = await manager.tasks().first(where: { $0.id == id }) else { return ToolResult(content: "Task not found.", isError: true) }
                guard case .object(var result) = taskJSON(task) else { return ToolResult(content: "Task not found.", isError: true) }
                result["transcript_tail"] = .string(String(await manager.transcript(taskID: id).suffix(8000)))
                return jsonResult(.object(result))
            case .cancel:
                let id = try taskID(arguments)
                guard await manager.tasks().contains(where: { $0.id == id }) else { return ToolResult(content: "Task not found.", isError: true) }
                await manager.cancel(taskID: id)
                return ToolResult(content: "Cancellation requested; any running process group was terminated.")
            case .shell:
                let command = try text("command", arguments)
                guard await approved("Run shell command?", detail: "\(command)\nDirectory: \(arguments["working_directory"]?.stringValue ?? "new Ambient workspace")") else { return denied() }
                if arguments["run_in_background"]?.boolValue == true {
                    return taskResult(try await manager.runShellCommand(command: command, workingDirectory: arguments["working_directory"]?.stringValue))
                }
                let directory = try foregroundDirectory(arguments["working_directory"]?.stringValue)
                return processResult(try await HeadlessProcess.run(executable: "/bin/zsh", arguments: ["-c", command],
                    directory: directory, environment: AgentExecutableResolver.environment))
            case .appleScript:
                let source = try text("source", arguments)
                guard await approved("Run AppleScript?", detail: source) else { return denied() }
                return processResult(try await HeadlessProcess.run(executable: "/usr/bin/osascript", arguments: ["-e", source],
                    directory: FileManager.default.homeDirectoryForCurrentUser, environment: AgentExecutableResolver.environment))
            case .readClipboard:
                return await MainActor.run { ToolResult(content: NSPasteboard.general.string(forType: .string) ?? "Clipboard has no plain text.") }
            case .writeClipboard:
                let text = try text("text", arguments, allowEmpty: true)
                return await MainActor.run {
                    NSPasteboard.general.clearContents()
                    let succeeded = NSPasteboard.general.setString(text, forType: .string)
                    return ToolResult(content: succeeded ? "Clipboard updated." : "Could not write clipboard.", isError: !succeeded)
                }
            case .openURL:
                guard let url = URL(string: try text("url", arguments)), url.scheme != nil else { throw BackgroundExecutionError.message("Provide an absolute URL.") }
                try await open(url: url, activate: arguments["activate"]?.boolValue ?? false, isApplication: false)
                return ToolResult(content: "URL opened\(arguments["activate"]?.boolValue == true ? " in front" : " without requesting activation").")
            case .openApplication:
                let application = try text("application", arguments)
                let url: URL? = await MainActor.run {
                    if application.hasPrefix("/") { return URL(fileURLWithPath: application) }
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: application) { return url }
                    let fileName = application.hasSuffix(".app") ? application : application + ".app"
                    let locations = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                                     URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                                     URL(fileURLWithPath: "/System/Applications/Utilities"), URL(fileURLWithPath: "/Applications/Utilities")]
                    return locations.map { $0.appendingPathComponent(fileName) }.first { FileManager.default.fileExists(atPath: $0.path) }
                }
                guard let url, url.pathExtension == "app" else { throw BackgroundExecutionError.message("Application not found: \(application)") }
                try await open(url: url, activate: arguments["activate"]?.boolValue ?? false, isApplication: true)
                return ToolResult(content: "Application opened\(arguments["activate"]?.boolValue == true ? " in front" : " without requesting activation").")
            }
        } catch { return ToolResult(content: error.localizedDescription, isError: true) }
    }

    private func validate(_ arguments: JSONValue) throws {
        guard case .object(let values) = arguments else { throw BackgroundExecutionError.message("Tool arguments must be a JSON object.") }
        for (key, value) in values {
            guard let property = operation.properties[key] else { throw BackgroundExecutionError.message("Unknown argument: \(key)") }
            if let string = value.stringValue, string.utf8.contains(0) { throw BackgroundExecutionError.message("\(key) must not contain a null byte.") }
            let isBoolean = property["type"]?.stringValue == "boolean"
            guard isBoolean ? value.boolValue != nil : value.stringValue != nil else { throw BackgroundExecutionError.message("Invalid type for \(key).") }
        }
        for key in operation.required where values[key] == nil { throw BackgroundExecutionError.message("Missing required argument: \(key)") }
    }
    private func text(_ key: String, _ arguments: JSONValue, allowEmpty: Bool = false) throws -> String {
        guard let value = arguments[key]?.stringValue, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackgroundExecutionError.message("\(key) must be a nonempty string.")
        }
        return value
    }
    private func taskID(_ arguments: JSONValue) throws -> UUID {
        guard let id = UUID(uuidString: try text("task_id", arguments)) else { throw BackgroundExecutionError.message("task_id must be a UUID.") }
        return id
    }
    private func approved(_ title: String, detail: String) async -> Bool {
        settings.allowWithoutAsking ? true : await approval(title, detail)
    }
    private func denied() -> ToolResult { ToolResult(content: "The person denied this action. Nothing was run.") }
    private func taskResult(_ task: BackgroundTask) -> ToolResult { jsonResult(taskJSON(task)) }
    private func taskJSON(_ task: BackgroundTask) -> JSONValue {
        .object(["task_id": .string(task.id.uuidString), "kind": .string(task.kind.rawValue), "title": .string(task.title),
                 "status": .string(task.status.rawValue), "latest_activity": .string(task.latestActivity),
                 "working_directory": task.workingDirectory.map(JSONValue.string) ?? .null,
                 "result": task.result.map(JSONValue.string) ?? .null])
    }
    private func jsonResult(_ json: JSONValue) -> ToolResult {
        do { return ToolResult(content: String(decoding: try JSONEncoder().encode(json), as: UTF8.self)) }
        catch { return ToolResult(content: "Could not encode tool result: \(error.localizedDescription)", isError: true) }
    }
    private func processResult(_ result: HeadlessProcessResult) -> ToolResult {
        var content = String(decoding: result.output, as: UTF8.self)
        if result.outputWasTruncated { content += "\n[Output capped at 256 KiB.]" }
        if result.timedOut { content += "\n[Timed out after 30 seconds; the process group was killed.]" }
        content += "\n[Exit code: \(result.exitCode)]"
        return ToolResult(content: content, isError: result.exitCode != 0 || result.timedOut)
    }
    private func foregroundDirectory(_ path: String?) throws -> URL {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BackgroundExecutionError.message("Working directory must be an existing absolute directory.")
            }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let directory = BackgroundTaskManager.defaultWorkspaceDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    @MainActor private func open(url: URL, activate: Bool, isApplication: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            if isApplication {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
            } else if let application = NSWorkspace.shared.urlForApplication(toOpen: url) {
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration, completionHandler: completion)
            } else { continuation.resume(throwing: BackgroundExecutionError.message("No application can open this URL.")) }
        }
    }
}
