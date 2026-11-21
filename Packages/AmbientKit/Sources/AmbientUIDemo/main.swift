// AmbientUIDemo: runs Ambient's interface alone, with scripted states and in-memory services.
//
//   swift run --scratch-path .build-ui AmbientUIDemo --state responding --edge left --quit-after 6
//   swift run --scratch-path .build-ui AmbientUIDemo --script --quit-after 60
//   swift run --scratch-path .build-ui AmbientUIDemo --settings connectors --quit-after 10
//   swift run --scratch-path .build-ui AmbientUIDemo --capture docs/ui-captures
//
// Every on-screen run should pass --quit-after so the demo never stays on the screen by accident.

import AmbientContracts
import AmbientUI
import AppKit
import SwiftUI

/// The parsed command line.
struct DemoLaunchOptions {
    var flowBarState: DemoFlowBarState?
    var dockEdge: FlowBarDockEdge = .bottom
    var runsScript = false
    var settingsSection: AmbientSettingsSection?
    var opensSettings = false
    var onboardingScreen: DemoOnboardingScreen?
    var showsPointer = false
    var captureDirectory: URL?
    var captureEdges: [FlowBarDockEdge] = [.bottom, .left]
    var captureStates: [DemoFlowBarState] = DemoFlowBarState.allCases
    var capturesWindows = true
    var quitAfterSeconds: Double?
    /// Takes a screenshot of the bar's region after this many seconds, then quits. Needs screen recording permission.
    var screenshotPath: String?
    var screenshotDelaySeconds: Double = 1.5
    var hidesBar = false

    static func parse(_ arguments: [String]) -> DemoLaunchOptions {
        var options = DemoLaunchOptions()
        var argumentIndex = 1
        func nextValue() -> String? {
            guard argumentIndex + 1 < arguments.count, !arguments[argumentIndex + 1].hasPrefix("--") else { return nil }
            argumentIndex += 1
            return arguments[argumentIndex]
        }
        while argumentIndex < arguments.count {
            switch arguments[argumentIndex] {
            case "--state":
                if let name = nextValue() {
                    guard let state = DemoFlowBarState(rawValue: name) else {
                        print("Unknown state \(name). Known: \(DemoFlowBarState.allCases.map(\.rawValue).joined(separator: ", "))")
                        exit(2)
                    }
                    options.flowBarState = state
                }
            case "--edge":
                if let name = nextValue(), let edge = FlowBarDockEdge(rawValue: name) { options.dockEdge = edge }
            case "--script":
                options.runsScript = true
            case "--settings":
                options.opensSettings = true
                if let name = nextValue() { options.settingsSection = AmbientSettingsSection(rawValue: name) }
            case "--onboarding":
                options.onboardingScreen = nextValue().flatMap(DemoOnboardingScreen.init(rawValue:)) ?? .firstRun
            case "--pointer":
                options.showsPointer = true
            case "--no-bar":
                options.hidesBar = true
            case "--capture":
                options.captureDirectory = URL(fileURLWithPath: nextValue() ?? "docs/ui-captures")
            case "--capture-edges":
                if let list = nextValue() { options.captureEdges = list.split(separator: ",").compactMap { FlowBarDockEdge(rawValue: String($0)) } }
            case "--capture-states":
                if let list = nextValue() { options.captureStates = list.split(separator: ",").compactMap { DemoFlowBarState(rawValue: String($0)) } }
            case "--capture-bar-only":
                options.capturesWindows = false
            case "--quit-after":
                options.quitAfterSeconds = nextValue().flatMap(Double.init)
            case "--screenshot":
                options.screenshotPath = nextValue()
            case "--screenshot-delay":
                options.screenshotDelaySeconds = nextValue().flatMap(Double.init) ?? 1.5
            default:
                print("Ignoring unknown argument \(arguments[argumentIndex])")
            }
            argumentIndex += 1
        }
        return options
    }
}

@MainActor
final class DemoApplicationDelegate: NSObject, NSApplicationDelegate {
    private let options: DemoLaunchOptions
    private let flowBarModel = FlowBarModel()
    private var flowBarController: FlowBarPanelController?
    private let backgroundTaskStore = DemoBackgroundTaskStore()
    private lazy var settingsModel = AmbientSettingsModel(
        generalSettings: AmbientGeneralSettings(dockEdge: options.dockEdge),
        account: AmbientAccountSummary(
            publikHandle: "jabir",
            planName: "Plus",
            usageRemainingFraction: 0.64,
            usageResetsOn: Calendar.current.date(byAdding: .day, value: 11, to: Date()),
            manageAccountURL: URL(string: "https://publik.example/account")!
        )
    )
    private var settingsController: AmbientSettingsWindowController?
    private var speechSimulator: DemoSpeechLevelSimulator?
    private var onboardingDirector: DemoOnboardingDirector?
    private var pointerDirector: DemoPointerDirector?

