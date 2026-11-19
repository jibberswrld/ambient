import AmbientContracts
import XCTest
@testable import AmbientUI

@MainActor
final class FlowBarModelTests: XCTestCase {
    private func makeModel() -> FlowBarModel {
        let model = FlowBarModel()
        model.revealsReplyInstantly = true
        return model
    }

    func testRestsByDefaultAndHoversWithThePointer() {
        let model = makeModel()
        XCTAssertEqual(model.presentation, .resting)
        model.setPointerHovering(true)
        XCTAssertEqual(model.presentation, .hovering)
        model.setPointerHovering(false)
        XCTAssertEqual(model.presentation, .resting)
    }

    func testAFullVoiceTurn() {
        let model = makeModel()
        model.beginListening()
        XCTAssertEqual(model.presentation, .listening)
        model.updateAudioLevel(1.7)
        XCTAssertEqual(model.audioLevel, 1, "levels are clamped to 0...1")
        model.beginTranscribing()
        XCTAssertEqual(model.presentation, .transcribing)
        XCTAssertEqual(model.audioLevel, 0)
        model.beginThinking()
        XCTAssertEqual(model.presentation, .thinking)

        model.apply(.toolStarted(callID: "1", toolName: "gmail_search", activityLabel: "Searching Gmail"))
        XCTAssertEqual(model.presentation, .working)
        XCTAssertEqual(model.currentActivityLine, "Searching Gmail")
        model.apply(.toolFinished(callID: "1", toolName: "gmail_search", isError: false))
        XCTAssertEqual(model.toolCallsThisTurn.first?.status, .succeeded)

        model.apply(.textDelta("You have "))
        XCTAssertEqual(model.presentation, .responding)
        model.apply(.textDelta("two new emails."))
        XCTAssertEqual(model.replyText, "You have two new emails.")
        XCTAssertEqual(model.displayedReplyText, "You have two new emails.")

        model.apply(.finished(finalText: "You have two new emails."))
        XCTAssertEqual(model.presentation, .reply)
        model.dismissReplyOrError()
        XCTAssertEqual(model.presentation, .resting)
        XCTAssertEqual(model.replyText, "")
    }

    func testToolStartingMidReplyKeepsTheReplyOnScreen() {
        let model = makeModel()
        model.apply(.textDelta("Let me check."))
        model.apply(.toolStarted(callID: "a", toolName: "calendar_list", activityLabel: ""))
        XCTAssertEqual(model.presentation, .responding)
        XCTAssertEqual(model.currentActivityLine, "Calendar list", "an empty label falls back to a readable tool name")
    }

    func testFailuresBecomePlainErrors() {
        let model = makeModel()
        let topUpURL = URL(string: "https://publik.example/top-up")!
        model.apply(.failed(.paymentRequired(message: "You have used this month's allowance.", topUpURL: topUpURL)))
        XCTAssertEqual(model.presentation, .error)
        XCTAssertEqual(model.currentErrorNotice?.link, FlowBarErrorNotice.Link(title: "Top up", destination: .webPage(topUpURL)))

        model.apply(.failed(.notSignedIn))
        XCTAssertEqual(model.currentErrorNotice?.link?.destination, .settings)

        model.apply(.failed(.cancelled))
        XCTAssertEqual(model.presentation, .resting, "a cancelled turn just goes quiet")
    }

    func testErrorLinkOpensTheURLAndClears() {
        let model = makeModel()
        var openedURL: URL?
        model.onOpenURL = { openedURL = $0 }
        let topUpURL = URL(string: "https://publik.example/top-up")!
        model.showError(FlowBarErrorNotice(message: "Out of credit.", link: .init(title: "Top up", destination: .webPage(topUpURL))))
        model.followErrorLink(model.currentErrorNotice!.link!)
        XCTAssertEqual(openedURL, topUpURL)
        XCTAssertEqual(model.presentation, .resting)
    }

    func testApprovalIsAwaitedAndAnswered() async {
        let model = makeModel()
        model.beginThinking()
        let request = FlowBarApprovalRequest(title: "Run this command?", detail: "git status", kind: .shellCommand)
        async let answer = model.requestApproval(request)
        await Task.yield()
        XCTAssertEqual(model.presentation, .approval)
        model.answerPendingApproval(isAllowed: true)
        let wasAllowed = await answer
        XCTAssertTrue(wasAllowed)
        XCTAssertEqual(model.presentation, .thinking, "the turn resumes where it was")
    }

