import AmbientContracts
import AppKit
import Foundation
import Observation

/// One tool call in the current turn, as the bar shows it.
public struct FlowBarToolCall: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case running, succeeded, failed }
    public var id: String
    public var toolName: String
    /// A few words, such as "Searching Gmail".
    public var activityLabel: String
    public var status: Status

    public init(id: String, toolName: String, activityLabel: String, status: Status) {
        self.id = id
        self.toolName = toolName
        self.activityLabel = activityLabel
        self.status = status
    }
}

/// An error in plain words, with at most one link.
public struct FlowBarErrorNotice: Equatable, Sendable {
    public enum LinkDestination: Equatable, Sendable {
        case webPage(URL)
        /// Opens Ambient's settings (for example to sign in again).
        case settings
    }

    public struct Link: Equatable, Sendable {
        public var title: String
        public var destination: LinkDestination
        public init(title: String, destination: LinkDestination) {
            self.title = title
            self.destination = destination
        }
    }

    public var message: String
    public var link: Link?

    public init(message: String, link: Link? = nil) {
        self.message = message
        self.link = link
    }
}

/// A question Ambient must ask before doing something with consequences.
public struct FlowBarApprovalRequest: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `detail` is the exact command line that will run.
        case shellCommand
        /// `detail` is what the background agent will be asked to do.
        case backgroundAgent
        case other
    }

    public var id: UUID
    public var title: String
    public var detail: String
    public var kind: Kind

    public init(id: UUID = UUID(), title: String, detail: String, kind: Kind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

/// Where the current voice or typed turn is.
public enum FlowBarTurnPhase: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case working
    case responding
    case replyFinished
    case error(FlowBarErrorNotice)
}

/// What the bar is drawing right now. Derived from the turn, the pointer and the tasks; never set directly.
public enum FlowBarPresentation: String, Equatable, Sendable, CaseIterable {
    case resting
    case hovering
    case listening
    case transcribing
    case thinking
    case working
    case responding
    case reply
    case error
    case approval
    case typing
    case taskTray
    case taskFinishedNotice

    /// Pill-shaped presentations; the rest are cards with a fixed corner radius.
    var isCapsule: Bool {
        switch self {
        case .resting, .hovering, .listening, .transcribing, .thinking, .working, .typing, .taskFinishedNotice: return true
        case .responding, .reply, .error, .approval, .taskTray: return false
        }
    }

    /// On the left and right edges these keep the edge's upright orientation; every other presentation becomes a
    /// horizontal surface that grows sideways away from the edge, because text cannot be read upright.
    var followsEdgeOrientation: Bool {
        switch self {
        case .resting, .hovering, .listening, .transcribing: return true
        default: return false
        }
    }
}

/// The flow bar's state. The app pushes state in through the methods below and hears intent back through the
/// `on…` closures. Everything here runs on the main actor.
@MainActor
@Observable
public final class FlowBarModel {

    // MARK: State the app pushes in

    public private(set) var turnPhase: FlowBarTurnPhase = .idle
    /// Microphone level from 0 to 1. Set it as often as you have it (30 to 60 times a second is ideal).
    public private(set) var audioLevel: Double = 0
    /// The newest activity line, such as "Searching Gmail".
    public private(set) var currentActivityLine: String?
    public private(set) var toolCallsThisTurn: [FlowBarToolCall] = []
    /// The whole reply received so far.
    public private(set) var replyText: String = ""
    /// The part of the reply shown on screen. It trails `replyText` slightly so text arriving in bursts still
    /// appears as an even stream.
    public private(set) var displayedReplyText: String = ""
    public private(set) var pendingApproval: FlowBarApprovalRequest?
    /// Background tasks, newest first, exactly as the store sends them.
    public private(set) var backgroundTasks: [BackgroundTask] = []
    /// A task that finished while the bar was resting, shown briefly to draw the eye.
    public private(set) var recentlyFinishedTask: BackgroundTask?

    // MARK: Interface state

    public private(set) var isTyping = false {
        didSet { if isTyping != oldValue { onTypingStateChanged?(isTyping) } }
    }
    public var typedText = ""
    public private(set) var isTaskTrayExpanded = false
    /// Set by the panel controller from the real pointer position.
    public internal(set) var isPointerHovering = false
    /// Hovering the working pill reveals the steps taken so far.
    var isShowingToolCallTrail = false
    /// Copy, Reply and Dismiss under a finished answer. Off for the onboarding practice bar, where they mean nothing.
    var showsReplyActions = true

    // MARK: Placement (owned by the panel controller)