    init(options: DemoLaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let quitAfterSeconds = options.quitAfterSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + quitAfterSeconds) { NSApp.terminate(nil) }
        }
        if let captureDirectory = options.captureDirectory {
            Task { await runCaptures(into: captureDirectory) }
            return
        }

        wireFlowBarIntents()
        if !options.hidesBar { showFlowBar() }

        if options.opensSettings { openSettings(section: options.settingsSection) }
        if let onboardingScreen = options.onboardingScreen {
            let director = DemoOnboardingDirector(flowBarController: flowBarController)
            onboardingDirector = director
            director.show(onboardingScreen)
        }
        if options.showsPointer {
            let director = DemoPointerDirector()
            pointerDirector = director
            director.show()
        }
        if let screenshotPath = options.screenshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.screenshotDelaySeconds) { [weak self] in
                self?.takeScreenshotOfBarRegion(to: screenshotPath)
                NSApp.terminate(nil)
            }
        }
    }

    /// Prints where the bar really ended up, so a short on-screen run can be checked even without a screenshot.
    func applicationWillTerminate(_ notification: Notification) {
        guard let controller = flowBarController, let screen = controller.dockedScreen else { return }
        let surfaceFrame = controller.barSurfaceFrameOnScreen
        let visibleFrame = screen.visibleFrame
        print("Placement: \(controller.placement.edge.rawValue) at \(controller.placement.positionAlongEdge) on \(screen.localizedName)")
        print("Visible frame: \(visibleFrame)")
        print("Panel frame: \(controller.panelWindow.frame)")
        print("Bar surface: \(surfaceFrame) inside visible frame: \(visibleFrame.contains(surfaceFrame))")
        print("Presentation: \(flowBarModel.presentation.rawValue)")
    }

    // MARK: Flow bar

    private func showFlowBar() {
        let placementStore = FlowBarPlacementStore(userDefaults: UserDefaults(suiteName: "ambient.ui.demo") ?? .standard)
        let controller = FlowBarPanelController(model: flowBarModel, placementStore: placementStore)
        flowBarController = controller
        controller.show()
        controller.dock(to: options.dockEdge)

        // Keeps the bar's task list in sync with the fake store, the way the app wires BackgroundTaskStore.
        Task { [flowBarModel, backgroundTaskStore] in
            for await tasks in backgroundTaskStore.updates() {
                if options.flowBarState == nil && !options.runsScript { continue }
                flowBarModel.setBackgroundTasks(tasks)
            }
        }

        if options.runsScript {
            Task { await DemoScript(model: flowBarModel, backgroundTaskStore: backgroundTaskStore, speechSimulatorFactory: makeSpeechSimulator).run() }
        } else if let state = options.flowBarState {
            DemoScenarioDirector.apply(state, to: flowBarModel)
            if state == .listening || state == .listeningQuiet {
                makeSpeechSimulator().start()
            }
            if state == .restingWithTasks || state == .hoveringWithTasks || state == .taskTray || state == .taskFinished {
                // The scenario already set its own list; stop the store from overwriting it.
            }
        }
    }

    private func makeSpeechSimulator() -> DemoSpeechLevelSimulator {
        let simulator = DemoSpeechLevelSimulator(model: flowBarModel)
        speechSimulator = simulator
        return simulator
    }

    private func wireFlowBarIntents() {
        flowBarModel.onOpenSettings = { [weak self] in self?.openSettings(section: nil) }
        flowBarModel.onCancelTurn = { print("Intent: cancel the current turn") }
        flowBarModel.onSubmitTypedText = { [weak self] text in
            print("Intent: submit typed text \"\(text)\"")
            guard let self else { return }
            Task { await DemoScript(model: self.flowBarModel, backgroundTaskStore: self.backgroundTaskStore, speechSimulatorFactory: self.makeSpeechSimulator).answer(typedText: text) }
        }
        flowBarModel.onCancelBackgroundTask = { [backgroundTaskStore] taskID in
            print("Intent: cancel background task \(taskID)")
            Task { await backgroundTaskStore.cancel(taskID: taskID) }
        }
        flowBarModel.onDismissBackgroundTask = { [backgroundTaskStore] taskID in
            print("Intent: dismiss background task \(taskID)")
            Task { await backgroundTaskStore.dismiss(taskID: taskID) }
        }
        flowBarModel.onOpenBackgroundTaskTranscript = { [weak self] taskID in
            print("Intent: open transcript of \(taskID)")
            self?.openSettings(section: .activity)
        }
        flowBarModel.onDockEdgeChanged = { [weak self] edge in
            print("Intent: dock edge changed to \(edge.rawValue)")
            self?.settingsModel.generalSettings.dockEdge = edge
        }
        flowBarModel.onOpenURL = { url in print("Intent: open \(url.absoluteString)") }
    }

    // MARK: Settings

    private func openSettings(section: AmbientSettingsSection?) {
        if settingsController == nil {
            settingsModel.onOpenURL = { url in print("Intent: open \(url.absoluteString)") }
            settingsModel.onGeneralSettingsChanged = { [weak self] settings in
                print("Intent: general settings changed \(settings)")
                if self?.flowBarController?.placement.edge != settings.dockEdge {
                    self?.flowBarController?.dock(to: settings.dockEdge)
                }
            }
            settingsController = AmbientSettingsWindowController(model: settingsModel, services: makeSettingsServices())
        }
        settingsController?.show(section: section)
    }

    private func makeSettingsServices(connectorBehaviour: DemoConnectorService.Behaviour = .normal) -> AmbientSettingsServices {
        AmbientSettingsServices(
            connectorService: DemoConnectorService(behaviour: connectorBehaviour),
            memoryStore: DemoMemoryStore(),
            skillStore: DemoSkillStore(),
            backgroundTaskStore: backgroundTaskStore
        )
    }

    // MARK: Captures

    private func runCaptures(into directory: URL) async {
        print("Rendering flow bar states into \(directory.path)")
        await DemoCaptureRunner.captureFlowBarStates(into: directory, edges: options.captureEdges, states: options.captureStates, backdrops: DemoBackdrop.allCases, includeIncreasedContrast: true)
        if options.capturesWindows {
            print("Rendering windows")
            await DemoWindowCaptures.captureAll(into: directory, makeSettingsServices: makeSettingsServices, settingsModel: settingsModel)
        }
        print("Done")
        NSApp.terminate(nil)
    }

    /// Uses the system screenshot tool on the bar's panel region, so live glass is captured exactly as composited.
    private func takeScreenshotOfBarRegion(to path: String) {
        guard let controller = flowBarController, let mainScreen = NSScreen.screens.first else { return }
        let panelFrame = controller.panelWindow.frame
        // screencapture takes rectangles with the origin at the top-left of the main display.
        let topLeftY = mainScreen.frame.maxY - panelFrame.maxY
        let region = "\(Int(panelFrame.minX)),\(Int(topLeftY)),\(Int(panelFrame.width)),\(Int(panelFrame.height))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", region, path]
        try? process.run()
        process.waitUntilExit()
        print("Screenshot \(region) -> \(path)")
    }
}

