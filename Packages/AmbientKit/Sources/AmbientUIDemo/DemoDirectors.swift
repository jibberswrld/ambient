import AmbientContracts
import AmbientUI
import AppKit
import SwiftUI

// MARK: - The scripted run

/// Plays the bar through a realistic session: a voice turn with tools and a streamed reply, background tasks
/// finishing, an approval, a plan error, typing and a long answer.
@MainActor
struct DemoScript {
    var model: FlowBarModel
    var backgroundTaskStore: DemoBackgroundTaskStore
    var speechSimulatorFactory: () -> DemoSpeechLevelSimulator

    func run() async {
        model.finishedReplyLingerDuration = 0
        model.errorLingerDuration = 0
        await pause(1.2)

        model.pinHoverForPreview(true)
        await pause(1.6)
        model.pinHoverForPreview(false)
        await pause(0.8)

        await voiceTurn(reply: DemoSampleData.mediumReply, tools: [("1", "gmail_search", "Searching Gmail"), ("2", "gmail_draft", "Drafting a reply")])
        await pause(3.0)
        model.returnToIdle()
        await pause(1.0)

        let now = Date()
        for task in DemoSampleData.backgroundTasks(relativeTo: now).reversed() { backgroundTaskStore.replace(task) }
        await pause(2.5)
        var finishedRefactor = DemoSampleData.backgroundTasks(relativeTo: now)[0]
        finishedRefactor.status = .succeeded
        finishedRefactor.finishedAt = Date()
        finishedRefactor.latestActivity = "Opened a pull request"
        finishedRefactor.result = "Split settings into six files and opened a pull request. All 214 tests pass."
        backgroundTaskStore.replace(finishedRefactor)
        await pause(3.5)
        model.toggleTaskTray()
        await pause(3.5)
        model.toggleTaskTray()
        await pause(1.0)

        model.beginThinking()
        await pause(0.8)
        let approved = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { @MainActor in
                await model.requestApproval(FlowBarApprovalRequest(title: DemoSampleData.shellCommandApprovalTitle, detail: DemoSampleData.shellCommandApprovalDetail, kind: .shellCommand))
            }
            group.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                model.returnToIdle()
                return false
            }
            let firstAnswer = await group.next() ?? false
            group.cancelAll()
            return firstAnswer
        }
        print("Approval answered: \(approved ? "allow" : "deny")")
        await pause(0.8)

        model.beginThinking()
        await pause(0.9)
        model.apply(.failed(.paymentRequired(message: "You have used this month's allowance.", topUpURL: URL(string: "https://publik.example/top-up"))))
        await pause(3.0)
        model.returnToIdle()
        await pause(1.0)

        model.beginTyping()
        model.typedText = ""
        for character in "What's on tomorrow?" {
            model.typedText.append(character)
            await pause(0.06)
        }
        await pause(0.8)
        model.returnToIdle()
        await pause(0.6)

        await voiceTurn(reply: DemoSampleData.longReply, tools: [("3", "calendar_list_events", "Checking your calendar"), ("4", "linear_search", "Looking in Linear"), ("5", "slack_search", "Reading Slack")])
        await pause(4.0)
        model.returnToIdle()
        print("Script finished")
    }

    /// Answers a typed question the way the real agent would: think, then stream a short reply.
    func answer(typedText: String) async {
        await pause(0.9)
        await stream(reply: "Tomorrow you have the launch review at 3pm and nothing after 4:30.")
    }

    private func voiceTurn(reply: String, tools: [(String, String, String)]) async {
        model.beginListening()
        let speechSimulator = speechSimulatorFactory()
        speechSimulator.start()
        await pause(2.8)
        speechSimulator.stop()
        model.beginTranscribing()
        await pause(0.7)
        model.beginThinking()
        await pause(1.0)
        for (callID, toolName, activityLabel) in tools {
            model.apply(.toolStarted(callID: callID, toolName: toolName, activityLabel: activityLabel))
            await pause(1.3)
            model.apply(.toolFinished(callID: callID, toolName: toolName, isError: false))
        }
        await stream(reply: reply)
    }

    /// Sends the reply in uneven small deltas, like a real model stream.
    private func stream(reply: String) async {
        var remaining = Substring(reply)
        while !remaining.isEmpty {
            let deltaLength = Int.random(in: 2...9)
            let delta = remaining.prefix(deltaLength)
            remaining = remaining.dropFirst(delta.count)
            model.apply(.textDelta(String(delta)))
            await pause(Double.random(in: 0.015...0.05))
        }
        model.apply(.finished(finalText: reply))
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Onboarding

enum DemoOnboardingScreen: String, CaseIterable {
    case gate, permissions
}

/// Walks the onboarding window through sign-in and permissions with fake answers.
@MainActor
final class DemoOnboardingDirector {
    private let onboarding = AmbientOnboardingWindowController()
    private weak var flowBarController: FlowBarPanelController?

    init(flowBarController: FlowBarPanelController?) {
        self.flowBarController = flowBarController
    }

    func show(_ screen: DemoOnboardingScreen) {
        switch screen {
        case .gate: Task { await runGate() }
        case .permissions: showPermissions()
        }
    }

    private func runGate() async {
        let pressedActionID = await onboarding.presentGate(DemoOnboardingContent.signInGate)
        print("Gate answered: \(pressedActionID ?? "closed")")
        guard pressedActionID == "sign-in" else { return }
        onboarding.updateGate(DemoOnboardingContent.waitingForBrowserGate)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        showPermissions()
    }

    private func showPermissions() {
        let permissionsModel = AmbientPermissionsModel(statuses: [.microphone: .granted, .accessibility: .notYetAsked, .screenRecording: .deniedInSystemSettings, .speechRecognition: .notYetAsked])
        permissionsModel.onGrant = { [weak permissionsModel] kind in
            print("Intent: grant \(kind.rawValue)")
            permissionsModel?.statuses[kind] = .waiting
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                permissionsModel?.statuses[kind] = .granted
            }
        }
        permissionsModel.onContinue = { [weak self] in self?.onboarding.close() }
        onboarding.showPermissions(permissionsModel)
    }
}

