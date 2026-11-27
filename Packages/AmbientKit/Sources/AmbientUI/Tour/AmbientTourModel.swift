import AmbientContracts
import Foundation
import Observation

// The guided tour teaches Ambient on the person's real desktop with the real bar. A small coach card watches what
// actually happens (keys, turns, tools, approvals, the bar's edge) and reacts to it. Nothing is simulated: the app
// feeds real events into `AmbientTourModel`, which decides what the coach says.

/// One thing the tour teaches. Each one is completed by doing it for real.
public enum AmbientTourLesson: Int, CaseIterable, Sendable {
    case talk, showScreen, handOff, connectApps, placeBar

    /// 1-based, for "2 of 5".
    public var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .talk: return "Talk to it"
        case .showScreen: return "Show it your screen"
        case .handOff: return "Hand off a job"
        case .connectApps: return "Connect your apps"
        case .placeBar: return "Put it where you like"
        }
    }

    func bodyText(shortcut: AmbientPushToTalkShortcut) -> String {
        switch self {
        case .talk:
            return "Hold \(shortcut.spokenName.replacingOccurrences(of: " + ", with: " and ")), say anything, then let go. The answer shows up in the bar."
        case .showScreen:
            return "Ask about something on your screen. Ambient looks, then points or draws to show you."
        case .handOff:
            return "Ask for something that takes a while. An agent works on it in the background while you keep going."
        case .connectApps:
            return "Link Gmail, Calendar and other apps so Ambient can read and act in them for you."
        case .placeBar:
            return "Drag the bar to any edge of your screen. It stays where you leave it."
        }
    }

    /// What to say out loud, shown as something to say rather than a button that does it for them.
    var suggestedPhrase: String? {
        switch self {
        case .talk: return "What can you help me with?"
        case .showScreen: return "Show me where the Apple menu is."
        case .handOff: return "Start an agent to find three good pizza places near me."
        case .connectApps, .placeBar: return nil
        }
    }

    /// The quiet way past the lesson. The optional lessons say so in their own words.
    var skipTitle: String {
        switch self {
        case .talk, .showScreen, .handOff: return "Skip"
        case .connectApps: return "Later"
        case .placeBar: return "It's fine here"
        }
    }

    /// Lessons completed by speaking to Ambient. The coach follows the voice turn on these.
    var isVoiceLesson: Bool {
        switch self {
        case .talk, .showScreen, .handOff: return true
        case .connectApps, .placeBar: return false
        }
    }

    /// Permissions without which the lesson cannot work, most specific first so the coach names the real blocker.
    var requiredPermissions: [AmbientPermissionKind] {
        switch self {
        case .talk, .handOff: return [.accessibility, .microphone]
        case .showScreen: return [.screenRecording, .accessibility, .microphone]
        case .connectApps, .placeBar: return []
        }
    }
}

/// Where the tour is: on a lesson, or on the closing cheat sheet.
public enum AmbientTourStep: Equatable, Sendable {
    case lesson(AmbientTourLesson)
    case finished
}

/// The coach's live line: what is happening right now, in a few words.
public struct AmbientTourStatus: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Nothing has happened yet; the coach is waiting for the person.
        case waiting
        /// The keys are held and Ambient is listening.
        case listening
        /// Ambient is thinking, using a tool or answering.
        case working
        /// A gentle pointer toward the lesson. Never a scolding.
        case nudge
        /// Something is in the way; usually comes with an action that fixes it.
        case problem
        /// The lesson is done.
        case done
    }

    public enum Action: Equatable, Sendable {
        case fixPermission(AmbientPermissionKind, AmbientPermissionStatus)
        case tryAgain
    }

    public var tone: Tone
    public var text: String
    public var action: Action?

    public init(tone: Tone, text: String, action: Action? = nil) {
        self.tone = tone
        self.text = text
        self.action = action
    }
}

/// The tour's state machine. The app feeds it real events; the coach card draws `step`, `status` and
/// `isCurrentLessonComplete`, and hears intent back through the `on…` closures. It never touches windows, so every
/// rule can be tested on its own.
@MainActor
@Observable
public final class AmbientTourModel {

