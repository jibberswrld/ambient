import Foundation

struct HeadlessProcessResult: Sendable {
    var exitCode: Int32
    var output: Data
    var timedOut: Bool
    var outputWasTruncated: Bool
}

/// Uses a separate process group and pipes, never a terminal or Launch Services.
final class HeadlessProcess: @unchecked Sendable {
    enum Event: Sendable { case output(Data, isStandardError: Bool), finished(HeadlessProcessResult) }
    let events: AsyncStream<Event>
    let processIdentifier: pid_t
    private let stateLock = NSLock()
    private var hasFinished = false
    private var timedOut = false

    init(executable: String, arguments: [String], directory: URL, environment: [String: String],
         timeout: TimeInterval? = nil, outputLimit: Int = 256 * 1024) throws {
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream { continuation = $0 }
        let eventContinuation = continuation!
        var outputDescriptors: [Int32] = [0, 0]
        var errorDescriptors: [Int32] = [0, 0]
        guard pipe(&outputDescriptors) == 0 else { throw POSIXError(.EMFILE) }
        guard pipe(&errorDescriptors) == 0 else {
            outputDescriptors.forEach { close($0) }
            throw POSIXError(.EMFILE)
        }
        let readDescriptor = outputDescriptors[0]
        let writeDescriptor = outputDescriptors[1]
        // Other tasks must not inherit these pipes and hold their EOF open.
        for descriptor in outputDescriptors + errorDescriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
            close(writeDescriptor)
            close(errorDescriptors[1])
        }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errorDescriptors[1], STDERR_FILENO)
        for descriptor in outputDescriptors + errorDescriptors {
            posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }
        posix_spawn_file_actions_addchdir_np(&fileActions, directory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argumentPointers = ([executable] + arguments).map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        var identifier: pid_t = 0
        let spawnError = argumentPointers.withUnsafeBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(&identifier, executable, &fileActions, &attributes,
                            UnsafeMutablePointer(mutating: argumentBuffer.baseAddress!),
                            UnsafeMutablePointer(mutating: environmentBuffer.baseAddress!))
            }
        }
        guard spawnError == 0 else {
            close(readDescriptor)
            close(errorDescriptors[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawnError) ?? .EIO)
        }
        processIdentifier = identifier
        let outputReadFinished = DispatchGroup()
        let capturedOutput = ProcessOutputBuffer(limit: outputLimit)
        // Stderr must never be spliced into a JSON record arriving on stdout.
        for (descriptor, isStandardError) in [(readDescriptor, false), (errorDescriptors[0], true)] {
            outputReadFinished.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { close(descriptor); outputReadFinished.leave() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    let data = Data(buffer.prefix(count))
                    capturedOutput.append(data)
                    eventContinuation.yield(.output(data, isStandardError: isStandardError))
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            var waitedIdentifier: pid_t
            repeat { waitedIdentifier = waitpid(identifier, &status, 0) } while waitedIdentifier < 0 && errno == EINTR
            stateLock.lock()
            hasFinished = true
            // A shell can exit leaving children holding its output pipe. They belong to this task too.
            kill(-identifier, SIGKILL)
            let didTimeOut = timedOut
            stateLock.unlock()
            outputReadFinished.wait()
            let exitCode: Int32 = waitedIdentifier < 0 ? -1 : (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
            eventContinuation.yield(.finished(HeadlessProcessResult(
                exitCode: exitCode, output: capturedOutput.data, timedOut: didTimeOut,
                outputWasTruncated: capturedOutput.wasTruncated)))
            eventContinuation.finish()
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.terminate(timedOut: true)
            }
        }
    }

    func terminate(timedOut: Bool = false) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !hasFinished else { return }
        self.timedOut = timedOut
        // Cancellation must also stop children that ignore SIGTERM.
        kill(-processIdentifier, SIGKILL)
    }

    static func run(executable: String, arguments: [String], directory: URL,
                    environment: [String: String], timeout: TimeInterval = 30,
                    outputLimit: Int = 256 * 1024) async throws -> HeadlessProcessResult {
        let process = try HeadlessProcess(executable: executable, arguments: arguments, directory: directory,
                                          environment: environment, timeout: timeout, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            for await event in process.events {
                if case .finished(let result) = event { return result }
            }
            throw CancellationError()
        } onCancel: { process.terminate() }
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    let limit: Int
    var data = Data()
    var wasTruncated = false
    private let lock = NSLock()
    init(limit: Int) { self.limit = max(0, limit) }
    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(newData.prefix(remaining))
        if newData.count > remaining { wasTruncated = true }
    }
}

struct AgentExecutableResolver: Sendable {
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + (environment["PATH"] ?? "").components(separatedBy: ":")
        environment["PATH"] = paths.filter { !$0.isEmpty }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ":")
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: "CLAUDECODE")
        return environment
    }

    static func resolve(_ name: String) async throws -> (path: String, environment: [String: String]) {
        var environment = environment
        let commonCandidate = environment["PATH", default: ""].components(separatedBy: ":")
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Finder omits shell-managed toolchains. Import the login PATH even if the CLI was found above.
        // Only fixed executable names enter this shell, never a model-provided argument.
        if let lookup = try? await HeadlessProcess.run(executable: shell,
            arguments: ["-lc", "printf '\\nAMBIENT_EXECUTABLE='; command -v \(name); printf '\\nAMBIENT_PATH=%s\\n' \"$PATH\""],
            directory: FileManager.default.homeDirectoryForCurrentUser, environment: environment, timeout: 5, outputLimit: 32 * 1024) {
            let lines = String(decoding: lookup.output, as: UTF8.self).components(separatedBy: "\n")
            if let shellPath = lines.first(where: { $0.hasPrefix("AMBIENT_PATH=") }) {
                environment["PATH"] = String(shellPath.dropFirst("AMBIENT_PATH=".count)) + ":" + environment["PATH", default: ""]
            }
            if let commonCandidate { return (commonCandidate, environment) }
            if let line = lines.first(where: { $0.hasPrefix("AMBIENT_EXECUTABLE=/") }) {
                let candidate = String(line.dropFirst("AMBIENT_EXECUTABLE=".count))
                if FileManager.default.isExecutableFile(atPath: candidate) { return (candidate, environment) }
            }
        }
        if let commonCandidate { return (commonCandidate, environment) }
        throw BackgroundExecutionError.message("\(name == "codex" ? "Codex CLI" : "Claude Code CLI") is not installed or could not be found. Install it and sign in before starting an agent.")
    }
}

enum BackgroundExecutionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