/// The words the publik sign-in module would pass to the gate.
enum DemoOnboardingContent {
    static let signInGate = AmbientGateContent(
        title: "Sign in to start",
        bodyText: "Ambient runs on your publik account. Sign in once and it works from any app on this Mac.",
        note: "No account yet? Creating one takes a minute.",
        buttons: [
            AmbientGateButton(actionID: "create-account", label: "Create an account", prominence: .quiet),
            AmbientGateButton(actionID: "sign-in", label: "Sign in with publik", prominence: .primary),
        ]
    )

    static let waitingForBrowserGate = AmbientGateContent(
        title: "Finish in your browser",
        bodyText: "We opened publik in your browser. Sign in there and Ambient picks it up on its own.",
        note: "Waiting for you to sign in",
        isWaiting: true,
        buttons: [
            AmbientGateButton(actionID: "cancel", label: "Cancel", prominence: .quiet),
            AmbientGateButton(actionID: "reopen-browser", label: "Open the page again", prominence: .secondary),
        ]
    )
}

// MARK: - Pointer

/// Shows the pointer travelling between three things on the main display, in a click-through overlay.
@MainActor
final class DemoPointerDirector {
    private var overlayPanel: NSPanel?

    func show() {
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DemoPointerTour(screenSize: screen.frame.size))
        panel.orderFrontRegardless()
        overlayPanel = panel
    }
}

private struct DemoPointerTour: View {
    var screenSize: CGSize
    @State private var stopIndex = 0
    @State private var hasArrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stops: [(point: CGPoint, label: String)] {
        [
            (CGPoint(x: screenSize.width * 0.30, y: screenSize.height * 0.30), "Share button"),
            (CGPoint(x: screenSize.width * 0.62, y: screenSize.height * 0.45), "The Q3 column"),
            (CGPoint(x: screenSize.width * 0.45, y: screenSize.height * 0.68), "Save"),
        ]
    }

    var body: some View {
        let stop = stops[stopIndex]
        AmbientPointerView(label: stop.label, phase: hasArrived ? .arrived : .travelling)
            .position(stop.point)
            .frame(width: screenSize.width, height: screenSize.height)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    hasArrived = false
                    // The ember flies to the next target, then locks on.
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.86)) {
                        stopIndex = (stopIndex + 1) % stops.count
                    }
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    hasArrived = true
                }
            }
            .onAppear { hasArrived = true }
    }
}

// MARK: - Window captures