    /// A hold shorter than this is a brush of the keys, not someone talking.
    public static let shortestRealHoldDuration: TimeInterval = 0.35
    /// Tools that mean Ambient looked at or marked up the screen.
    static let screenToolNames: Set<String> = ["look_at_screen", "draw_on_screen", "point_at"]
    static let spawnAgentToolName = "spawn_agent"

    // MARK: State the coach draws

    public private(set) var step: AmbientTourStep = .lesson(.talk)
    public private(set) var isCurrentLessonComplete = false
    /// True while the push-to-talk keys are down, so the coach's keycaps light up.
    public private(set) var isShortcutHeld = false
    public var shortcut: AmbientPushToTalkShortcut
    public private(set) var dockEdge: FlowBarDockEdge
    public private(set) var permissionStatuses: [AmbientPermissionKind: AmbientPermissionStatus] = [:]
    /// Names of the apps the person has connected, as the connector service last reported them.
    public private(set) var connectedAppNames: [String] = []
    /// The person opened Connectors from this lesson and is presumably finishing in the browser.
    public private(set) var hasOpenedConnectors = false

    // MARK: Behaviour

    /// How long the coach waits without any sign of the person before offering one hint.
    public var idleHintDelay: TimeInterval = 20

    // MARK: Intents the app handles

    /// Fix a missing permission: ask the system, or open System Settings when it has already been asked.
    public var onFixPermission: ((AmbientPermissionKind) -> Void)?
    /// Open Settings on the Connectors page.
    public var onOpenConnectors: (() -> Void)?
    /// The tour ended, finished or not. The app records completion and closes the coach.
    public var onFinish: (() -> Void)?
    /// The person moved past a lesson: true when it was completed, false when skipped.
    public var onLessonEnded: ((AmbientTourLesson, Bool) -> Void)?

    // MARK: Private

    /// What the current turn is doing, set by events. Nil means nothing is happening and the lesson's resting line
    /// shows.
    private var activityStatus: AmbientTourStatus?
    private var currentTurnWasTyped = false
    private var lastHoldWasTooShort = false
    private var approvalWasDeniedThisTurn = false
    private var hasAcknowledgedReplyThisTurn = false
    private var dockEdgeWhenLessonBegan: FlowBarDockEdge
    private var hasShownIdleHintThisLesson = false
    private var idleHintTask: Task<Void, Never>?

    public init(shortcut: AmbientPushToTalkShortcut = .controlOption, dockEdge: FlowBarDockEdge = .bottom) {
        self.shortcut = shortcut
        self.dockEdge = dockEdge
        self.dockEdgeWhenLessonBegan = dockEdge
    }

    /// Starts the idle-hint clock for the first lesson. Call once the coach is on screen.
    public func begin() {
        scheduleIdleHint()
    }

    // MARK: Derived

    public var currentLesson: AmbientTourLesson? {
        if case .lesson(let lesson) = step { return lesson }
        return nil
    }

    /// The line under the lesson. A finished lesson says so; a missing permission comes next because nothing else
    /// can work without it; then whatever the current turn is doing; then the lesson's own resting line.
    public var status: AmbientTourStatus {
        guard let lesson = currentLesson else { return AmbientTourStatus(tone: .done, text: "") }
        if isCurrentLessonComplete { return completedStatus(for: lesson) }
        if let missingPermission = firstMissingPermission(for: lesson) {
            return AmbientTourStatus(tone: .problem, text: Self.missingPermissionText(missingPermission),
                                     action: .fixPermission(missingPermission, permissionStatuses[missingPermission] ?? .notYetAsked))
        }
        return activityStatus ?? restingStatus(for: lesson)
    }

    private func firstMissingPermission(for lesson: AmbientTourLesson) -> AmbientPermissionKind? {
        // An unreported permission is treated as granted: the coach never guesses that something is broken.
        lesson.requiredPermissions.first { kind in
            guard let permissionStatus = permissionStatuses[kind] else { return false }
            return permissionStatus != .granted
        }
    }

