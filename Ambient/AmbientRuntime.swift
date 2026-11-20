import AppKit
import AVFoundation
import Combine
import AmbientContracts
import AmbientAgent
import AmbientBackground
import AmbientConnectors
import AmbientMemory

@MainActor
final class AmbientRuntimeState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening(audioLevel: CGFloat)
        case transcribing
        case thinking
        case working(activityLabel: String)
        case responding(text: String)
        case finished(finalText: String)
        case failed(AgentFailure)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var userText = ""
    @Published private(set) var responseText = ""
    @Published private(set) var latestBackgroundCompletion: BackgroundTask?

    func begin(userText: String = "") {
        self.userText = userText
        responseText = ""
    }

    func transition(to phase: Phase) {
        self.phase = phase
        switch phase {
        case .responding(let text), .finished(let text): responseText = text
        default: break
        }
        // Debug text stays on this Mac; credentials and tool payloads are never logged.
        if case .listening = phase { return }
        NSLog("Ambient state: %@", String(describing: phase))
    }

    func completed(_ task: BackgroundTask) {
        latestBackgroundCompletion = task
        NSLog("Ambient background completion: %@ — %@", task.title, task.status.rawValue)
    }
}

@MainActor
final class AmbientRuntime {
    let state = AmbientRuntimeState()
    let credentialSource: any AICredentialSource
    let agentSession: any AgentSession
    let completionService: any TextCompletionService
    let backgroundTaskStore: any BackgroundTaskStore
    let memoryStore: any MemoryStore
    let skillStore: any SkillStore
    let connectorService: any ConnectorService
    let speechClient: PublikSpeechClient
    let approvalSettings: BackgroundApprovalSettings
    let interaction: AmbientInteraction
    let screenTools: AmbientScreenToolProvider

    private let backgroundTaskManager: BackgroundTaskManager
    private var turnTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var playback: AVAudioPlayer?
    private var turnIdentifier = UUID()
    private var isReady = false
    private var pendingText: String?