/// Feeds the waveform a level that moves like speech: syllables, short pauses and breath, many times a second.
@MainActor
final class DemoSpeechLevelSimulator {
    private weak var model: FlowBarModel?
    private var timer: Timer?
    private let startDate = Date()

    init(model: FlowBarModel) {
        self.model = model
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 45.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let elapsedSeconds = Date().timeIntervalSince(startDate)
        // Syllables at about 4 a second, grouped into words with gaps, over a slower phrase envelope.
        let syllable = max(0, sin(elapsedSeconds * 2 * .pi * 4.1))
        let word = max(0, sin(elapsedSeconds * 2 * .pi * 0.9 + 0.6))
        let phrase = 0.55 + 0.45 * sin(elapsedSeconds * 2 * .pi * 0.23)
        let noise = Double.random(in: 0...0.12)
        model?.updateAudioLevel(min(1, (0.15 + 0.85 * syllable * word) * phrase + noise))
    }
}

MainActor.assumeIsolated {
    let launchOptions = DemoLaunchOptions.parse(CommandLine.arguments)
    let application = NSApplication.shared
    // No Dock icon: like the real app, the demo lives on the edge of the screen.
    application.setActivationPolicy(.accessory)
    let applicationDelegate = DemoApplicationDelegate(options: launchOptions)
    application.delegate = applicationDelegate
    application.run()
}
