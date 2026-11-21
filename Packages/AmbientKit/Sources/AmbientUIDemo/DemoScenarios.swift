import AmbientContracts
import AmbientUI
import Foundation

/// Every state the flow bar can show, each reachable by name from the command line (`--state responding`).
enum DemoFlowBarState: String, CaseIterable {
    case resting
    case restingWithTasks = "resting-tasks"
    case hovering
    case hoveringWithTasks = "hovering-tasks"
    case listening
    case listeningQuiet = "listening-quiet"
    case transcribing
    case thinking
    case working
    case respondingShort = "responding-short"
    case responding
    case replyShort = "reply-short"
    case reply
    case replyLong = "reply-long"
    case error
    case errorTopUp = "error-top-up"
    case approvalCommand = "approval-command"
    case approvalAgent = "approval-agent"
    case typing
    case taskTray = "task-tray"
    case taskFinished = "task-finished"

    /// The pinned audio level used for listening captures. A real voice moves; a still capture needs one value.
    var stillAudioLevel: Double {
        switch self {
        case .listening: return 0.62
        case .listeningQuiet: return 0.08
        default: return 0
        }
    }
}

/// Puts a flow bar model into a named state with realistic content, using only the public API the app uses.
@MainActor
enum DemoScenarioDirector {

    static func apply(_ state: DemoFlowBarState, to model: FlowBarModel, now: Date = Date()) {
        model.returnToIdle()
        model.pinHoverForPreview(false)
        model.setBackgroundTasks([])

        switch state {
        case .resting:
            break

        case .restingWithTasks:
            model.setBackgroundTasks(DemoSampleData.backgroundTasks(relativeTo: now))

        case .hovering:
            model.pinHoverForPreview(true)

        case .hoveringWithTasks:
            model.setBackgroundTasks(DemoSampleData.backgroundTasks(relativeTo: now))
            model.pinHoverForPreview(true)

        case .listening, .listeningQuiet:
            model.beginListening()
            model.updateAudioLevel(state.stillAudioLevel)

        case .transcribing:
            model.beginListening()
            model.beginTranscribing()

        case .thinking:
            model.beginThinking()

        case .working:
            model.beginThinking()
            model.apply(.toolStarted(callID: "1", toolName: "gmail_search", activityLabel: "Searching Gmail"))
            model.apply(.toolFinished(callID: "1", toolName: "gmail_search", isError: false))
            model.apply(.toolStarted(callID: "2", toolName: "calendar_list_events", activityLabel: "Checking your calendar"))

        case .respondingShort:
            model.beginThinking()
            model.apply(.textDelta("Done. It's on"))

        case .responding:
            model.beginThinking()
            model.apply(.toolStarted(callID: "1", toolName: "gmail_search", activityLabel: "Searching Gmail"))
            model.apply(.toolFinished(callID: "1", toolName: "gmail_search", isError: false))
            let partialReply = String(DemoSampleData.mediumReply.prefix(150))
            model.apply(.textDelta(partialReply))

        case .replyShort:
            model.beginThinking()
            model.apply(.textDelta(DemoSampleData.shortReply))
            model.apply(.finished(finalText: DemoSampleData.shortReply))

        case .reply:
            model.beginThinking()
            model.apply(.toolStarted(callID: "1", toolName: "gmail_search", activityLabel: "Searching Gmail"))
            model.apply(.toolFinished(callID: "1", toolName: "gmail_search", isError: false))
            model.apply(.toolStarted(callID: "2", toolName: "gmail_draft", activityLabel: "Drafting a reply"))
            model.apply(.toolFinished(callID: "2", toolName: "gmail_draft", isError: false))
            model.apply(.textDelta(DemoSampleData.mediumReply))
            model.apply(.finished(finalText: DemoSampleData.mediumReply))

        case .replyLong:
            model.beginThinking()
            model.apply(.textDelta(DemoSampleData.longReply))
            model.apply(.finished(finalText: DemoSampleData.longReply))

        case .error:
            model.beginThinking()
            model.apply(.failed(.other(message: "Ambient could not reach the internet. Check your connection and try again.")))

        case .errorTopUp:
            model.beginThinking()
            model.apply(.failed(.paymentRequired(message: "You have used this month's allowance.", topUpURL: URL(string: "https://publik.example/top-up"))))

        case .approvalCommand:
            model.beginThinking()
            let request = FlowBarApprovalRequest(title: DemoSampleData.shellCommandApprovalTitle, detail: DemoSampleData.shellCommandApprovalDetail, kind: .shellCommand)
            Task { _ = await model.requestApproval(request) }

        case .approvalAgent:
            model.beginThinking()
            let request = FlowBarApprovalRequest(title: DemoSampleData.agentApprovalTitle, detail: DemoSampleData.agentApprovalDetail, kind: .backgroundAgent)
            Task { _ = await model.requestApproval(request) }

        case .typing:
            model.beginTyping()
            model.typedText = "Move my 4:30 with Alex to Monday"

        case .taskTray:
            var tasks = DemoSampleData.backgroundTasks(relativeTo: now)
            tasks.insert(DemoSampleData.failedTask(relativeTo: now), at: 1)
            model.setBackgroundTasks(tasks)
            model.toggleTaskTray()

        case .taskFinished:
            let tasks = DemoSampleData.backgroundTasks(relativeTo: now)
            model.setBackgroundTasks(tasks)
            var finishedTasks = tasks
            finishedTasks[0].status = .succeeded
            finishedTasks[0].finishedAt = now
            finishedTasks[0].latestActivity = "Opened a pull request"
            finishedTasks[0].result = "Split settings into six files and opened a pull request. All 214 tests pass."
            model.setBackgroundTasks(finishedTasks)
        }
    }

    /// States that need a moment of async work (approvals resume through a Task) before they render.
    static func needsAsyncSettle(_ state: DemoFlowBarState) -> Bool {
        state == .approvalCommand || state == .approvalAgent
    }
}