@MainActor
enum DemoWindowCaptures {
    static func captureAll(into directory: URL, makeSettingsServices: (DemoConnectorService.Behaviour) -> AmbientSettingsServices, settingsModel: AmbientSettingsModel) async {
        let settingsSize = CGSize(width: 820, height: 580)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let appearanceName = appearance == .aqua ? "light" : "dark"
            for section in AmbientSettingsSection.allCases {
                let pageModel = AmbientSettingsModel(generalSettings: settingsModel.generalSettings, account: settingsModel.account)
                pageModel.selectedSection = section
                pageModel.appVersion = "0.1.8"
                // The Account page doubles as the capture of an update waiting.
                if section == .account { pageModel.availableUpdateVersion = "0.1.9" }
                let view = AmbientSettingsView(model: pageModel, services: makeSettingsServices(.normal))
                await DemoCaptureRunner.captureWindowContent(view, size: settingsSize, appearance: appearance, settleSeconds: 0.9,
                                                             to: directory.appendingPathComponent("settings-\(section.rawValue)-\(appearanceName).png"))
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let reportModel = AmbientSettingsModel(generalSettings: settingsModel.generalSettings, account: settingsModel.account)
            reportModel.selectedSection = .activity
            reportModel.selectedBackgroundTaskID = DemoSampleData.inboxTaskIdentifier
            await DemoCaptureRunner.captureWindowContent(AmbientSettingsView(model: reportModel, services: makeSettingsServices(.normal)), size: settingsSize, appearance: appearance, settleSeconds: 0.9,
                                                         to: directory.appendingPathComponent("settings-activity-report-\(appearance == .aqua ? "light" : "dark").png"))
        }
        for (behaviour, name) in [(DemoConnectorService.Behaviour.failing, "error"), (.empty, "empty")] {
            let pageModel = AmbientSettingsModel(generalSettings: settingsModel.generalSettings, account: settingsModel.account)
            pageModel.selectedSection = .connectors
            await DemoCaptureRunner.captureWindowContent(AmbientSettingsView(model: pageModel, services: makeSettingsServices(behaviour)), size: settingsSize, appearance: .darkAqua, settleSeconds: 0.9,
                                                         to: directory.appendingPathComponent("settings-connectors-\(name)-dark.png"))
        }
        let loadingModel = AmbientSettingsModel(generalSettings: settingsModel.generalSettings, account: settingsModel.account)
        loadingModel.selectedSection = .connectors
        await DemoCaptureRunner.captureWindowContent(AmbientSettingsView(model: loadingModel, services: makeSettingsServices(.normal)), size: settingsSize, appearance: .aqua, settleSeconds: 0.15,
                                                     to: directory.appendingPathComponent("settings-connectors-loading-light.png"))
        let signedOutModel = AmbientSettingsModel(generalSettings: settingsModel.generalSettings, account: nil)
        signedOutModel.selectedSection = .account
        await DemoCaptureRunner.captureWindowContent(AmbientSettingsView(model: signedOutModel, services: makeSettingsServices(.normal)), size: settingsSize, appearance: .aqua, settleSeconds: 0.3,
                                                     to: directory.appendingPathComponent("settings-account-signed-out-light.png"))

        let onboardingSize = AmbientOnboardingWindowController.windowSize
        await DemoCaptureRunner.captureWindowContent(AmbientOnboardingPreview.gate(DemoOnboardingContent.signInGate), size: onboardingSize, appearance: .darkAqua, settleSeconds: 0.4,
                                                     to: directory.appendingPathComponent("onboarding-gate.png"))
        await DemoCaptureRunner.captureWindowContent(AmbientOnboardingPreview.gate(DemoOnboardingContent.waitingForBrowserGate), size: onboardingSize, appearance: .darkAqua, settleSeconds: 0.4,
                                                     to: directory.appendingPathComponent("onboarding-gate-waiting.png"))
        let permissionsModel = AmbientPermissionsModel(statuses: [.microphone: .granted, .accessibility: .notYetAsked, .screenRecording: .deniedInSystemSettings, .speechRecognition: .notYetAsked])
        await DemoCaptureRunner.captureWindowContent(AmbientOnboardingPreview.permissions(permissionsModel), size: onboardingSize, appearance: .darkAqua, settleSeconds: 0.4,
                                                     to: directory.appendingPathComponent("onboarding-permissions.png"))
        let allGrantedModel = AmbientPermissionsModel(statuses: [.microphone: .granted, .accessibility: .granted, .screenRecording: .granted, .speechRecognition: .granted])
        await DemoCaptureRunner.captureWindowContent(AmbientOnboardingPreview.permissions(allGrantedModel), size: onboardingSize, appearance: .darkAqua, settleSeconds: 0.4,
                                                     to: directory.appendingPathComponent("onboarding-permissions-granted.png"))

        for backdrop in DemoBackdrop.allCases {
            let canvasSize = CGSize(width: 360, height: 220)
            let pointerScene = ZStack {
                AmbientPointerView(label: "Share button", phase: .arrived).position(x: 110, y: 80)
                AmbientPointerView(label: "Save", phase: .arrived, labelPlacement: .leadingAbove).position(x: 270, y: 170)
            }
            if let rendered = AmbientSnapshotRenderer.renderOverBackdrop(pointerScene, canvasSize: canvasSize, backdrop: backdrop.image(canvasSize: canvasSize, barEdge: .left)),
               let pngData = AmbientSnapshotRenderer.pngData(from: rendered) {
                try? pngData.write(to: directory.appendingPathComponent("pointer-\(backdrop.rawValue).png"))
            }
        }
    }
}