    static func missingPermissionText(_ kind: AmbientPermissionKind) -> String {
        switch kind {
        case .microphone: return "Ambient needs the microphone to hear you."
        case .accessibility: return "Ambient needs Accessibility to notice the keys."
        case .screenRecording: return "Ambient needs Screen Recording to see your screen."
        case .speechRecognition: return "Ambient needs Speech Recognition to understand you on this Mac."
        }
    }

    private func restingStatus(for lesson: AmbientTourLesson) -> AmbientTourStatus {
        switch lesson {
        case .talk, .showScreen, .handOff:
            return AmbientTourStatus(tone: .waiting, text: "Waiting for you to hold the keys.")
        case .connectApps:
            return AmbientTourStatus(tone: .waiting, text: hasOpenedConnectors
                ? "Waiting for you to finish in the browser."
                : "No apps connected yet.")
        case .placeBar:
            return AmbientTourStatus(tone: .waiting, text: "The bar is on the \(dockEdge.displayName.lowercased()) edge.")
        }
    }

    /// A short fact beside Next. The longer "what this means" goes in `completionNote`.
    private func completedStatus(for lesson: AmbientTourLesson) -> AmbientTourStatus {
        switch lesson {
        case .talk: return AmbientTourStatus(tone: .done, text: "Done. Ambient heard you.")
        case .showScreen: return AmbientTourStatus(tone: .done, text: "Done. Ambient saw your screen.")
        case .handOff: return AmbientTourStatus(tone: .done, text: "Done. Your agent is working.")
        case .connectApps: return AmbientTourStatus(tone: .done, text: "\(Self.listedAppNames(connectedAppNames)) connected.")
        case .placeBar: return AmbientTourStatus(tone: .done, text: "The bar is on the \(dockEdge.displayName.lowercased()) edge now.")
        }
    }

    /// Replaces the lesson's instructions once it is done: what just happened and what to know about it.
    public var completionNote: String? {
        guard let lesson = currentLesson, isCurrentLessonComplete else { return nil }
        switch lesson {
        case .talk: return "That's the whole gesture. It works from any app, any time."
        case .showScreen: return "The drawing clears when you make your next request."
        case .handOff: return "The dot in the bar is your agent working. Click the bar to see it. You can keep going."
        case .connectApps: return "Ask about it any time. You can connect more in Settings."
        case .placeBar: return "Move it again whenever you like."
        }
    }