    func testCancellingTheTurnDeniesAPendingApproval() async {
        let model = makeModel()
        var didCancel = false
        model.onCancelTurn = { didCancel = true }
        async let answer = model.requestApproval(FlowBarApprovalRequest(title: "Start an agent?", detail: "Fix the flaky test", kind: .backgroundAgent))
        await Task.yield()
        model.cancelCurrentTurn()
        let wasAllowed = await answer
        XCTAssertFalse(wasAllowed)
        XCTAssertTrue(didCancel)
    }

    func testListeningOutranksTyping() {
        let model = makeModel()
        model.beginTyping()
        XCTAssertEqual(model.presentation, .typing)
        model.beginListening()
        XCTAssertEqual(model.presentation, .listening)
        XCTAssertFalse(model.isTyping)
    }

    func testTypedTextIsSubmittedTrimmed() {
        let model = makeModel()
        var submittedText: String?
        model.onSubmitTypedText = { submittedText = $0 }
        model.beginTyping()
        model.typedText = "   "
        model.submitTypedText()
        XCTAssertNil(submittedText, "blank text is not sent")
        model.typedText = "  what's on my calendar  "
        model.submitTypedText()
        XCTAssertEqual(submittedText, "what's on my calendar")
        XCTAssertEqual(model.presentation, .thinking)
    }

    func testContinuingAReplyOpensTyping() {
        let model = makeModel()
        model.apply(.finished(finalText: "Done."))
        model.continueConversation()
        XCTAssertEqual(model.presentation, .typing)
    }

    func testATaskFinishingWhileRestingShowsANotice() {
        let model = makeModel()
        var task = BackgroundTask(id: UUID(), kind: .codexAgent, title: "Fix login test", status: .running, workingDirectory: "/tmp", startedAt: Date(), finishedAt: nil, latestActivity: "Running tests", result: nil)
        model.setBackgroundTasks([task])
        XCTAssertEqual(model.presentation, .resting)
        task.status = .succeeded
        task.finishedAt = Date()
        model.setBackgroundTasks([task])
        XCTAssertEqual(model.presentation, .taskFinishedNotice)
        model.toggleTaskTray()
        XCTAssertEqual(model.presentation, .taskTray)
        model.setBackgroundTasks([])
        XCTAssertEqual(model.presentation, .resting, "an empty task list closes the tray")
    }

    func testTaskTrayIntentsReachTheApp() {
        let model = makeModel()
        let taskID = UUID()
        var cancelledID: UUID?
        var dismissedID: UUID?
        var transcriptID: UUID?
        model.onCancelBackgroundTask = { cancelledID = $0 }
        model.onDismissBackgroundTask = { dismissedID = $0 }
        model.onOpenBackgroundTaskTranscript = { transcriptID = $0 }
        model.cancelBackgroundTask(taskID)
        model.dismissBackgroundTask(taskID)
        model.openBackgroundTaskTranscript(taskID)
        XCTAssertEqual(cancelledID, taskID)
        XCTAssertEqual(dismissedID, taskID)
        XCTAssertEqual(transcriptID, taskID)
    }

    func testPacedRevealCatchesUpWithTheWholeReply() async throws {
        let model = FlowBarModel()
        model.apply(.textDelta(String(repeating: "word ", count: 60)))
        XCTAssertLessThan(model.displayedReplyText.count, model.replyText.count)
        for _ in 0..<200 where model.displayedReplyText != model.replyText {
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        XCTAssertEqual(model.displayedReplyText, model.replyText)
    }
}

final class AmbientLightMarkdownParserTests: XCTestCase {
    func testParsesParagraphsListsHeadingsAndCode() {
        let blocks = AmbientLightMarkdownParser.blocks(from: """
        # Today
        You have **three** meetings.

        - Standup at 9
        - Lunch with *Sam*
        2. Review `main`
        ```
        git pull
        ```
        """)
        XCTAssertEqual(blocks, [
            .heading("Today"),
            .paragraph("You have **three** meetings."),
            .listItem(marker: "•", text: "Standup at 9"),
            .listItem(marker: "•", text: "Lunch with *Sam*"),
            .listItem(marker: "2.", text: "Review `main`"),
            .codeBlock("git pull"),
        ])
    }

    func testAnUnclosedCodeFenceWhileStreamingStillShowsCode() {
        XCTAssertEqual(AmbientLightMarkdownParser.blocks(from: "Run this:\n```\nnpm test"), [.paragraph("Run this:"), .codeBlock("npm test")])
    }

    func testElapsedTimeFormatting() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(AmbientElapsedTimeFormatter.string(from: start, to: start.addingTimeInterval(42)), "0:42")
        XCTAssertEqual(AmbientElapsedTimeFormatter.string(from: start, to: start.addingTimeInterval(725)), "12:05")
        XCTAssertEqual(AmbientElapsedTimeFormatter.string(from: start, to: start.addingTimeInterval(3729)), "1:02:09")
    }
}
