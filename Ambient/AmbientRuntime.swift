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

    var onReady: (() -> Void)?
    var onAgentEvent: ((AgentEvent) -> Void)?

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
        let webSearch = PublikWebSearchProvider(credentialSource: credentialSource)
        let connectors = ComposioToolProvider(client: connectorClient) { url in await interaction.authorize(url) }
        let memoryTools = MemoryToolProvider(store: memoryStore), skillTools = SkillToolProvider(store: skillStore)
        // A background agent is a second conversation on the person's publik account: the same tools minus the
        // screen and spawning, plus a shell confined to its working directory, and more reasoning than the bar.
        let ambientAgent: BackgroundTaskManager.InProcessAgent = { prompt, workingDirectory, reportActivity in
            let session = AmbientAgentSession(credentialSource: credentialSource,
                toolProviders: [AgentWorkspaceToolProvider(workingDirectory: workingDirectory), webSearch, connectors, memoryTools, skillTools],
                baseSystemPrompt: ambientBackgroundAgentPrompt, reasoningEffort: "high")
            for await event in session.send(UserTurn(text: prompt)) {
                switch event {
                case .toolStarted(_, _, let activityLabel): reportActivity(activityLabel)
                case .finished(let finalText): return finalText
                case .failed(let failure): throw failure
                case .textDelta, .toolFinished: break
                }
            }
            throw CancellationError()
        }
        // The bar answers and acts with as little deliberation as the model allows; agents do the thinking.
        agentSession = AmbientAgentSession(credentialSource: credentialSource, toolProviders: [
            webSearch,
            BackgroundToolProvider(manager: taskManager, approvalSettings: approvalSettings, ambientAgent: ambientAgent) { title, detail in
                await interaction.approve(title: title, detail: detail)
            },
            connectors, memoryTools, skillTools, screenTools
        ], reasoningEffort: "low")
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
            interaction.closeGate()
            isReady = true
            onReady?()
            NSLog("Ambient sign-in ready")
            if let pendingText { self.pendingText = nil; submit(text: pendingText) }
            #if DEBUG
            // Exercises the exact same transcription path as microphone recordings.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--transcribe-wav"), arguments.indices.contains(index + 1) {
                do { submit(recordedWAV: try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))) }
                catch { reportFailure(.other(message: error.localizedDescription)) }
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
            // On-device recognition answers in a fraction of the time and keeps the audio on this Mac.
            let started = Date()
            if let text = await AmbientLocalTranscriber.transcribe(wavData: recordedWAV) {
                NSLog("Ambient transcribed on this Mac in %.2f s", Date().timeIntervalSince(started))
                return text
            }
            let text = try await speechClient.transcribe(wavData: recordedWAV)
            NSLog("Ambient transcribed with publik in %.2f s", Date().timeIntervalSince(started))
            return text
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
                NSLog("Ambient heard: %@", userText)
                state.begin(userText: userText)
                state.transition(to: .thinking)
                var accumulatedText = ""
                // Speech starts with the first finished sentence instead of waiting for the whole reply.
                let speech = spokenRepliesEnabled ? startSpeaking(identifier: identifier) : nil
                defer { speech?.sentences.finish() }
                var unspokenText = ""
                var activities: [(identifier: String, label: String)] = []
                for await event in agentSession.send(UserTurn(text: userText)) {
                    guard isCurrent(identifier) else { return }
                    onAgentEvent?(event)
                    switch event {
                    case .textDelta(let fragment):
                        guard !fragment.isEmpty else { continue }
                        accumulatedText += fragment
                        state.transition(to: .responding(text: accumulatedText))
                        if let speech {
                            unspokenText += fragment
                            while let sentence = Self.takeSentence(from: &unspokenText) { speech.sentences.yield(sentence) }
                        }
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
                        // Learning is a separate model call; it must not delay the reply or its speech.
                        Task { [memoryStore] in await memoryStore.learn(fromUserText: userText, assistantText: finalText) }
                        if let speech {
                            speech.sentences.yield(unspokenText)
                            speech.sentences.finish()
                            try await speech.playback.value
                        }
                    case .failed(let failure): state.transition(to: .failed(failure))
                    }
                }
            } catch {
                guard isCurrent(identifier) else { return }
                reportFailure(error as? AgentFailure ?? .other(message: error.localizedDescription))
            }
        }
    }

    /// The first complete sentence of `text`, removed from it. A sentence ends at ". ", "! ", "? " or a line break.
    static func takeSentence(from text: inout String) -> String? {
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character.isNewline || (character == " " && previous.map { ".!?".contains($0) } == true) {
                let sentence = String(text[..<index])
                text = String(text[text.index(after: index)...])
                return sentence
            }
            previous = character
        }
        return nil
    }

    /// Synthesis of each sentence starts as soon as it arrives; playback keeps them in order.
    private func startSpeaking(identifier: UUID) -> (sentences: AsyncStream<String>.Continuation, playback: Task<Void, Error>) {
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        let (clips, clipContinuation) = AsyncStream<Task<Data, Error>>.makeStream()
        Task { [speechClient] in
            for await sentence in sentences {
                // publik limits one speech call to 4096 characters.
                var remainder = sentence.trimmingCharacters(in: .whitespacesAndNewlines)[...]
                while !remainder.isEmpty {
                    let chunk = String(remainder.prefix(4096))
                    remainder = remainder.dropFirst(4096)
                    clipContinuation.yield(Task { try await speechClient.synthesize(text: chunk) })
                }
            }
            clipContinuation.finish()
        }
        let playback = Task {
            for await clip in clips {
                let audio = try await clip.value
                guard isCurrent(identifier), spokenRepliesEnabled else { return }
                let player = try AVAudioPlayer(data: audio)
                self.playback = player
                guard player.prepareToPlay(), player.play() else {
                    throw AgentFailure.other(message: "The spoken reply could not start playing.")
                }
                NSLog("Ambient speech playback started")
                while player.isPlaying {
                    try await Task.sleep(for: .milliseconds(30))
                    guard isCurrent(identifier), spokenRepliesEnabled else { return }
                }
            }
        }
        return (continuation, playback)
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

    func reportFailure(_ failure: AgentFailure) {
        state.transition(to: .failed(failure))
        onAgentEvent?(.failed(failure))
    }

    func stop() {
        cancelCurrentTurn()
        startupTask?.cancel()
        completionTask?.cancel()

    }
}