    public internal(set) var dockEdge: FlowBarDockEdge = .bottom
    /// Where the middle of the bar's edge-facing side sits, in the panel's SwiftUI coordinates.
    var barAnchorInPanel: CGPoint = .zero
    /// While dragging, the bar's centre in the panel's SwiftUI coordinates. Nil when docked.
    var draggedBarCentreInPanel: CGPoint?
    var isBeingDragged: Bool { draggedBarCentreInPanel != nil }

    // MARK: Hooks for the panel controller

    /// The glass surface's frame in the panel's SwiftUI coordinates, whenever it changes.
    var onSurfaceFrameChanged: ((CGRect) -> Void)?
    var onBarDragChanged: (() -> Void)?
    var onBarDragEnded: (() -> Void)?
    var onTypingStateChanged: ((Bool) -> Void)?

    // MARK: Behaviour

    /// How long a finished reply stays when the pointer is not over it. Zero keeps it until dismissed.
    public var finishedReplyLingerDuration: TimeInterval = 24
    /// How long an error stays when the pointer is not over it. Zero keeps it until dismissed.
    public var errorLingerDuration: TimeInterval = 16
    /// How long the "task finished" notice shows on the resting bar.
    public var taskFinishedNoticeDuration: TimeInterval = 5

    // MARK: Intents the app handles

    public var onCancelTurn: (() -> Void)?
    public var onSubmitTypedText: ((String) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onCancelBackgroundTask: ((UUID) -> Void)?
    public var onDismissBackgroundTask: ((UUID) -> Void)?
    public var onOpenBackgroundTaskTranscript: ((UUID) -> Void)?
    public var onDockEdgeChanged: ((FlowBarDockEdge) -> Void)?
    /// Opens a link from a reply or an error. Defaults to the person's browser.
    public var onOpenURL: (URL) -> Void = { url in NSWorkspace.shared.open(url) }

    // MARK: Private

    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var lingerTask: Task<Void, Never>?
    private var taskFinishedNoticeTask: Task<Void, Never>?
    private var replyRevealTask: Task<Void, Never>?
    /// When true, the displayed reply always equals the full reply. Used for still captures. Reduce Motion does
    /// not turn the paced reveal off: the stream is information arriving, not decoration.
    public var revealsReplyInstantly = false

    public init() {}

    // MARK: Derived

    /// What the bar draws. Approval outranks everything because the turn is blocked on it; listening outranks
    /// typing because holding the shortcut is an explicit request to talk.
    public var presentation: FlowBarPresentation {
        if pendingApproval != nil { return .approval }
        switch turnPhase {
        case .listening: return .listening
        case .transcribing: return .transcribing
        default: break
        }
        if isTyping { return .typing }
        switch turnPhase {
        case .error: return .error
        case .responding: return .responding
        case .replyFinished: return .reply
        case .working: return .working
        case .thinking: return .thinking
        case .idle, .listening, .transcribing: break
        }
        if isTaskTrayExpanded && !backgroundTasks.isEmpty { return .taskTray }
        if isBeingDragged { return .resting }
        if recentlyFinishedTask != nil && !isPointerHovering { return .taskFinishedNotice }
        if isPointerHovering { return .hovering }
        return .resting
    }

    public var runningBackgroundTaskCount: Int { backgroundTasks.filter { $0.status == .running }.count }

    var currentErrorNotice: FlowBarErrorNotice? {
        if case .error(let notice) = turnPhase { return notice }
        return nil
    }

    var isReplyStillStreaming: Bool { turnPhase == .responding || displayedReplyText.count < replyText.count }

    // MARK: Inputs: the voice turn

    /// The shortcut went down: start a new turn.
    public func beginListening() {
        resetTurn()
        isTyping = false
        isTaskTrayExpanded = false
        turnPhase = .listening
    }

    public func updateAudioLevel(_ level: Double) {
        audioLevel = min(max(level, 0), 1)
    }

    /// The shortcut came up and the words are being turned into text.
    public func beginTranscribing() {
        audioLevel = 0
        turnPhase = .transcribing
    }

    /// The request went to the agent.
    public func beginThinking() {
        cancelLinger()
        audioLevel = 0
        if turnPhase != .responding { turnPhase = .thinking }
    }

    /// Feed every event from `AgentSession.send` here, in order.
    public func apply(_ event: AgentEvent) {
        switch event {
        case .textDelta(let delta):
            if turnPhase != .responding { turnPhase = .responding }
            replyText += delta
            scheduleReplyReveal()

        case .toolStarted(let callID, let toolName, let activityLabel):
            let label = activityLabel.isEmpty ? Self.readableToolName(toolName) : activityLabel
            if let existingIndex = toolCallsThisTurn.firstIndex(where: { $0.id == callID }) {
                toolCallsThisTurn[existingIndex].status = .running
            } else {
                toolCallsThisTurn.append(FlowBarToolCall(id: callID, toolName: toolName, activityLabel: label, status: .running))
            }
            currentActivityLine = label
            // A tool starting mid-reply keeps the reply on screen and shows the activity under it, rather than
            // collapsing the card back into a pill.
            if turnPhase != .responding { turnPhase = .working }

        case .toolFinished(let callID, _, let isError):
            if let index = toolCallsThisTurn.firstIndex(where: { $0.id == callID }) {
                toolCallsThisTurn[index].status = isError ? .failed : .succeeded
            }
            if !toolCallsThisTurn.contains(where: { $0.status == .running }), turnPhase == .responding {
                currentActivityLine = nil
            }

        case .finished(let finalText):
            if !finalText.isEmpty { replyText = finalText }
            currentActivityLine = nil
            if replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                returnToIdle()
            } else {
                turnPhase = .replyFinished
                scheduleReplyReveal()
                scheduleLinger(after: finishedReplyLingerDuration)
            }

        case .failed(let failure):
            switch failure {
            case .cancelled:
                returnToIdle()
            case .paymentRequired(let message, let topUpURL):
                showError(FlowBarErrorNotice(message: message, link: topUpURL.map { .init(title: "Top up", destination: .webPage($0)) }))
            case .notSignedIn:
                showError(FlowBarErrorNotice(message: "You are signed out. Sign in to keep going.", link: .init(title: "Sign in", destination: .settings)))
            case .other(let message):
                showError(FlowBarErrorNotice(message: message))
            }
        }
    }

