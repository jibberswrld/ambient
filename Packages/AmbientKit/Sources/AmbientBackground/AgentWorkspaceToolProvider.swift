import Foundation
import AmbientContracts

/// The shell of one background agent. Commands start in the agent's working directory and may write only
/// there and in temporary and cache folders, so an agent nobody is watching cannot change the rest of the Mac.
public struct AgentWorkspaceToolProvider: ToolProvider {
    let workingDirectory: URL

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    public func tools() async -> [any AmbientTool] { [AgentShellTool(workingDirectory: workingDirectory)] }

    public func systemPromptSection() async -> String? {
        """
        Your working directory is \(workingDirectory.path). run_shell_command runs zsh there. Use it to read
        and search files, write them (a heredoc or a short script works well for edits), and run builds, tests
        and git. Commands can read the whole Mac and use the network, and can write only inside the working
        directory and temporary folders; a write anywhere else fails with "operation not permitted", which is
        not something to work around. Each command is limited to five minutes and 256 KiB of output.
        """
    }
}

struct AgentShellTool: AmbientTool {
    let workingDirectory: URL

    var definition: ToolDefinition {
        ToolDefinition(name: "run_shell_command",
            description: "Run a zsh command in the working directory and return its combined output and exit code.",
            parametersJSONSchema: .object(["type": .string("object"),
                "properties": .object(["command": .object(["type": .string("string"), "description": .string("The exact zsh command to execute.")])]),
                "required": .array([.string("command")]), "additionalProperties": .bool(false)]))
    }

    func activityLabel(arguments: JSONValue) -> String? {
        arguments["command"]?.stringValue.map { "Running \(AgentEventParser.singleLine($0))" }
    }

    func run(arguments: JSONValue) async -> ToolResult {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty, !command.utf8.contains(0) else {
            return ToolResult(content: "command must be a nonempty string.", isError: true)
        }
        do {
            let result = try await HeadlessProcess.run(executable: "/usr/bin/sandbox-exec",
                arguments: ["-p", Self.sandboxProfile(workingDirectory: workingDirectory), "/bin/zsh", "-c", command],
                directory: workingDirectory, environment: AgentExecutableResolver.environment, timeout: 300)
            var content = String(decoding: result.output, as: UTF8.self)
            if result.outputWasTruncated { content += "\n[Output capped at 256 KiB.]" }
            if result.timedOut { content += "\n[Timed out after five minutes; the process group was killed.]" }
            content += "\n[Exit code: \(result.exitCode)]"
            return ToolResult(content: content, isError: result.exitCode != 0 || result.timedOut)
        } catch { return ToolResult(content: error.localizedDescription, isError: true) }
    }

    /// Everything is allowed except writing under the home folder, outside the working directory and the
    /// caches that compilers and package managers need. System locations are already protected by macOS.
    static func sandboxProfile(workingDirectory: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let writable = [workingDirectory.resolvingSymlinksInPath().path, "\(home)/Library/Caches", "\(home)/.cache", "\(home)/.npm"]
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "(version 1)(allow default)(deny file-write* (subpath \(quoted(home))))(allow file-write* "
            + writable.map { "(subpath \(quoted($0)))" }.joined() + ")"
    }
}
