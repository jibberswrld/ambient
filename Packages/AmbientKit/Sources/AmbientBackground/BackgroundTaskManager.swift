import Foundation
import AmbientContracts

/// Keep one manager alive for the lifetime of the app. It owns every child it launches.
public actor BackgroundTaskManager: BackgroundTaskStore {
    public static var defaultStorageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ambient/tasks", isDirectory: true)
    }
    public static var defaultWorkspaceDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ambient/workspaces", isDirectory: true)
    }

    private let storageDirectory: URL
    private let workspaceDirectory: URL
    private var records: [UUID: PersistedBackgroundTask] = [:]
    private var processes: [UUID: HeadlessProcess] = [:]
    private var inProcessAgents: [UUID: Task<Void, Never>] = [:]
    private var listContinuations: [UUID: AsyncStream<[BackgroundTask]>.Continuation] = [:]
    private var completionContinuations: [UUID: AsyncStream<BackgroundTask>.Continuation] = [:]

    public init(storageDirectory: URL = BackgroundTaskManager.defaultStorageDirectory,
                workspaceDirectory: URL = BackgroundTaskManager.defaultWorkspaceDirectory) throws {
        self.storageDirectory = storageDirectory
        self.workspaceDirectory = workspaceDirectory
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for url in try FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            var record = try JSONDecoder().decode(PersistedBackgroundTask.self, from: Data(contentsOf: url))
            if record.status == .running {
                // Relaunch cannot safely adopt or signal a PID: it may now belong to another process.
                record.status = .failed
                record.finishedAt = Date()
                record.latestActivity = "Ambient restarted; the previous process is no longer supervised. Its completion could not be verified."
                record.result = record.latestActivity
                try Data((record.latestActivity + "\n").utf8).appendPrivately(to: storageDirectory.appendingPathComponent("\(record.id).log"))
                try JSONEncoder().encode(record).writePrivately(to: url)
            }
            records[record.id] = record
        }
    }

    deinit {
        for process in processes.values { process.terminate() }
        for agent in inProcessAgents.values { agent.cancel() }
        for continuation in listContinuations.values { continuation.finish() }
        for continuation in completionContinuations.values { continuation.finish() }
    }

    public func tasks() async -> [BackgroundTask] { taskList() }

    public nonisolated func updates() -> AsyncStream<[BackgroundTask]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observerID = UUID()
            Task { await self.addListObserver(observerID, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListObserver(observerID) } }
        }
    }

    /// Future transitions only; subscribe before starting work. Every final status is delivered once per run.
    public func completions() -> AsyncStream<BackgroundTask> {
        AsyncStream { continuation in
            let observerID = UUID()
            self.completionContinuations[observerID] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeCompletionObserver(observerID) } }
        }
    }

    public func transcript(taskID: UUID) async -> String {
        guard records[taskID] != nil else { return "Task not found." }
        do { return String(decoding: try Data(contentsOf: transcriptURL(taskID)), as: UTF8.self) }
        catch { return "Could not read transcript: \(error.localizedDescription)" }
    }

    public func dismiss(taskID: UUID) async {
        guard let record = records[taskID], record.status != .running else { return }
        do {
            try FileManager.default.removeItem(at: recordURL(taskID))
            if FileManager.default.fileExists(atPath: transcriptURL(taskID).path) {
                try FileManager.default.removeItem(at: transcriptURL(taskID))
            }
            records.removeValue(forKey: taskID)
            publish()
        } catch { recordStorageFailure(taskID, error: error); publish() }
    }

    public func cancel(taskID: UUID) async {
        guard var record = records[taskID], record.status == .running else { return }
        processes.removeValue(forKey: taskID)?.terminate()
        inProcessAgents.removeValue(forKey: taskID)?.cancel()
        record.status = .cancelled
        record.finishedAt = Date()
        record.latestActivity = "Cancelled"
        record.result = "Cancelled by the user."
        records[taskID] = record
        do { try appendTranscript("Cancelled by the user.", taskID: taskID); try persist(taskID) }
        catch { recordStorageFailure(taskID, error: error) }
        publishCompletion(taskID)
    }

    @discardableResult
    public func spawnAgent(kind: BackgroundTask.Kind, prompt: String, workingDirectory: String? = nil,
                           title: String, model: String? = nil) async throws -> BackgroundTask {
        guard kind == .codexAgent || kind == .claudeAgent else { throw BackgroundExecutionError.message("Choose codex or claude for an agent.") }
        let executable = try await AgentExecutableResolver.resolve(kind == .codexAgent ? "codex" : "claude")
        let directory = try prepareDirectory(workingDirectory)
        let record = PersistedBackgroundTask(kind: kind, title: title, directory: directory.path, model: model)
        return try start(record: record, executable: executable.path,
                         arguments: agentArguments(record: record, prompt: prompt, resuming: false),
                         environment: executable.environment, prompt: prompt)
    }

    /// An agent that runs inside Ambient instead of a CLI. `run` reports what it is doing and returns its final answer.
    public typealias InProcessAgent = @Sendable (_ prompt: String, _ workingDirectory: URL, _ reportActivity: @escaping @Sendable (String) -> Void) async throws -> String

    @discardableResult
    public func spawnInProcessAgent(prompt: String, workingDirectory: String? = nil, title: String, run: @escaping InProcessAgent) throws -> BackgroundTask {
        let directory = try prepareDirectory(workingDirectory)
        let record = PersistedBackgroundTask(kind: .ambientAgent, title: title, directory: directory.path)
        let taskID = record.id
        records[taskID] = record
        try appendTranscript("\nUser: \(prompt)\n", taskID: taskID)
        try persist(taskID)
        inProcessAgents[taskID] = Task { [weak self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await run(prompt, directory) { [weak self] activity in Task { await self?.recordActivity(activity, taskID: taskID) } })
            } catch { outcome = .failure(error) }
            await self?.finishInProcessAgent(taskID: taskID, outcome: outcome)
        }
        publish()
        return record.task
    }

    private func recordActivity(_ activity: String, taskID: UUID) {
        guard var record = records[taskID], record.status == .running else { return }
        record.latestActivity = AgentEventParser.singleLine(activity)
        records[taskID] = record
        do { try appendTranscript(activity, taskID: taskID); try persist(taskID) }
        catch { recordStorageFailure(taskID, error: error) }
        publish()
    }

    private func finishInProcessAgent(taskID: UUID, outcome: Result<String, Error>) {
        // A cancelled task was already finished by cancel(taskID:).
        guard inProcessAgents.removeValue(forKey: taskID) != nil, var record = records[taskID], record.status == .running else { return }
        switch outcome {
        case .success(let answer):
            record.status = .succeeded
            record.result = answer
            record.latestActivity = "Finished"
        case .failure(let error):
            record.status = .failed
            record.result = error.localizedDescription
            record.latestActivity = "Failed"
        }
        record.finishedAt = Date()
        records[taskID] = record
        do { try appendTranscript(record.result ?? "", taskID: taskID); try persist(taskID) }
        catch { recordStorageFailure(taskID, error: error) }
        publishCompletion(taskID)
    }

    @discardableResult
    public func continueAgent(taskID: UUID, message: String) async throws -> BackgroundTask {
        guard let previous = records[taskID] else { throw BackgroundExecutionError.message("Task not found.") }
        guard previous.status != .running else { throw BackgroundExecutionError.message("The agent is still running. Wait for it to finish first.") }
        guard previous.sessionID != nil else {
            throw BackgroundExecutionError.message("This task has no resumable agent session.")
        }
        let executable = try await AgentExecutableResolver.resolve(previous.kind == .codexAgent ? "codex" : "claude")
        // Resolving a login shell yields the actor; recheck to prevent two concurrent resumes.
        guard var record = records[taskID], record.status != .running else {
            throw BackgroundExecutionError.message("The agent is already running.")
        }
        record.status = .running
        record.finishedAt = nil
        record.result = nil
        record.latestActivity = "Continuing agent"
        record.agentFailure = nil
        return try start(record: record, executable: executable.path,
                         arguments: agentArguments(record: record, prompt: message, resuming: true),
                         environment: executable.environment, prompt: message)
    }

    @discardableResult
    public func runShellCommand(command: String, workingDirectory: String? = nil) async throws -> BackgroundTask {
        let directory = try prepareDirectory(workingDirectory)
        return try start(record: PersistedBackgroundTask(kind: .shellCommand,
            title: AgentEventParser.singleLine(command), directory: directory.path), executable: "/bin/zsh",
            arguments: ["-c", command], environment: AgentExecutableResolver.environment, prompt: command)
    }

    private func agentArguments(record: PersistedBackgroundTask, prompt: String, resuming: Bool) -> [String] {
        var arguments: [String]
        if record.kind == .codexAgent {
            arguments = ["exec"] + (resuming ? ["resume"] : [])
            arguments += ["--json", "--skip-git-repo-check", "-c", "approval_policy=\"never\"",
                          "-c", "sandbox_mode=\"workspace-write\""]
        } else {
            arguments = ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                         "--permission-prompts", "none", "--no-chrome"]
            if resuming { arguments += ["--resume", record.sessionID!] }
        }
        if let model = record.model { arguments += ["--model", model] }
        if resuming && record.kind == .codexAgent { arguments.append(record.sessionID!) }
        let backgroundPrompt = """
        You are running headlessly in Ambient while the person uses their Mac. Do not open windows, launch
        GUI apps, or change focus unless the person's task explicitly asks to see something. Work through
        files and headless commands. Do not launch interactive permission or authentication flows; report
        missing access in your final answer. The person's task follows:

        \(prompt)
        """
        arguments += ["--", backgroundPrompt]
        return arguments
    }

    private func prepareDirectory(_ path: String?) throws -> URL {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw BackgroundExecutionError.message("Working directory must be an absolute path.") }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BackgroundExecutionError.message("Working directory does not exist: \(expanded)")
            }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let directory = workspaceDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func start(record: PersistedBackgroundTask, executable: String, arguments: [String],
                       environment: [String: String], prompt: String) throws -> BackgroundTask {
        records[record.id] = record
        do {
            try appendTranscript("\nUser: \(prompt)\n", taskID: record.id)
            try persist(record.id)
            let process = try HeadlessProcess(executable: executable, arguments: arguments,
                directory: URL(fileURLWithPath: record.directory), environment: environment)
            processes[record.id] = process
            Task { [weak self] in
                var partialLines = [Data(), Data()]
                for await event in process.events {
                    guard let self else { process.terminate(); return }
                    switch event {
                    case .output(let data, let isStandardError):
                        let channel = isStandardError ? 1 : 0
                        partialLines[channel].append(data)
                        while let newline = partialLines[channel].firstIndex(of: 10) {
                            let line = String(decoding: partialLines[channel][..<newline], as: UTF8.self)
                            partialLines[channel].removeSubrange(...newline)
                            await self.receive(line: line, isStandardError: isStandardError, taskID: record.id, process: process)
                        }
                        // Bound a malformed JSON record or command that never emits a newline.
                        if partialLines[channel].count > 1024 * 1024 {
                            await self.receive(line: String(decoding: partialLines[channel], as: UTF8.self),
                                               isStandardError: isStandardError, taskID: record.id, process: process)
                            partialLines[channel].removeAll(keepingCapacity: true)
                        }
                    case .finished(let result):
                        for channel in partialLines.indices where !partialLines[channel].isEmpty {
                            await self.receive(line: String(decoding: partialLines[channel], as: UTF8.self),
                                               isStandardError: channel == 1, taskID: record.id, process: process)
                        }
                        await self.finish(taskID: record.id, process: process, result: result)
                    }
                }
            }
            publish()
            return record.task
        } catch {
            var failed = record
            failed.status = .failed
            failed.finishedAt = Date()
            failed.latestActivity = "Could not start: \(error.localizedDescription)"
            failed.result = failed.latestActivity
            records[record.id] = failed
            try? persist(record.id)
            publishCompletion(record.id)
            throw error
        }
    }

    private func receive(line: String, isStandardError: Bool, taskID: UUID, process: HeadlessProcess) {
        guard processes[taskID] === process, var record = records[taskID], record.status == .running else { return }
        let event = record.kind == .shellCommand
            ? ParsedAgentEvent(activity: AgentEventParser.singleLine(line), transcript: line)
            : (isStandardError ? ParsedAgentEvent(transcript: line) : AgentEventParser.parse(line, kind: record.kind))
        if let sessionID = event.sessionID { record.sessionID = sessionID }
        if let result = event.result { record.result = result }
        if let failure = event.failure { record.agentFailure = failure }
        if let activity = event.activity, !activity.isEmpty { record.latestActivity = AgentEventParser.singleLine(activity) }
        records[taskID] = record
        do {
            if let transcript = event.transcript, !transcript.isEmpty { try appendTranscript(transcript, taskID: taskID) }
            try persist(taskID)
        } catch { recordStorageFailure(taskID, error: error) }
        publish()
    }

    private func finish(taskID: UUID, process: HeadlessProcess, result: HeadlessProcessResult) {
        guard processes[taskID] === process, var record = records[taskID], record.status == .running else { return }
        processes.removeValue(forKey: taskID)
        if record.kind != .shellCommand && record.result == nil && record.agentFailure == nil && result.exitCode == 0 {
            record.agentFailure = "The CLI exited without a final answer. See the transcript for details."
        }
        let succeeded = result.exitCode == 0 && record.agentFailure == nil
        record.status = succeeded ? .succeeded : .failed
        record.finishedAt = Date()
        if record.kind == .shellCommand {
            record.result = String(decoding: result.output, as: UTF8.self)
            if result.outputWasTruncated { record.result! += "\n[Result capped at 256 KiB; full output is in the transcript.]" }
        } else if let failure = record.agentFailure { record.result = failure }
        if !succeeded && record.result == nil {
            record.result = "Process exited with code \(result.exitCode).\n" + String((try? String(contentsOf: transcriptURL(taskID), encoding: .utf8))?.suffix(4000) ?? "")
        }
        record.latestActivity = succeeded ? "Finished" : "Failed (exit \(result.exitCode))"
        records[taskID] = record
        do { try persist(taskID) } catch { recordStorageFailure(taskID, error: error) }
        publishCompletion(taskID)
    }

    private func recordStorageFailure(_ taskID: UUID, error: Error) {
        guard var record = records[taskID] else { return }
        record.latestActivity = "Could not save task: \(error.localizedDescription)"
        records[taskID] = record
    }
    private func recordURL(_ id: UUID) -> URL { storageDirectory.appendingPathComponent("\(id).json") }
    private func transcriptURL(_ id: UUID) -> URL { storageDirectory.appendingPathComponent("\(id).log") }
    private func persist(_ id: UUID) throws { try JSONEncoder().encode(records[id]!).writePrivately(to: recordURL(id)) }
    private func appendTranscript(_ text: String, taskID: UUID) throws {
        try Data((text + "\n").utf8).appendPrivately(to: transcriptURL(taskID))
    }
    private func taskList() -> [BackgroundTask] { records.values.map(\.task).sorted { $0.startedAt > $1.startedAt } }
    private func publish() { for continuation in listContinuations.values { continuation.yield(taskList()) } }
    private func publishCompletion(_ id: UUID) {
        publish()
        guard let task = records[id]?.task else { return }
        for continuation in completionContinuations.values { continuation.yield(task) }
    }
    private func addListObserver(_ id: UUID, continuation: AsyncStream<[BackgroundTask]>.Continuation) {
        listContinuations[id] = continuation
        continuation.yield(taskList())
    }
    private func removeListObserver(_ id: UUID) { listContinuations.removeValue(forKey: id) }
    private func removeCompletionObserver(_ id: UUID) { completionContinuations.removeValue(forKey: id) }
}

private struct PersistedBackgroundTask: Codable {
    var id = UUID()
    var kind: BackgroundTask.Kind
    var title: String
    var status: BackgroundTask.Status = .running
    var directory: String
    var startedAt = Date()
    var finishedAt: Date?
    var latestActivity = "Starting"
    var result: String?
    var sessionID: String?
    var model: String?
    var agentFailure: String?
    var task: BackgroundTask {
        BackgroundTask(id: id, kind: kind, title: title, status: status, workingDirectory: directory,
                       startedAt: startedAt, finishedAt: finishedAt, latestActivity: latestActivity, result: result)
    }
}

private extension Data {
    func writePrivately(to url: URL) throws {
        try write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func appendPrivately(to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try Data().writePrivately(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
