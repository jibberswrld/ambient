import AmbientContracts
import AppKit
import XCTest
@testable import AmbientUI

@MainActor
final class FlowBarLingerTests: XCTestCase {
    private func makeModel() -> FlowBarModel {
        let model = FlowBarModel()
        model.revealsReplyInstantly = true
        return model
    }

    func testAFinishedReplyReturnsToRestAfterItsLinger() async throws {
        let model = makeModel()
        model.finishedReplyLingerDuration = 0.05
        model.apply(.textDelta("Done."))
        model.apply(.finished(finalText: "Done."))
        XCTAssertEqual(model.presentation, .reply)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.presentation, .resting)
    }

    func testHoveringAReplyHoldsItOnScreen() async throws {
        let model = makeModel()
        model.finishedReplyLingerDuration = 0.05
        model.apply(.textDelta("Done."))
        model.apply(.finished(finalText: "Done."))
        model.setPointerHovering(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.presentation, .reply, "a reply being read must not vanish")
        model.setPointerHovering(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.presentation, .resting)
    }

    func testZeroLingerKeepsAReplyUntilDismissed() async throws {
        let model = makeModel()
        model.finishedReplyLingerDuration = 0
        model.apply(.finished(finalText: "Done."))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.presentation, .reply)
    }

    func testAnEmptyFinishedTurnGoesStraightBackToRest() {
        let model = makeModel()
        model.beginThinking()
        model.apply(.finished(finalText: "   "))
        XCTAssertEqual(model.presentation, .resting)
    }

    func testSignedOutErrorLinksToSettings() {
        let model = makeModel()
        var didOpenSettings = false
        model.onOpenSettings = { didOpenSettings = true }
        model.apply(.failed(.notSignedIn))
        XCTAssertEqual(model.presentation, .error)
        let link = try? XCTUnwrap(model.currentErrorNotice?.link)
        XCTAssertEqual(link?.destination, .settings)
        if let link { model.followErrorLink(link) }
        XCTAssertTrue(didOpenSettings)
        XCTAssertEqual(model.presentation, .resting)
    }

    func testTranscribingIsItsOwnPresentationAndSilencesTheLevel() {
        let model = makeModel()
        model.beginListening()
        model.updateAudioLevel(0.8)
        model.beginTranscribing()
        XCTAssertEqual(model.presentation, .transcribing)
        XCTAssertEqual(model.audioLevel, 0)
        model.updateAudioLevel(-3)
        XCTAssertEqual(model.audioLevel, 0, "levels below zero are clamped")
    }

    func testBeginningANewTurnClearsTheLastReply() {
        let model = makeModel()
        model.apply(.textDelta("Old answer"))
        model.apply(.finished(finalText: "Old answer"))
        model.beginListening()
        XCTAssertEqual(model.replyText, "")
        XCTAssertTrue(model.toolCallsThisTurn.isEmpty)
        XCTAssertEqual(model.presentation, .listening)
    }

    func testApprovalOutranksEverythingElse() async {
        let model = makeModel()
        model.beginTyping()
        let answer = Task { await model.requestApproval(FlowBarApprovalRequest(title: "Run this command?", detail: "ls", kind: .shellCommand)) }
        await Task.yield()
        XCTAssertEqual(model.presentation, .approval)
        XCTAssertFalse(model.isTyping, "asking for approval closes the text field")
        model.answerPendingApproval(isAllowed: true)
        let wasAllowed = await answer.value
        XCTAssertTrue(wasAllowed)
    }

    func testANewApprovalDeniesTheOneBeforeIt() async {
        let model = makeModel()
        let firstAnswer = Task { await model.requestApproval(FlowBarApprovalRequest(title: "First", detail: "a", kind: .other)) }
        await Task.yield()
        let secondAnswer = Task { await model.requestApproval(FlowBarApprovalRequest(title: "Second", detail: "b", kind: .other)) }
        await Task.yield()
        let firstWasAllowed = await firstAnswer.value
        XCTAssertFalse(firstWasAllowed)
        XCTAssertEqual(model.pendingApproval?.title, "Second")
        model.answerPendingApproval(isAllowed: true)
        let secondWasAllowed = await secondAnswer.value
        XCTAssertTrue(secondWasAllowed)
    }

    func testTheTrayClosesWhenTheLastTaskIsDismissed() {
        let model = makeModel()
        let task = BackgroundTask(id: UUID(), kind: .shellCommand, title: "Tests", status: .succeeded, workingDirectory: nil, startedAt: Date(), finishedAt: Date(), latestActivity: "Done", result: "All passed")
        model.setBackgroundTasks([task])
        model.toggleTaskTray()
        XCTAssertEqual(model.presentation, .taskTray)
        model.setBackgroundTasks([])
        XCTAssertFalse(model.isTaskTrayExpanded)
        XCTAssertEqual(model.presentation, .resting)
    }

    func testOnlyRestingAndVoiceStatesStandUprightOnSideEdges() {
        XCTAssertTrue(FlowBarPresentation.resting.followsEdgeOrientation)
        XCTAssertTrue(FlowBarPresentation.listening.followsEdgeOrientation)
        XCTAssertFalse(FlowBarPresentation.responding.followsEdgeOrientation, "text is never set upright")
        XCTAssertFalse(FlowBarPresentation.taskTray.followsEdgeOrientation)
    }
}