    var spokenRepliesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "ambient.spokenRepliesEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "ambient.spokenRepliesEnabled")
            if !newValue { playback?.stop() }
        }
    }

    init() throws {
        UserDefaults.standard.register(defaults: ["ambient.spokenRepliesEnabled": true])
        let interaction = AmbientInteraction()
        let screenTools = AmbientScreenToolProvider()
        self.interaction = interaction
        self.screenTools = screenTools
        let credentialSource = PublikCredentialSource()
        let completionService = PublikAIClient(credentialSource: credentialSource)
        let memoryStore = try PersistentMemoryStore(completionService: completionService)
        let skillStore = try FileSkillStore()
        let taskManager = try BackgroundTaskManager()
        let connectorClient = AmbientConnectorClient(credentialSource: credentialSource)
        let approvalSettings = BackgroundApprovalSettings()
        self.credentialSource = credentialSource
        self.completionService = completionService
        self.memoryStore = memoryStore
        self.skillStore = skillStore
        self.backgroundTaskManager = taskManager
        self.backgroundTaskStore = taskManager
        self.connectorService = connectorClient
        self.approvalSettings = approvalSettings
        speechClient = PublikSpeechClient(credentialSource: credentialSource)
        agentSession = AmbientAgentSession(credentialSource: credentialSource, toolProviders: [
            PublikWebSearchProvider(credentialSource: credentialSource),
            BackgroundToolProvider(manager: taskManager, approvalSettings: approvalSettings) { title, detail in
                await interaction.approve(title: title, detail: detail)
            },
            ComposioToolProvider(client: connectorClient) { url in await interaction.authorize(url) },
            MemoryToolProvider(store: memoryStore), SkillToolProvider(store: skillStore), screenTools
        ])
    }

    func start() {
        guard startupTask == nil else { return }
        startupTask = Task {
            // Subscribe before sign-in can enable any tools, so even short tasks surface.
            let completions = await backgroundTaskManager.completions()
            completionTask = Task { [weak self] in
                for await task in completions {
                    guard let self, !Task.isCancelled else { return }
                    state.completed(task)
                }
            }
            _ = await Publik.ensureSignedIn(interaction)
            guard !Task.isCancelled else { return }
            guard await credentialSource.credential() != nil else {
                state.transition(to: .failed(.notSignedIn))
                return
            }
            isReady = true
            NSLog("Ambient sign-in ready")
            if let pendingText { self.pendingText = nil; submit(text: pendingText) }
            #if DEBUG
            // Exercises the exact same transcription path as microphone recordings.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--transcribe-wav"), arguments.indices.contains(index + 1) {
                do { submit(recordedWAV: try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) }
                catch { state.transition(to: .failed(.other(message: error.localizedDescription))) }
            }
            #endif
        }
    }

    /// Every subscriber gets its own stream, including the runtime's logging subscriber.
    func backgroundCompletions() async -> AsyncStream<BackgroundTask> {
        await backgroundTaskManager.completions()
    }

    func beginListening() {
        cancelCurrentTurn()
        guard isReady else {
            state.transition(to: .failed(.other(message: "Finish signing in with publik before recording.")))
            return
        }
        state.begin()
        state.transition(to: .listening(audioLevel: 0))
    }

    func updateAudioLevel(_ level: CGFloat) {
        if case .listening = state.phase { state.transition(to: .listening(audioLevel: level)) }
    }

    func submit(recordedWAV: Data) {
        startTurn { [speechClient] in
            try await speechClient.transcribe(wavData: recordedWAV)
        }
    }

    func submit(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard isReady else { pendingText = text; return }
        startTurn(text: text) { text }
    }

    private func startTurn(text: String? = nil, transcription: @escaping () async throws -> String) {
        cancelCurrentTurn()
        guard isReady else {
            state.transition(to: .failed(.notSignedIn))
            return
        }
        let identifier = turnIdentifier
        state.begin(userText: text ?? "")
        state.transition(to: text == nil ? .transcribing : .thinking)
        turnTask = Task {
            defer { if identifier == turnIdentifier { turnTask = nil } }
            // Cancellation is ordered before send, rather than an unstructured cancel racing the new turn.
            await cancellationTask?.value
            guard isCurrent(identifier) else { return }
            do {
                let userText = try await transcription().trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !userText.isEmpty else { state.transition(to: .idle); return }
                state.begin(userText: userText)
                state.transition(to: .thinking)
                var accumulatedText = ""
                var activities: [(identifier: String, label: String)] = []
                for await event in agentSession.send(UserTurn(text: userText)) {
                    guard isCurrent(identifier) else { return }
                    switch event {
                    case .textDelta(let fragment):
                        accumulatedText += fragment
                        state.transition(to: .responding(text: accumulatedText))
                    case .toolStarted(let callID, let toolName, let activityLabel):
                        activities.append((callID, activityLabel))
                        NSLog("Ambient tool started: %@", toolName)
                        state.transition(to: .working(activityLabel: activityLabel))
                    case .toolFinished(let callID, let toolName, let isError):
                        activities.removeAll { $0.identifier == callID }
                        NSLog("Ambient tool finished: %@ error=%@", toolName, String(isError))
                        if let activity = activities.last { state.transition(to: .working(activityLabel: activity.label)) }
                        else { state.transition(to: .thinking) }
                    case .finished(let finalText):
                        state.transition(to: .finished(finalText: finalText))
                        await memoryStore.learn(fromUserText: userText, assistantText: finalText)
                        guard isCurrent(identifier), spokenRepliesEnabled else { return }
                        try await speak(finalText, identifier: identifier)
                    case .failed(let failure): state.transition(to: .failed(failure))
                    }
                }
            } catch {
                guard isCurrent(identifier) else { return }
                state.transition(to: .failed(error as? AgentFailure ?? .other(message: error.localizedDescription)))
            }
        }
    }

    private func speak(_ text: String, identifier: UUID) async throws {
        // publik limits one speech call to 4096 characters. Speak longer replies in order.
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(remainder.startIndex, offsetBy: min(remainder.count, 4096))
            let chunk = String(remainder[..<end])
            remainder = remainder[end...]
            let audio = try await speechClient.synthesize(text: chunk)
            guard isCurrent(identifier), spokenRepliesEnabled else { return }
            NSLog("Ambient speech synthesis succeeded: %ld bytes", audio.count)
            let player = try AVAudioPlayer(data: audio)
            playback = player
            guard player.prepareToPlay(), player.play() else {
                throw AgentFailure.other(message: "The spoken reply could not start playing.")
            }
            NSLog("Ambient speech playback started")
            while player.isPlaying {
                try await Task.sleep(for: .milliseconds(50))
                guard isCurrent(identifier), spokenRepliesEnabled else { return }
            }
        }
    }

    private func isCurrent(_ identifier: UUID) -> Bool { identifier == turnIdentifier && !Task.isCancelled }

    func cancelCurrentTurn() {
        turnIdentifier = UUID()
        if turnTask != nil { NSLog("Ambient turn cancelled; playback stopped") }
        turnTask?.cancel()
        turnTask = nil
        playback?.stop()
        playback = nil
        let priorCancellation = cancellationTask
        cancellationTask = Task {
            await priorCancellation?.value
            await agentSession.cancel()
        }
        interaction.cancelApproval()
        screenTools.clearCaptures()
        state.transition(to: .idle)
    }

    func stop() {
        cancelCurrentTurn()
        startupTask?.cancel()
        completionTask?.cancel()

    }
}