    /// "Gmail is", "Gmail and Calendar are", "Gmail, Calendar and 2 more are".
    static func listedAppNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return "An app is"
        case 1: return "\(names[0]) is"
        case 2: return "\(names[0]) and \(names[1]) are"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more are"
        }
    }

    // MARK: Inputs: the voice turn

    public func shortcutPressed() {
        isShortcutHeld = true
        beginTurn(isTyped: false)
        activityStatus = AmbientTourStatus(tone: .listening, text: "Listening…")
        noteActivity()
    }

    public func shortcutReleased(heldFor holdDuration: TimeInterval) {
        guard isShortcutHeld else { return }
        isShortcutHeld = false
        if holdDuration < Self.shortestRealHoldDuration {
            lastHoldWasTooShort = true
            activityStatus = AmbientTourStatus(tone: .nudge, text: "Keep both keys held while you talk.")
        } else {
            activityStatus = AmbientTourStatus(tone: .working, text: "Thinking…")
        }
        noteActivity()
    }

    /// The recording was transcribed and nothing was heard (the runtime went from transcribing straight to idle).
    public func heardNothing() {
        // While the keys are down a new turn has already started; after a brief tap, the tap nudge is the better one.
        guard !isShortcutHeld, !lastHoldWasTooShort else { return }
        activityStatus = AmbientTourStatus(tone: .nudge, text: "I didn't catch anything. Hold the keys and speak, then let go.")
        noteActivity()
    }

    /// The request reached the agent.
    public func thinkingStarted() {
        guard !isShortcutHeld else { return }
        lastHoldWasTooShort = false
        activityStatus = AmbientTourStatus(tone: .working, text: "Thinking…")
        noteActivity()
    }

    /// The person typed into the bar instead of talking.
    public func typedRequestSubmitted() {
        beginTurn(isTyped: true)
        activityStatus = AmbientTourStatus(tone: .working, text: "Thinking…")
        noteActivity()
    }

    /// Every event from the agent session, in order, exactly as the bar receives them.
    public func apply(_ event: AgentEvent) {
        switch event {
        case .textDelta(let fragment):
            guard !fragment.isEmpty, !hasAcknowledgedReplyThisTurn else { return }
            hasAcknowledgedReplyThisTurn = true
            // A denial or a failed tool explains more than "here it comes" does; it stays until the turn ends.
            if let currentTone = activityStatus?.tone, currentTone == .nudge || currentTone == .problem { return }
            activityStatus = AmbientTourStatus(tone: .working, text: "Here it comes. The answer is in the bar.")

        case .toolStarted(_, let toolName, let activityLabel):
            let label = activityLabel.isEmpty ? FlowBarModel.readableToolName(toolName) : activityLabel
            activityStatus = AmbientTourStatus(tone: .working, text: "\(label)…")

        case .toolFinished(_, let toolName, let isError):
            toolFinished(toolName: toolName, isError: isError)

        case .finished:
            turnFinished()

        case .failed(let failure):
            switch failure {
            case .cancelled:
                // A cancelled turn leaves nothing to say, except a nudge the person has not read yet.
                if activityStatus?.tone != .nudge { activityStatus = nil }
            case .notSignedIn:
                activityStatus = AmbientTourStatus(tone: .problem, text: "You are signed out. Sign in from Settings, then try again.", action: .tryAgain)
            case .paymentRequired(let message, _), .other(let message):
                activityStatus = AmbientTourStatus(tone: .problem, text: message, action: .tryAgain)
            }
        }
        noteActivity()
    }

    private func toolFinished(toolName: String, isError: Bool) {
        guard let lesson = currentLesson, !isCurrentLessonComplete else { return }
        switch lesson {
        case .showScreen where Self.screenToolNames.contains(toolName):
            if isError {
                activityStatus = AmbientTourStatus(tone: .problem, text: "Ambient couldn't use your screen that time.", action: .tryAgain)
            } else {
                completeCurrentLesson()
            }
        case .handOff where toolName == Self.spawnAgentToolName:
            if !isError {
                completeCurrentLesson()
            } else if !approvalWasDeniedThisTurn {
                activityStatus = AmbientTourStatus(tone: .problem, text: "The agent couldn't start.", action: .tryAgain)
            }
        default:
            break
        }
    }

    private func turnFinished() {
        guard let lesson = currentLesson, !isCurrentLessonComplete else {
            activityStatus = nil
            return
        }
        switch lesson {
        case .talk:
            if currentTurnWasTyped {
                activityStatus = AmbientTourStatus(tone: .nudge, text: "Typing works too. Now try it with your voice.")
            } else {
                completeCurrentLesson()
            }
        case .showScreen:
            // The reply stays in the bar as usual; the coach stays and points back at the lesson.
            activityStatus = AmbientTourStatus(tone: .nudge, text: "That was a regular answer. To use your screen, try the phrase above.")
        case .handOff:
            if approvalWasDeniedThisTurn { return }
            activityStatus = AmbientTourStatus(tone: .nudge, text: "That was answered right away. Begin with \u{201C}Start an agent to\u{201D} to hand it off.")
        case .connectApps, .placeBar:
            activityStatus = nil
        }
    }

    // MARK: Inputs: approvals, the bar, apps, permissions

    public func approvalRequested(kind: FlowBarApprovalRequest.Kind) {
        guard currentLesson == .handOff, !isCurrentLessonComplete, kind == .backgroundAgent else { return }
        activityStatus = AmbientTourStatus(tone: .nudge, text: "Ambient asks before it starts work. Press Allow in the bar.")
        noteActivity()
    }

    public func approvalAnswered(isAllowed: Bool) {
        guard currentLesson == .handOff, !isCurrentLessonComplete else { return }
        if isAllowed {
            activityStatus = AmbientTourStatus(tone: .working, text: "Starting the agent…")
        } else {
            approvalWasDeniedThisTurn = true
            activityStatus = AmbientTourStatus(tone: .nudge, text: "No agent started. Ask again when you're ready, then press Allow.")
        }
        noteActivity()
    }

    public func dockEdgeChanged(to newEdge: FlowBarDockEdge) {
        dockEdge = newEdge
        guard currentLesson == .placeBar, !isCurrentLessonComplete, newEdge != dockEdgeWhenLessonBegan else { return }
        completeCurrentLesson()
    }

    /// The names of every connected app, whenever the app checks.
    public func connectedAppsChanged(names: [String]) {
        connectedAppNames = names
        guard currentLesson == .connectApps, !isCurrentLessonComplete, !names.isEmpty else { return }
        completeCurrentLesson()
    }

    public func permissionStatusesChanged(_ statuses: [AmbientPermissionKind: AmbientPermissionStatus]) {
        permissionStatuses = statuses
    }

    // MARK: Intents from the coach

    public func advanceToNextStep() {
        guard let lesson = currentLesson else { return }
        onLessonEnded?(lesson, isCurrentLessonComplete)
        let nextLessonIndex = lesson.rawValue + 1
        if let nextLesson = AmbientTourLesson(rawValue: nextLessonIndex) {
            step = .lesson(nextLesson)
        } else {
            step = .finished
        }
        resetForNewLesson()
    }

    public func skipCurrentLesson() {
        advanceToNextStep()
    }

    public func endTour() {
        idleHintTask?.cancel()
        idleHintTask = nil
        onFinish?()
    }

    public func performStatusAction(_ action: AmbientTourStatus.Action) {
        switch action {
        case .fixPermission(let kind, _):
            onFixPermission?(kind)
        case .tryAgain:
            activityStatus = nil
            noteActivity()
        }
    }

    public func openConnectors() {
        hasOpenedConnectors = true
        onOpenConnectors?()
        noteActivity()
    }

    // MARK: Private helpers

    private func beginTurn(isTyped: Bool) {
        currentTurnWasTyped = isTyped
        lastHoldWasTooShort = false
        approvalWasDeniedThisTurn = false
        hasAcknowledgedReplyThisTurn = false
    }

    private func completeCurrentLesson() {
        isCurrentLessonComplete = true
        activityStatus = nil
        idleHintTask?.cancel()
        idleHintTask = nil
    }

    private func resetForNewLesson() {
        isCurrentLessonComplete = false
        activityStatus = nil
        hasOpenedConnectors = false
        hasShownIdleHintThisLesson = false
        dockEdgeWhenLessonBegan = dockEdge
        scheduleIdleHint()
    }

    /// Anything the person does restarts the quiet clock.
    private func noteActivity() {
        scheduleIdleHint()
    }

    private func scheduleIdleHint() {
        idleHintTask?.cancel()
        idleHintTask = nil
        guard currentLesson != nil, !isCurrentLessonComplete, !hasShownIdleHintThisLesson else { return }
        let delay = idleHintDelay
        idleHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.showIdleHintIfStillQuiet()
        }
    }

    /// One gentle hint per lesson, and only while nothing else is being said.
    private func showIdleHintIfStillQuiet() {
        guard let lesson = currentLesson, !isCurrentLessonComplete, !hasShownIdleHintThisLesson,
              !isShortcutHeld, activityStatus == nil else { return }
        hasShownIdleHintThisLesson = true
        activityStatus = AmbientTourStatus(tone: .nudge, text: idleHintText(for: lesson))
    }

    private func idleHintText(for lesson: AmbientTourLesson) -> String {
        switch lesson {
        case .talk: return "Press both keys first and keep them down, then start talking."
        case .showScreen, .handOff: return "Hold the keys, read the phrase above out loud, then let go."
        case .connectApps: return "This one is optional. Choose Later to move on."
        case .placeBar: return "Grab the small bar and drag it toward another edge."
        }
    }
}