    public func showError(_ notice: FlowBarErrorNotice) {
        resolvePendingApproval(isAllowed: false)
        audioLevel = 0
        isTyping = false
        turnPhase = .error(notice)
        scheduleLinger(after: errorLingerDuration)
    }

    /// Asks the person and waits for the answer. A new request, a cancelled turn or a new turn answers "deny".
    public func requestApproval(_ request: FlowBarApprovalRequest) async -> Bool {
        resolvePendingApproval(isAllowed: false)
        cancelLinger()
        isTyping = false
        pendingApproval = request
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                resolvePendingApproval(isAllowed: false)
                return false
            }
            return await withCheckedContinuation { continuation in
                approvalContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pendingApproval?.id == request.id else { return }
                self?.resolvePendingApproval(isAllowed: false)
            }
        }
    }

    public func returnToIdle() {
        resolvePendingApproval(isAllowed: false)
        cancelLinger()
        resetTurn()
        turnPhase = .idle
    }

    /// The whole list from `BackgroundTaskStore.updates()`. Notices tasks that just finished.
    public func setBackgroundTasks(_ tasks: [BackgroundTask]) {
        let previouslyRunningIdentifiers = Set(backgroundTasks.filter { $0.status == .running }.map(\.id))
        let justFinishedTask = tasks.first { task in
            previouslyRunningIdentifiers.contains(task.id) && task.status != .running
        }
        backgroundTasks = tasks
        if tasks.isEmpty { isTaskTrayExpanded = false }
        if let justFinishedTask, !isTaskTrayExpanded {
            showTaskFinishedNotice(for: justFinishedTask)
        }
        if let shownTask = recentlyFinishedTask, !tasks.contains(where: { $0.id == shownTask.id }) {
            recentlyFinishedTask = nil
        }
    }

    // MARK: Intents from the interface

    func cancelCurrentTurn() {
        resolvePendingApproval(isAllowed: false)
        onCancelTurn?()
        returnToIdle()
    }

    /// Opens the text field. The bar does this itself on a click; the app may also call it (from a menu item).
    public func beginTyping() {
        guard turnPhase != .listening && turnPhase != .transcribing else { return }
        isTaskTrayExpanded = false
        isTyping = true
    }

    func endTyping() {
        isTyping = false
    }

    func submitTypedText() {
        let trimmedText = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        typedText = ""
        isTyping = false
        resetTurn()
        turnPhase = .thinking
        onSubmitTypedText?(trimmedText)
    }

    func openSettings() {
        onOpenSettings?()
    }

    public func answerPendingApproval(isAllowed: Bool) {
        resolvePendingApproval(isAllowed: isAllowed)
    }

    func copyReplyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(replyText, forType: .string)
    }

    /// "Reply" on a finished answer: keep the conversation and open the text field.
    func continueConversation() {
        cancelLinger()
        resetTurn()
        turnPhase = .idle
        isTyping = true
    }

    func dismissReplyOrError() {
        returnToIdle()
    }

    func followErrorLink(_ link: FlowBarErrorNotice.Link) {
        switch link.destination {
        case .webPage(let url): onOpenURL(url)
        case .settings: onOpenSettings?()
        }
        returnToIdle()
    }

    /// Opens or closes the background task tray.
    public func toggleTaskTray() {
        isTaskTrayExpanded.toggle()
        if isTaskTrayExpanded { recentlyFinishedTask = nil }
    }

    func collapseTaskTray() {
        isTaskTrayExpanded = false
    }

    func cancelBackgroundTask(_ taskID: UUID) { onCancelBackgroundTask?(taskID) }
    func dismissBackgroundTask(_ taskID: UUID) { onDismissBackgroundTask?(taskID) }
    func openBackgroundTaskTranscript(_ taskID: UUID) { onOpenBackgroundTaskTranscript?(taskID) }

    /// Holds the hover presentation regardless of where the pointer is. Only for previews and still captures,
    /// where there is no real pointer to hover with.
    public func pinHoverForPreview(_ isPinned: Bool) {
        isHoverPinnedForPreview = isPinned
        setPointerHovering(isPinned)
    }
    private var isHoverPinnedForPreview = false

    /// The pointer moved over or off the bar. Hovering a reply or error pauses its linger timer.
    func setPointerHovering(_ isHovering: Bool) {
        if isHoverPinnedForPreview && !isHovering { return }
        guard isHovering != isPointerHovering else { return }
        isPointerHovering = isHovering
        if !isHovering { isShowingToolCallTrail = false }
        switch turnPhase {
        case .replyFinished:
            if isHovering { cancelLinger() } else { scheduleLinger(after: finishedReplyLingerDuration) }
        case .error:
            if isHovering { cancelLinger() } else { scheduleLinger(after: errorLingerDuration) }
        default:
            break
        }
        if isHovering, recentlyFinishedTask != nil, presentation == .hovering {
            // The person came to look: the notice has done its job.
            recentlyFinishedTask = nil
        }
    }

    // MARK: Private helpers

    private func resetTurn() {
        replyRevealTask?.cancel()
        replyRevealTask = nil
        replyText = ""
        displayedReplyText = ""
        toolCallsThisTurn = []
        currentActivityLine = nil
        audioLevel = 0
    }

    private func resolvePendingApproval(isAllowed: Bool) {
        approvalContinuation?.resume(returning: isAllowed)
        approvalContinuation = nil
        pendingApproval = nil
    }

    private func scheduleLinger(after duration: TimeInterval) {
        cancelLinger()
        guard duration > 0, !isPointerHovering else { return }
        lingerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.turnPhase {
            case .replyFinished, .error: self.returnToIdle()
            default: break
            }
        }
    }

    private func cancelLinger() {
        lingerTask?.cancel()
        lingerTask = nil
    }

    private func showTaskFinishedNotice(for task: BackgroundTask) {
        recentlyFinishedTask = task
        taskFinishedNoticeTask?.cancel()
        let noticeDuration = taskFinishedNoticeDuration
        taskFinishedNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(noticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.recentlyFinishedTask = nil
        }
    }

    /// Reveals the reply at an even pace, faster when more text is waiting, so bursts read as a smooth stream.
    private func scheduleReplyReveal() {
        if revealsReplyInstantly {
            displayedReplyText = replyText
            return
        }
        guard replyRevealTask == nil || replyRevealTask?.isCancelled == true else { return }
        replyRevealTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waitingCharacterCount = self.replyText.count - self.displayedReplyText.count
                if waitingCharacterCount <= 0 {
                    // The full reply may have been replaced by the final text; keep them identical.
                    if self.displayedReplyText != self.replyText { self.displayedReplyText = self.replyText }
                    break
                }
                guard self.replyText.hasPrefix(self.displayedReplyText) else {
                    self.displayedReplyText = self.replyText
                    break
                }
                let charactersThisFrame = max(1, waitingCharacterCount / 6)
                let revealEnd = self.replyText.index(self.replyText.startIndex, offsetBy: self.displayedReplyText.count + charactersThisFrame)
                self.displayedReplyText = String(self.replyText[..<revealEnd])
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            // A cancelled task has already been replaced; only a task that ran to completion clears the slot.
            if !Task.isCancelled { self?.replyRevealTask = nil }
        }
    }

    /// "gmail_search_threads" becomes "Gmail search threads", for tools that give no activity label.
    static func readableToolName(_ toolName: String) -> String {
        let words = toolName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let firstCharacter = words.first else { return toolName }
        return firstCharacter.uppercased() + words.dropFirst().lowercased()
    }
}