@MainActor
final class OnboardingModelTests: XCTestCase {

    func testPermissionsReportTheFirstMissingOneAndWhenAllAreGranted() {
        let permissionsModel = AmbientPermissionsModel(statuses: [.microphone: .granted, .accessibility: .notYetAsked])
        XCTAssertEqual(permissionsModel.status(of: .screenRecording), .notYetAsked, "an unknown status reads as not yet asked")
        XCTAssertEqual(permissionsModel.firstMissingPermission, .accessibility)
        XCTAssertFalse(permissionsModel.areAllGranted)
        permissionsModel.statuses[.accessibility] = .granted
        permissionsModel.statuses[.screenRecording] = .granted
        XCTAssertTrue(permissionsModel.areAllGranted)
        XCTAssertNil(permissionsModel.firstMissingPermission)
    }

    func testAHeldAndReleasedShortcutCompletesTheGesture() async throws {
        let firstRunModel = AmbientFirstRunModel()
        firstRunModel.isShortcutHeld = true
        try await Task.sleep(nanoseconds: 400_000_000)
        firstRunModel.isShortcutHeld = false
        XCTAssertTrue(firstRunModel.hasCompletedGesture)
    }

    func testABriefTapDoesNotCountAsTheGesture() {
        let firstRunModel = AmbientFirstRunModel()
        firstRunModel.isShortcutHeld = true
        firstRunModel.isShortcutHeld = false
        XCTAssertFalse(firstRunModel.hasCompletedGesture, "brushing the keys is not talking to Ambient")
    }

    func testOnlyTheExactModifierPairMatchesTheShortcut() {
        XCTAssertTrue(AmbientFirstRunModel.modifierFlags([.control, .option], match: .controlOption))
        XCTAssertTrue(AmbientFirstRunModel.modifierFlags([.control, .option, .capsLock], match: .controlOption), "caps lock is ignored")
        XCTAssertFalse(AmbientFirstRunModel.modifierFlags([.control, .option, .shift], match: .controlOption))
        XCTAssertFalse(AmbientFirstRunModel.modifierFlags([.control], match: .controlOption))
        XCTAssertTrue(AmbientFirstRunModel.modifierFlags([.option, .command], match: .optionCommand))
    }

    func testChoosingAnEdgeAndFinishingReachTheApp() {
        let firstRunModel = AmbientFirstRunModel(chosenEdge: .bottom)
        var chosenEdges: [FlowBarDockEdge] = []
        var didFinish = false
        firstRunModel.onDockEdgeChosen = { chosenEdges.append($0) }
        firstRunModel.onFinish = { didFinish = true }
        firstRunModel.advanceToEdgeStep()
        XCTAssertEqual(firstRunModel.step, .edge)
        firstRunModel.chosenEdge = .left
        firstRunModel.chosenEdge = .left
        XCTAssertEqual(chosenEdges, [.left], "choosing the same edge again is not a change")
        firstRunModel.finish()
        XCTAssertTrue(didFinish)
    }

    func testGateContentKeepsButtonsInOrder() {
        let content = AmbientGateContent(
            title: "Sign in to start",
            bodyText: "Ambient runs on your publik account.",
            buttons: [AmbientGateButton(actionID: "create", label: "Create an account", prominence: .quiet),
                      AmbientGateButton(actionID: "sign-in", label: "Sign in", prominence: .primary)]
        )
        XCTAssertEqual(content.buttons.map(\.actionID), ["create", "sign-in"])
        XCTAssertNil(content.note)
        XCTAssertFalse(content.isWaiting)
    }
}
