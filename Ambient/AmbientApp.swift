import SwiftUI
import AVFoundation
import Combine
import ServiceManagement
import Speech
import Sparkle
import AmbientContracts
import AmbientBackground
import AmbientUI

@main
struct AmbientApp: App {
    @NSApplicationDelegateAdaptor(AmbientAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Open Settings") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class AmbientAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AmbientRuntime?
    private var flowBarModel: FlowBarModel?
    private var flowBarController: FlowBarPanelController?
    private var settingsModel: AmbientSettingsModel?
    private var settingsController: AmbientSettingsWindowController?
    private var statusItem: NSStatusItem?
    private var visibilityMenuItem: NSMenuItem?
    private var backgroundUpdatesTask: Task<Void, Never>?
    private var walletTask: Task<Void, Never>?
    private var phaseSubscription: AnyCancellable?
    private var shortcutSubscription: AnyCancellable?
    private let dictationManager = AmbientDictationManager()
    private let shortcutMonitor = GlobalPushToTalkShortcutMonitor()
    private let pointerController = AmbientPointerWindowController()
    /// Drawings get their own window so pointing, or the next request, never takes one away.
    private let drawingController = AmbientPointerWindowController()
    private let permissionsModel = AmbientPermissionsModel()
    private var tourModel: AmbientTourModel?
    private var tourController: AmbientTourPanelController?
    /// Checks for newly connected apps while the tour is on its Connectors lesson; the connector service has no push.
    private var tourConnectorPollingTask: Task<Void, Never>?
    private var shortcutPressedDate: Date?
    private var previousRuntimePhase: AmbientRuntimeState.Phase = .idle
    private var permissionTimer: Timer?
    private var recordingStartTask: Task<Void, Never>?
    private var previousPermissionsWereGranted = false
    private var isUpdatingSettings = false
    /// Sparkle reads the publik update feed from Info.plist, checks at every launch and daily, downloads in the background and asks before relaunching.
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host the app executable but must not start a second live session.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Started before the runtime so an install that cannot start can still receive the fix.
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Sparkle's own schedule only checks once a day, so a relaunch inside that day would find nothing.
        updaterController?.updater.checkForUpdatesInBackground()
        do {
            let runtime = try AmbientRuntime()
            self.runtime = runtime
            runtime.onReady = { [weak self] in self?.startInterface() }
            createStatusItem()
            runtime.start()
        } catch {
            let controller = AmbientOnboardingWindowController()
            settingsStartupErrorController = controller
            Task {
                _ = await controller.presentGate(AmbientGateContent(title: "Ambient could not start", bodyText: error.localizedDescription,
                    buttons: [AmbientGateButton(actionID: "quit", label: "Quit Ambient", prominence: .primary)]))
                NSApp.terminate(nil)
            }
        }
    }

    private var settingsStartupErrorController: AmbientOnboardingWindowController?

