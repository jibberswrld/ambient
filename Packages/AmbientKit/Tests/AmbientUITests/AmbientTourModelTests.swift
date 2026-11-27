import AmbientContracts
import XCTest
@testable import AmbientUI

@MainActor
final class AmbientTourModelTests: XCTestCase {

    private let allPermissionsGranted: [AmbientPermissionKind: AmbientPermissionStatus] = [
        .microphone: .granted, .accessibility: .granted, .screenRecording: .granted, .speechRecognition: .granted,
    ]

    private func makeTour(at lesson: AmbientTourLesson = .talk, dockEdge: FlowBarDockEdge = .bottom) -> AmbientTourModel {
        let tourModel = AmbientTourModel(dockEdge: dockEdge)
        // Long enough that the idle hint never fires during a test that is not about it.
        tourModel.idleHintDelay = 60
        tourModel.permissionStatusesChanged(allPermissionsGranted)
        while tourModel.currentLesson != lesson { tourModel.skipCurrentLesson() }
        return tourModel
    }

    /// A complete spoken turn that ends with a reply.
    private func speakAndGetReply(_ tourModel: AmbientTourModel, tools: [(name: String, isError: Bool)] = []) {
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 1.5)
        tourModel.thinkingStarted()
        for (index, tool) in tools.enumerated() {
            tourModel.apply(.toolStarted(callID: "\(index)", toolName: tool.name, activityLabel: ""))
            tourModel.apply(.toolFinished(callID: "\(index)", toolName: tool.name, isError: tool.isError))
        }
        tourModel.apply(.textDelta("Here you go."))
        tourModel.apply(.finished(finalText: "Here you go."))
    }

    // MARK: Order and navigation

    func testTheTourStartsOnTalkingAndWalksThroughEveryLessonToTheFinish() {
        let tourModel = AmbientTourModel()
        XCTAssertEqual(tourModel.step, .lesson(.talk))
        var visitedLessons: [AmbientTourLesson] = []
        while let lesson = tourModel.currentLesson {
            visitedLessons.append(lesson)
            tourModel.skipCurrentLesson()
        }
        XCTAssertEqual(visitedLessons, [.talk, .showScreen, .handOff, .connectApps, .placeBar])
        XCTAssertEqual(tourModel.step, .finished)
    }

    func testNextAppearsOnlyOnceTheLessonIsDoneAndThenMovesOn() {
        let tourModel = makeTour()
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        speakAndGetReply(tourModel)
        XCTAssertTrue(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.step, .lesson(.talk), "a finished lesson waits for Next instead of advancing under the reply")
        tourModel.advanceToNextStep()
        XCTAssertEqual(tourModel.step, .lesson(.showScreen))
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
    }

    func testEachLessonReportsWhetherItWasCompletedOrSkipped() {
        let tourModel = makeTour()
        var endedLessons: [(AmbientTourLesson, Bool)] = []
        tourModel.onLessonEnded = { endedLessons.append(($0, $1)) }
        speakAndGetReply(tourModel)
        tourModel.advanceToNextStep()
        tourModel.skipCurrentLesson()
        XCTAssertEqual(endedLessons.map(\.0), [.talk, .showScreen])
        XCTAssertEqual(endedLessons.map(\.1), [true, false])
    }

    func testEndingTheTourReportsFinishFromAnyLessonAndFromTheLastCard() {
        var finishCount = 0
        let midwayTour = makeTour(at: .handOff)
        midwayTour.onFinish = { finishCount += 1 }
        midwayTour.endTour()
        let finishedTour = makeTour(at: .placeBar)
        finishedTour.onFinish = { finishCount += 1 }
        finishedTour.skipCurrentLesson()
        XCTAssertEqual(finishedTour.step, .finished)
        finishedTour.endTour()
        XCTAssertEqual(finishCount, 2)
    }

    func testSkipTitlesMakeTheOptionalLessonsSoundOptional() {
        XCTAssertEqual(AmbientTourLesson.talk.skipTitle, "Skip")
        XCTAssertEqual(AmbientTourLesson.connectApps.skipTitle, "Later")
        XCTAssertEqual(AmbientTourLesson.placeBar.skipTitle, "It's fine here")
    }

    // MARK: Lesson 1: talk

    func testASpokenTurnWithAReplyCompletesTalking() {
        let tourModel = makeTour()
        speakAndGetReply(tourModel)
        XCTAssertTrue(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.status.tone, .done)
        XCTAssertNotNil(tourModel.completionNote)
        tourModel.advanceToNextStep()
        XCTAssertNil(tourModel.completionNote, "a new lesson shows its instructions again")
    }

    func testATypedTurnDoesNotCompleteTalkingAndAsksForTheVoice() {
        let tourModel = makeTour()
        tourModel.typedRequestSubmitted()
        tourModel.apply(.textDelta("Hi."))
        tourModel.apply(.finished(finalText: "Hi."))
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .nudge, text: "Typing works too. Now try it with your voice."))
    }

    func testHoldingTheKeysLightsThemAndSaysListening() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        XCTAssertTrue(tourModel.isShortcutHeld)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .listening, text: "Listening…"))
        tourModel.shortcutReleased(heldFor: 1.2)
        XCTAssertFalse(tourModel.isShortcutHeld)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .working, text: "Thinking…"))
    }

    func testTheFirstWordsOfAReplyAreAcknowledged() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 1.2)
        tourModel.apply(.textDelta("I"))
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .working, text: "Here it comes. The answer is in the bar."))
    }

    func testAToolInUseIsNamedInTheStatusLine() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 1.2)
        tourModel.apply(.toolStarted(callID: "1", toolName: "web_search", activityLabel: "Searching the web"))
        XCTAssertEqual(tourModel.status.text, "Searching the web…")
        tourModel.apply(.toolStarted(callID: "2", toolName: "gmail_search_threads", activityLabel: ""))
        XCTAssertEqual(tourModel.status.text, "Gmail search threads…", "a tool without a label gets a readable name")
    }

    func testABriefTapNudgesToKeepTheKeysHeld() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 0.2)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .nudge, text: "Keep both keys held while you talk."))
        tourModel.heardNothing()
        XCTAssertEqual(tourModel.status.text, "Keep both keys held while you talk.", "the tap is the real reason nothing was heard")
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
    }

    func testAHoldJustLongEnoughIsNotATap() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: AmbientTourModel.shortestRealHoldDuration)
        XCTAssertEqual(tourModel.status.tone, .working)
    }

    func testARecordingWithNothingInItSaysSo() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 1.5)
        tourModel.heardNothing()
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .nudge, text: "I didn't catch anything. Hold the keys and speak, then let go."))
    }

    func testHeardNothingIsIgnoredOnceANewHoldHasStarted() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.heardNothing()
        XCTAssertEqual(tourModel.status.tone, .listening)
    }

    func testAFailedTurnShowsThePlainReasonAndTryAgainClearsIt() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 1.5)
        tourModel.apply(.failed(.other(message: "Ambient could not reach the internet.")))
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .problem, text: "Ambient could not reach the internet.", action: .tryAgain))
        tourModel.performStatusAction(.tryAgain)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .waiting, text: "Waiting for you to hold the keys."))
    }

    func testASignedOutFailureSaysWhereToSignIn() {
        let tourModel = makeTour()
        tourModel.apply(.failed(.notSignedIn))
        XCTAssertEqual(tourModel.status.tone, .problem)
        XCTAssertEqual(tourModel.status.action, .tryAgain)
    }

    func testACancelledTurnGoesQuietWithoutLosingAnUnreadNudge() {
        let tourModel = makeTour()
        tourModel.shortcutPressed()
        tourModel.apply(.failed(.cancelled))
        XCTAssertEqual(tourModel.status.tone, .waiting)
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 0.1)
        tourModel.apply(.failed(.cancelled))
        XCTAssertEqual(tourModel.status.tone, .nudge)
    }

    func testAMissingMicrophoneIsNamedWithAButtonThatFixesIt() {
        let tourModel = makeTour()
        var fixedPermissions: [AmbientPermissionKind] = []
        tourModel.onFixPermission = { fixedPermissions.append($0) }
        var statuses = allPermissionsGranted
        statuses[.microphone] = .deniedInSystemSettings
        tourModel.permissionStatusesChanged(statuses)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .problem, text: "Ambient needs the microphone to hear you.",
                                                           action: .fixPermission(.microphone, .deniedInSystemSettings)))
        tourModel.shortcutPressed()
        XCTAssertEqual(tourModel.status.tone, .problem, "nothing else can work until the microphone is back")
        if let action = tourModel.status.action { tourModel.performStatusAction(action) }
        XCTAssertEqual(fixedPermissions, [.microphone])
        statuses[.microphone] = .granted
        tourModel.permissionStatusesChanged(statuses)
        XCTAssertEqual(tourModel.status.tone, .listening)
    }

    func testMissingAccessibilityBlocksTheVoiceLessonsBecauseTheKeysCannotBeHeard() {
        let tourModel = makeTour()
        var statuses = allPermissionsGranted
        statuses[.accessibility] = .notYetAsked
        tourModel.permissionStatusesChanged(statuses)
        XCTAssertEqual(tourModel.status.action, .fixPermission(.accessibility, .notYetAsked))
    }

    func testUnreportedPermissionsAreNeverAssumedMissing() {
        let tourModel = AmbientTourModel()
        XCTAssertEqual(tourModel.status.tone, .waiting)
    }

    // MARK: Lesson 2: show it your screen

    func testLookingAtTheScreenCompletesShowYourScreen() {
        for screenToolName in ["look_at_screen", "draw_on_screen", "point_at"] {
            let tourModel = makeTour(at: .showScreen)
            tourModel.shortcutPressed()
            tourModel.shortcutReleased(heldFor: 1.5)
            tourModel.apply(.toolStarted(callID: "1", toolName: screenToolName, activityLabel: ""))
            XCTAssertFalse(tourModel.isCurrentLessonComplete)
            tourModel.apply(.toolFinished(callID: "1", toolName: screenToolName, isError: false))
            XCTAssertTrue(tourModel.isCurrentLessonComplete, screenToolName)
            XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .done, text: "Done. Ambient saw your screen."))
            XCTAssertEqual(tourModel.completionNote, "The drawing clears when you make your next request.")
        }
    }

    func testAScreenToolThatFailsDoesNotCompleteTheLesson() {
        let tourModel = makeTour(at: .showScreen)
        tourModel.apply(.toolFinished(callID: "1", toolName: "look_at_screen", isError: true))
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.status.tone, .problem)
        XCTAssertEqual(tourModel.status.action, .tryAgain)
    }

    func testARegularAnswerDuringTheScreenLessonNudgesWithoutBlocking() {
        let tourModel = makeTour(at: .showScreen)
        speakAndGetReply(tourModel, tools: [("web_search", false)])
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.step, .lesson(.showScreen), "the coach stays on the lesson")
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .nudge, text: "That was a regular answer. To use your screen, try the phrase above."))
    }

    func testMissingScreenRecordingIsTheProblemNamedForTheScreenLesson() {
        let tourModel = makeTour(at: .showScreen)
        var statuses = allPermissionsGranted
        statuses[.screenRecording] = .notYetAsked
        tourModel.permissionStatusesChanged(statuses)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .problem, text: "Ambient needs Screen Recording to see your screen.",
                                                           action: .fixPermission(.screenRecording, .notYetAsked)))
        let talkTour = makeTour(at: .talk)
        talkTour.permissionStatusesChanged(statuses)
        XCTAssertEqual(talkTour.status.tone, .waiting, "talking does not need the screen")
    }

    func testOnlyTheLessonsOwnToolCompletesIt() {
        let tourModel = makeTour(at: .showScreen)
        tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: false))
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        let talkTour = makeTour(at: .talk)
        talkTour.apply(.toolFinished(callID: "1", toolName: "look_at_screen", isError: false))
        XCTAssertFalse(talkTour.isCurrentLessonComplete, "talking completes on a reply, not a tool")
    }

    // MARK: Lesson 3: hand off a job

    func testStartingAnAgentCompletesHandOff() {
        let tourModel = makeTour(at: .handOff)
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 2)
        tourModel.approvalRequested(kind: .backgroundAgent)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .nudge, text: "Ambient asks before it starts work. Press Allow in the bar."))
        tourModel.approvalAnswered(isAllowed: true)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .working, text: "Starting the agent…"))
        tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: false))
        XCTAssertTrue(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.status.text, "Done. Your agent is working.")
        XCTAssertEqual(tourModel.completionNote, "The dot in the bar is your agent working. Click the bar to see it. You can keep going.")
    }

    func testStartingAnAgentWithoutBeingAskedAlsoCompletesHandOff() {
        let tourModel = makeTour(at: .handOff)
        tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: false))
        XCTAssertTrue(tourModel.isCurrentLessonComplete, "allow without asking skips the approval card")
    }

    func testDenyingTheAgentOffersToTryAgainAndSurvivesTheRestOfTheTurn() {
        let tourModel = makeTour(at: .handOff)
        tourModel.shortcutPressed()
        tourModel.shortcutReleased(heldFor: 2)
        tourModel.approvalRequested(kind: .backgroundAgent)
        tourModel.approvalAnswered(isAllowed: false)
        let deniedStatus = AmbientTourStatus(tone: .nudge, text: "No agent started. Ask again when you're ready, then press Allow.")
        XCTAssertEqual(tourModel.status, deniedStatus)
        tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: true))
        tourModel.apply(.textDelta("Okay, I won't start it."))
        tourModel.apply(.finished(finalText: "Okay, I won't start it."))
        XCTAssertEqual(tourModel.status.text, deniedStatus.text, "the denial explanation is not replaced by a generic one")
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
    }

    func testAnAgentThatFailsToStartIsAProblem() {
        let tourModel = makeTour(at: .handOff)
        tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: true))
        XCTAssertEqual(tourModel.status.tone, .problem)
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
    }

    func testAShellCommandApprovalIsNotExplainedAsAnAgent() {
        let tourModel = makeTour(at: .handOff)
        tourModel.approvalRequested(kind: .shellCommand)
        XCTAssertEqual(tourModel.status.tone, .waiting)
    }

    func testAnApprovalOutsideTheHandOffLessonIsLeftToTheBar() {
        let tourModel = makeTour(at: .talk)
        tourModel.approvalRequested(kind: .backgroundAgent)
        XCTAssertEqual(tourModel.status.tone, .waiting)
    }

    func testAQuickAnswerDuringHandOffNudgesTowardTheAgentPhrase() {
        let tourModel = makeTour(at: .handOff)
        speakAndGetReply(tourModel)
        XCTAssertEqual(tourModel.status.tone, .nudge)
        XCTAssertTrue(tourModel.status.text.contains("Start an agent to"))
    }

    // MARK: Lesson 4: connect your apps

    func testConnectingAnAppCompletesConnectApps() {
        let tourModel = makeTour(at: .connectApps)
        var openedConnectors = false
        tourModel.onOpenConnectors = { openedConnectors = true }
        XCTAssertEqual(tourModel.status.text, "No apps connected yet.")
        tourModel.openConnectors()
        XCTAssertTrue(openedConnectors)
        XCTAssertEqual(tourModel.status.text, "Waiting for you to finish in the browser.")
        tourModel.connectedAppsChanged(names: [])
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        tourModel.connectedAppsChanged(names: ["Gmail"])
        XCTAssertTrue(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.status.text, "Gmail is connected.")
    }

    func testConnectedAppsAreListedBriefly() {
        XCTAssertEqual(AmbientTourModel.listedAppNames(["Gmail", "Calendar"]), "Gmail and Calendar are")
        XCTAssertEqual(AmbientTourModel.listedAppNames(["Gmail", "Calendar", "Slack", "Notion"]), "Gmail, Calendar and 2 more are")
    }

    func testLaterMovesOnFromConnectApps() {
        let tourModel = makeTour(at: .connectApps)
        tourModel.skipCurrentLesson()
        XCTAssertEqual(tourModel.step, .lesson(.placeBar))
    }

    func testConnectingAnAppEarlierInTheTourDoesNotCompleteTheWrongLesson() {
        let tourModel = makeTour(at: .talk)
        tourModel.connectedAppsChanged(names: ["Gmail"])
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
    }

    // MARK: Lesson 5: put it where you like

    func testMovingTheBarToAnotherEdgeCompletesPlaceBar() {
        let tourModel = makeTour(at: .placeBar, dockEdge: .bottom)
        XCTAssertEqual(tourModel.status.text, "The bar is on the bottom edge.")
        tourModel.dockEdgeChanged(to: .bottom)
        XCTAssertFalse(tourModel.isCurrentLessonComplete, "landing back on the same edge is not a change")
        tourModel.dockEdgeChanged(to: .left)
        XCTAssertTrue(tourModel.isCurrentLessonComplete)
        XCTAssertEqual(tourModel.status.text, "The bar is on the left edge now.")
    }

    func testTheEdgeTheLessonStartsFromIsTheEdgeAtThatMoment() {
        let tourModel = makeTour(at: .connectApps, dockEdge: .bottom)
        tourModel.dockEdgeChanged(to: .right)
        XCTAssertFalse(tourModel.isCurrentLessonComplete, "moving the bar during another lesson completes nothing")
        tourModel.skipCurrentLesson()
        XCTAssertEqual(tourModel.status.text, "The bar is on the right edge.")
        tourModel.dockEdgeChanged(to: .right)
        XCTAssertFalse(tourModel.isCurrentLessonComplete)
        tourModel.dockEdgeChanged(to: .top)
        XCTAssertTrue(tourModel.isCurrentLessonComplete)
    }

    func testItsFineHereMovesOnToTheFinish() {
        let tourModel = makeTour(at: .placeBar)
        tourModel.skipCurrentLesson()
        XCTAssertEqual(tourModel.step, .finished)
    }

    // MARK: Idle hint

    func testOneGentleHintAfterAQuietSpellAndNoMore() async throws {
        let tourModel = makeTour()
        tourModel.idleHintDelay = 0.05
        tourModel.begin()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tourModel.status, AmbientTourStatus(tone: .nudge, text: "Press both keys first and keep them down, then start talking."))
        tourModel.performStatusAction(.tryAgain)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tourModel.status.tone, .waiting, "the hint is shown once per lesson, not repeated")
    }

    func testActivityPostponesTheHint() async throws {
        let tourModel = makeTour()
        tourModel.idleHintDelay = 0.15
        tourModel.begin()
        try await Task.sleep(nanoseconds: 100_000_000)
        tourModel.shortcutPressed()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(tourModel.status.tone, .listening, "no hint while the keys are held")
    }

    func testEachLessonGetsItsOwnHint() async throws {
        let tourModel = makeTour(at: .placeBar)
        tourModel.idleHintDelay = 0.05
        tourModel.begin()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tourModel.status.text, "Grab the small bar and drag it toward another edge.")
    }

    func testNoHintOnceTheLessonIsDone() async throws {
        let tourModel = makeTour()
        tourModel.idleHintDelay = 0.05
        speakAndGetReply(tourModel)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tourModel.status.tone, .done)
    }

    // MARK: Coach placement

    func testTheCoachSitsInTheCornerAwayFromTheBar() {
        XCTAssertEqual(AmbientTourCoachCorner.corner(awayFromBarDockedTo: .bottom), .topTrailing)
        XCTAssertEqual(AmbientTourCoachCorner.corner(awayFromBarDockedTo: .left), .topTrailing)
        XCTAssertEqual(AmbientTourCoachCorner.corner(awayFromBarDockedTo: .top), .bottomTrailing)
        XCTAssertEqual(AmbientTourCoachCorner.corner(awayFromBarDockedTo: .right), .topLeading)
    }

    func testThePanelPutsTheCardInsetFromTheCorner() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let panelSize = CGSize(width: 396, height: 520)
        let topTrailing = AmbientTourCoachCorner.topTrailing.panelFrame(panelSize: panelSize, cardMargin: 28, inset: 14, within: visibleFrame)
        XCTAssertEqual(topTrailing.maxX - 28, visibleFrame.maxX - 14, "the card's trailing edge is 14 points from the screen edge")
        XCTAssertEqual(topTrailing.maxY - 28, visibleFrame.maxY - 14)
        let bottomTrailing = AmbientTourCoachCorner.bottomTrailing.panelFrame(panelSize: panelSize, cardMargin: 28, inset: 14, within: visibleFrame)
        XCTAssertEqual(bottomTrailing.minY + 28, visibleFrame.minY + 14)
        let topLeading = AmbientTourCoachCorner.topLeading.panelFrame(panelSize: panelSize, cardMargin: 28, inset: 14, within: visibleFrame)
        XCTAssertEqual(topLeading.minX + 28, visibleFrame.minX + 14)
    }
}