    private func startInterface() {
        guard let runtime, flowBarModel == nil else { return }
        let model = FlowBarModel()
        let controller = FlowBarPanelController(model: model)
        flowBarModel = model
        flowBarController = controller
        settingsModel = AmbientSettingsModel(generalSettings: AmbientGeneralSettings(
            pushToTalkShortcut: AmbientPushToTalkShortcut(rawValue: UserDefaults.standard.string(forKey: "ambient.pushToTalkShortcut") ?? "") ?? .controlOption,
            dockEdge: controller.placement.edge,
            speaksReplies: runtime.spokenRepliesEnabled,
            runsCommandsWithoutAsking: runtime.approvalSettings.allowWithoutAsking,
            launchesAtLogin: SMAppService.mainApp.status == .enabled
        ))
        model.onCancelTurn = { [weak self] in self?.cancelTurn() }
        model.onSubmitTypedText = { [weak self] text in
            self?.tourModel?.typedRequestSubmitted()
            self?.submit(text: text)
        }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onCheckForUpdates = { [weak self] in self?.updaterController?.checkForUpdates(nil) }
        model.onCancelBackgroundTask = { [weak runtime] identifier in
            guard let runtime else { return }
            Task { await runtime.backgroundTaskStore.cancel(taskID: identifier) }
        }
        model.onDismissBackgroundTask = { [weak runtime] identifier in
            guard let runtime else { return }
            Task { await runtime.backgroundTaskStore.dismiss(taskID: identifier) }
        }
        model.onOpenBackgroundTaskTranscript = { [weak self] identifier in
            self?.settingsModel?.selectedBackgroundTaskID = identifier
            self?.openSettings(section: .activity)
        }
        // The panel persists the whole placement, including display and position, before this callback.
        model.onDockEdgeChanged = { [weak self] edge in
            guard let self else { return }
            self.settingsModel?.generalSettings.dockEdge = edge
            self.tourModel?.dockEdgeChanged(to: edge)
            self.tourController?.barMoved(to: edge, on: self.flowBarController?.dockedScreen)
        }
        model.onOpenURL = { NSWorkspace.shared.open($0) }
        runtime.onAgentEvent = { [weak self, weak model] event in
            model?.apply(event)
            self?.tourModel?.apply(event)
        }
        runtime.interaction.approvalHandler = { [weak self, weak model] title, detail in
            guard let self, let model else { return false }
            self.showBar()
            let kind: FlowBarApprovalRequest.Kind = title == "Run shell command?" ? .shellCommand
                : (["Start Codex agent?", "Start Claude agent?", "Start agent?", "Continue agent?"].contains(title) ? .backgroundAgent : .other)
            NSLog("Ambient approval presented: %@", title)
            self.tourModel?.approvalRequested(kind: kind)
            let allowed = await model.requestApproval(FlowBarApprovalRequest(title: title, detail: detail, kind: kind))
            NSLog("Ambient approval answered: %@", String(allowed))
            if kind == .backgroundAgent { self.tourModel?.approvalAnswered(isAllowed: allowed) }
            return allowed
        }
        runtime.interaction.cancelApprovalHandler = { [weak model] in model?.returnToIdle() }
        phaseSubscription = runtime.state.$phase.sink { [weak self, weak model] phase in
            guard let self, let model else { return }
            // Transcribing straight to idle is a recording in which nothing was heard: an empty transcript.
            if case .transcribing = self.previousRuntimePhase, case .idle = phase { self.tourModel?.heardNothing() }
            self.previousRuntimePhase = phase
            switch phase {
            case .idle: model.returnToIdle()
            case .listening(let level):
                if model.turnPhase != .listening { model.beginListening() }
                model.updateAudioLevel(Double(level))
                self.showBar()
            case .transcribing: model.beginTranscribing(); self.showBar()
            case .thinking: model.beginThinking(); self.tourModel?.thinkingStarted(); self.showBar()
            // These arrive verbatim through onAgentEvent, not reconstructed from accumulated state.
            case .working, .responding, .finished, .failed: break
            }
        }
        runtime.screenTools.pointHandler = { [weak self] location, frame, label in
            self?.pointerController.show(at: location, displayFrame: frame, label: label)
        }
        runtime.screenTools.drawHandler = { [weak self] annotations, frame in
            self?.drawingController.show(annotations: annotations, displayFrame: frame)
        }
        runtime.screenTools.clearDrawingHandler = { [weak self] in
            guard let self, self.drawingController.isShowing else { return false }
            self.drawingController.hide()
            return true
        }
        dictationManager.audioLevelChanged = { [weak runtime] in runtime?.updateAudioLevel($0) }
        dictationManager.recordingFinished = { [weak runtime] in runtime?.submit(recordedWAV: $0) }
        dictationManager.recordingFailed = { [weak runtime] in runtime?.reportFailure(.other(message: $0.localizedDescription)) }
        shortcutSubscription = shortcutMonitor.shortcutTransitionPublisher.sink { [weak self] in self?.handleShortcut($0) }
        settingsModel?.onGeneralSettingsChanged = { [weak self] in self?.applySettings($0) }
        shortcutMonitor.shortcut = settingsModel?.generalSettings.pushToTalkShortcut ?? .controlOption
        model.pushToTalkShortcut = shortcutMonitor.shortcut
        backgroundUpdatesTask = Task { [weak model] in
            for await tasks in runtime.backgroundTaskStore.updates() {
                guard !Task.isCancelled else { return }
                model?.setBackgroundTasks(tasks)
                NSLog("Ambient task tray updated: %ld tasks, %ld running", tasks.count, tasks.filter { $0.status == .running }.count)
            }
        }
        permissionsModel.onGrant = { [weak self] in self?.grantPermission($0) }
        permissionsModel.onContinue = { [weak self] in self?.continueOnboarding() }
        refreshPermissions()
        if !UserDefaults.standard.bool(forKey: "ambient.onboardingCompleted") || !permissionsModel.areRequiredPermissionsGranted {
            showPermissions()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        showBar()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Ambient")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Open Settings", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        let visibility = menu.addItem(withTitle: "Show Bar", action: #selector(toggleBar), keyEquivalent: "")
        visibility.target = self
        visibilityMenuItem = visibility
        let replayTour = menu.addItem(withTitle: "Replay the Tour", action: #selector(replayTourFromMenu), keyEquivalent: "")
        replayTour.target = self
        let clearDrawing = menu.addItem(withTitle: "Clear Drawing", action: #selector(clearDrawingFromMenu), keyEquivalent: "")
        clearDrawing.target = self
        let checkForUpdates = menu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = updaterController
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ambient", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func clearDrawingFromMenu() { drawingController.hide() }

    private func showBar() {
        flowBarController?.show()
        visibilityMenuItem?.title = "Hide Bar"
    }

    @objc private func toggleBar() {
        guard let controller = flowBarController else { return }
        if controller.panelWindow.isVisible {
            controller.hide()
            visibilityMenuItem?.title = "Show Bar"
        } else { showBar() }
    }

    @objc private func openSettingsFromMenu() { openSettings() }

    func openSettings(section: AmbientSettingsSection? = nil) {
        guard let runtime, let settingsModel else { return }
        if settingsController == nil {
            settingsController = AmbientSettingsWindowController(model: settingsModel, services: AmbientSettingsServices(
                connectorService: runtime.connectorService, memoryStore: runtime.memoryStore,
                skillStore: runtime.skillStore, backgroundTaskStore: runtime.backgroundTaskStore
            ))
        }
        settingsController?.show(section: section)
        walletTask?.cancel()
        walletTask = Task {
            guard let credential = await runtime.credentialSource.credential() else { return }
            do {
                var request = URLRequest(url: credential.baseURL.appendingPathComponent("wallet"), timeoutInterval: 15)
                request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let wallet = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AgentFailure.other(message: "Your publik account could not be loaded.")
                }
                settingsModel.account = Self.accountSummary(from: wallet, baseURL: credential.baseURL)
                NSLog("Ambient account loaded: handle=%@ plan=%@ percentage=%@", String(settingsModel.account?.publikHandle != nil), String(settingsModel.account?.planName != nil), String(settingsModel.account?.usageRemainingFraction != nil))
            } catch {
                guard !Task.isCancelled else { return }
                runtime.reportFailure(.other(message: "Your publik account could not be loaded. Try opening Settings again."))
            }
        }
    }

    static func accountSummary(from wallet: [String: Any], baseURL: URL) -> AmbientAccountSummary {
        let account = wallet["account"] as? [String: Any]
        let plan = wallet["plan"] as? [String: Any]
        let percentage = (wallet["remaining_percent"] as? NSNumber)?.doubleValue ?? (wallet["prepaid_remaining_percent"] as? NSNumber)?.doubleValue
        let reset = (wallet["resets_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let accountURL = (wallet["top_up_url"] as? String).flatMap(URL.init(string:)) ?? baseURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wallet")
        return AmbientAccountSummary(publikHandle: account?["handle"] as? String, planName: plan?["label"] as? String,
            usageRemainingFraction: percentage.map { min(1, max(0, $0 / 100)) }, usageResetsOn: reset, manageAccountURL: accountURL)
    }

    private func applySettings(_ settings: AmbientGeneralSettings) {
        guard !isUpdatingSettings, let runtime else { return }
        runtime.spokenRepliesEnabled = settings.speaksReplies
        runtime.approvalSettings.allowWithoutAsking = settings.runsCommandsWithoutAsking
        UserDefaults.standard.set(settings.pushToTalkShortcut.rawValue, forKey: "ambient.pushToTalkShortcut")
        shortcutMonitor.shortcut = settings.pushToTalkShortcut
        flowBarModel?.pushToTalkShortcut = settings.pushToTalkShortcut
        tourModel?.shortcut = settings.pushToTalkShortcut
        if flowBarController?.placement.edge != settings.dockEdge { flowBarController?.dock(to: settings.dockEdge) }
        if settings.launchesAtLogin != (SMAppService.mainApp.status == .enabled) {
            do {
                if settings.launchesAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                runtime.reportFailure(.other(message: "Open at login could not be changed. Check Login Items in System Settings."))
            }
            isUpdatingSettings = true
            settingsModel?.generalSettings.launchesAtLogin = SMAppService.mainApp.status == .enabled
            isUpdatingSettings = false
        }
    }

    private func refreshPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        permissionsModel.statuses = [
            .microphone: microphone == .authorized ? .granted : (microphone == .notDetermined
                ? (permissionsModel.status(of: .microphone) == .waiting ? .waiting : .notYetAsked) : .deniedInSystemSettings),
            .accessibility: AmbientPermissionHelper.hasAccessibilityPermission() ? .granted
                : (UserDefaults.standard.bool(forKey: "ambient.accessibilityRequested") ? .deniedInSystemSettings : .notYetAsked),
            .screenRecording: AmbientPermissionHelper.hasScreenRecordingPermission() ? .granted
                : (UserDefaults.standard.bool(forKey: "ambient.screenRecordingRequested") ? .deniedInSystemSettings : .notYetAsked),
            .speechRecognition: Self.permissionStatus(forSpeechRecognition: AmbientPermissionHelper.speechRecognitionAuthorizationStatus(),
                                                      isWaitingForAnswer: permissionsModel.status(of: .speechRecognition) == .waiting)
        ]
        if permissionsModel.status(of: .accessibility) == .granted { shortcutMonitor.start() }
        else { shortcutMonitor.stop() }
        tourModel?.permissionStatusesChanged(permissionsModel.statuses)
        if previousPermissionsWereGranted && !permissionsModel.areRequiredPermissionsGranted { showPermissions() }
        previousPermissionsWereGranted = permissionsModel.areRequiredPermissionsGranted
    }

    static func permissionStatus(forSpeechRecognition authorization: SFSpeechRecognizerAuthorizationStatus, isWaitingForAnswer: Bool) -> AmbientPermissionStatus {
        switch authorization {
        case .authorized: return .granted
        case .notDetermined: return isWaitingForAnswer ? .waiting : .notYetAsked
        case .denied, .restricted: return .deniedInSystemSettings
        @unknown default: return .deniedInSystemSettings
        }
    }

    private func showPermissions() {
        guard let runtime else { return }
        runtime.interaction.onboardingController.showPermissions(permissionsModel)
    }

    private func grantPermission(_ kind: AmbientPermissionKind) {
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                permissionsModel.statuses[.microphone] = .waiting
                Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        case .accessibility:
            // Always ask the system first: asking is what puts Ambient in the System Settings list, and the list
            // can be empty even after an earlier ask (a reset, or a grant made to a differently signed build).
            UserDefaults.standard.set(true, forKey: "ambient.accessibilityRequested")
            AmbientPermissionHelper.requestAccessibilityPermission()
        case .screenRecording:
            let wasAlreadyAsked = permissionsModel.status(of: .screenRecording) == .deniedInSystemSettings
            UserDefaults.standard.set(true, forKey: "ambient.screenRecordingRequested")
            // macOS shows this prompt once; later calls are silent but still list Ambient in System Settings.
            _ = CGRequestScreenCaptureAccess()
            if wasAlreadyAsked { AmbientPermissionHelper.openScreenRecordingSettings() }
        case .speechRecognition:
            if AmbientPermissionHelper.speechRecognitionAuthorizationStatus() == .notDetermined {
                permissionsModel.statuses[.speechRecognition] = .waiting
                Task { _ = await AmbientPermissionHelper.requestSpeechRecognitionPermission(); refreshPermissions() }
            } else {
                AmbientPermissionHelper.openSpeechRecognitionSettings()
            }
        }
        refreshPermissions()
    }

    private func continueOnboarding() {
        guard let runtime else { return }
        runtime.interaction.onboardingController.close()
        if !UserDefaults.standard.bool(forKey: "ambient.onboardingCompleted") { startTour() }
    }

    @objc private func replayTourFromMenu() { startTour() }

    /// The guided tour runs on the real desktop with the real bar; the coach only watches and explains.
    private func startTour() {
        guard flowBarController != nil else { return }
        endTour()
        showBar()
        let model = AmbientTourModel(shortcut: shortcutMonitor.shortcut, dockEdge: flowBarController?.placement.edge ?? .bottom)
        model.permissionStatusesChanged(permissionsModel.statuses)
        model.onFixPermission = { [weak self] kind in self?.grantPermission(kind) }
        model.onOpenConnectors = { [weak self] in self?.openSettings(section: .connectors) }
        model.onFinish = { [weak self] in
            UserDefaults.standard.set(true, forKey: "ambient.onboardingCompleted")
            self?.endTour()
        }
        let controller = AmbientTourPanelController(model: model)
        tourModel = model
        tourController = controller
        controller.show(awayFromBarDockedTo: flowBarController?.placement.edge ?? .bottom, on: flowBarController?.dockedScreen)
        startPollingConnectedAppsDuringTour()
        NSLog("Ambient tour started")
    }

    private func endTour() {
        tourConnectorPollingTask?.cancel()
        tourConnectorPollingTask = nil
        tourController?.close()
        tourController = nil
        tourModel = nil
    }

    private func startPollingConnectedAppsDuringTour() {
        guard let connectorService = runtime?.connectorService else { return }
        tourConnectorPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.tourModel?.currentLesson == .connectApps {
                    // An unreachable connector service is not the person's problem to solve in the tour; the
                    // lesson simply stays open and "Later" moves on.
                    if let apps = try? await connectorService.apps(matching: "") {
                        guard !Task.isCancelled else { return }
                        self?.tourModel?.connectedAppsChanged(names: apps.filter(\.isConnected).map(\.name))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handleShortcut(_ transition: AmbientShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            shortcutPressedDate = Date()
            // Before the turn is cancelled, so the coach treats the cancelled turn's idle as part of a new hold.
            tourModel?.shortcutPressed()
            cancelTurn()
            pointerController.hide()
            runtime?.beginListening()
            recordingStartTask = Task { await dictationManager.startRecording() }
        case .released:
            tourModel?.shortcutReleased(heldFor: shortcutPressedDate.map { Date().timeIntervalSince($0) } ?? 0)
            shortcutPressedDate = nil
            recordingStartTask?.cancel()
            recordingStartTask = nil
            if !dictationManager.finishRecording(), case .listening = runtime?.state.phase { runtime?.cancelCurrentTurn() }
        case .none: break
        }
    }

    private func cancelTurn() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
        dictationManager.cancelCurrentDictation()
        runtime?.cancelCurrentTurn()
    }

    private func submit(text: String) {
        dictationManager.cancelCurrentDictation()
        pointerController.hide()
        runtime?.submit(text: text)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let text = Self.automationText(from: url) { submit(text: text); continue }
        }
    }

    static func automationText(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "ambient", url.host == "ask",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelTurn()
        runtime?.stop()
        shortcutMonitor.stop()
        backgroundUpdatesTask?.cancel()
        walletTask?.cancel()
        permissionTimer?.invalidate()
        endTour()
        pointerController.hide()
        drawingController.hide()
        flowBarController?.hide()
    }
}
