import AmbientContracts
import AmbientUI
import AppKit
import SwiftUI

/// Renders every coach state of the guided tour, with the real bar beside it, over the light and dark desktops.
/// Each scenario drives the tour model with the same events the app feeds it, so the captures show real output.
@MainActor
enum DemoTourCaptures {

    struct Scenario {
        var name: String
        var barEdge: FlowBarDockEdge = .bottom
        /// Puts the tour model into the state to capture, with the events the app would send.
        var driveTour: (AmbientTourModel) -> Void
        /// Puts the bar into the matching state.
        var driveBar: (FlowBarModel) -> Void = { _ in }
    }

    static let allPermissionsGranted: [AmbientPermissionKind: AmbientPermissionStatus] = [
        .microphone: .granted, .accessibility: .granted, .screenRecording: .granted, .speechRecognition: .granted,
    ]

    static func captureAll(into directory: URL) async {
        let tourDirectory = directory.appendingPathComponent("tour")
        try? FileManager.default.createDirectory(at: tourDirectory, withIntermediateDirectories: true)
        let canvasSize = CGSize(width: 1000, height: 640)
        for backdrop in DemoBackdrop.allCases {
            for scenario in scenarios {
                let tourModel = AmbientTourModel()
                tourModel.permissionStatusesChanged(allPermissionsGranted)
                scenario.driveTour(tourModel)
                let barModel = FlowBarModel()
                barModel.revealsReplyInstantly = true
                scenario.driveBar(barModel)
                // Approvals resume through a Task before they render.
                try? await Task.sleep(nanoseconds: 30_000_000)
                let canvas = AmbientSnapshotRenderer.tourCanvas(tourModel: tourModel, barModel: barModel, barEdge: scenario.barEdge,
                                                                canvasSize: canvasSize, backdrop: backdrop.image(canvasSize: canvasSize, barEdge: scenario.barEdge))
                await DemoCaptureRunner.captureWindowContent(canvas, size: canvasSize, appearance: .darkAqua, settleSeconds: 0.3,
                                                             to: tourDirectory.appendingPathComponent("tour-\(scenario.name)-\(backdrop.rawValue).png"))
            }
        }

        let onboardingSize = AmbientOnboardingWindowController.windowSize
        let permissionsModel = AmbientPermissionsModel(statuses: [.microphone: .granted, .accessibility: .notYetAsked, .screenRecording: .deniedInSystemSettings, .speechRecognition: .notYetAsked])
        await DemoCaptureRunner.captureWindowContent(AmbientOnboardingPreview.permissions(permissionsModel), size: onboardingSize, appearance: .darkAqua, settleSeconds: 0.4,
                                                     to: tourDirectory.appendingPathComponent("permissions-four-rows.png"))
        let requiredGrantedModel = AmbientPermissionsModel(statuses: [.microphone: .granted, .accessibility: .granted, .screenRecording: .granted, .speechRecognition: .notYetAsked])
        await DemoCaptureRunner.captureWindowContent(AmbientOnboardingPreview.permissions(requiredGrantedModel), size: onboardingSize, appearance: .darkAqua, settleSeconds: 0.4,
                                                     to: tourDirectory.appendingPathComponent("permissions-required-granted.png"))
    }

    // MARK: Scenarios

    static func skip(_ tourModel: AmbientTourModel, to lesson: AmbientTourLesson) {
        while let currentLesson = tourModel.currentLesson, currentLesson != lesson { tourModel.skipCurrentLesson() }
    }

    static func reply(_ barModel: FlowBarModel, _ text: String, tools: [(String, String)] = []) {
        barModel.beginThinking()
        for (index, tool) in tools.enumerated() {
            barModel.apply(.toolStarted(callID: "\(index)", toolName: tool.0, activityLabel: tool.1))
            barModel.apply(.toolFinished(callID: "\(index)", toolName: tool.0, isError: false))
        }
        barModel.apply(.textDelta(text))
        barModel.apply(.finished(finalText: text))
    }

    static let talkReply = "I can answer questions, look at your screen and point things out, and start agents that work in the background while you keep going."
    static let regularReply = "Tomorrow is Saturday, and your calendar is clear."

    static var scenarios: [Scenario] {
        [
            Scenario(name: "1-talk-waiting", driveTour: { _ in }),
            Scenario(name: "1-talk-listening", driveTour: { $0.shortcutPressed() }, driveBar: { barModel in
                barModel.beginListening()
                barModel.updateAudioLevel(0.6)
            }),
            Scenario(name: "1-talk-thinking", driveTour: { tourModel in
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 2.1)
            }, driveBar: { $0.beginThinking() }),
            Scenario(name: "1-talk-nudge-short-hold", driveTour: { tourModel in
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 0.12)
            }),
            Scenario(name: "1-talk-nudge-heard-nothing", driveTour: { tourModel in
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 1.4)
                tourModel.heardNothing()
            }),
            Scenario(name: "1-talk-microphone-missing", driveTour: { tourModel in
                var statuses = allPermissionsGranted
                statuses[.microphone] = .deniedInSystemSettings
                tourModel.permissionStatusesChanged(statuses)
            }),
            Scenario(name: "1-talk-failed", driveTour: { tourModel in
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 1.8)
                tourModel.apply(.failed(.other(message: "Ambient could not reach the internet.")))
            }, driveBar: { barModel in
                barModel.beginThinking()
                barModel.apply(.failed(.other(message: "Ambient could not reach the internet. Check your connection and try again.")))
            }),
            Scenario(name: "1-talk-answering", driveTour: { tourModel in
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 1.8)
                tourModel.thinkingStarted()
                tourModel.apply(.textDelta("I can"))
            }, driveBar: { barModel in
                barModel.beginThinking()
                barModel.apply(.textDelta(String(talkReply.prefix(60))))
            }),
            Scenario(name: "1-talk-completed", driveTour: { tourModel in
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 1.8)
                tourModel.apply(.textDelta(talkReply))
                tourModel.apply(.finished(finalText: talkReply))
            }, driveBar: { reply($0, talkReply) }),

            Scenario(name: "2-screen-waiting", driveTour: { skip($0, to: .showScreen) }),
            Scenario(name: "2-screen-recording-missing", driveTour: { tourModel in
                skip(tourModel, to: .showScreen)
                var statuses = allPermissionsGranted
                statuses[.screenRecording] = .notYetAsked
                tourModel.permissionStatusesChanged(statuses)
            }),
            Scenario(name: "2-screen-working", driveTour: { tourModel in
                skip(tourModel, to: .showScreen)
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 2.0)
                tourModel.apply(.toolStarted(callID: "1", toolName: "look_at_screen", activityLabel: "Looking at your screen"))
            }, driveBar: { barModel in
                barModel.beginThinking()
                barModel.apply(.toolStarted(callID: "1", toolName: "look_at_screen", activityLabel: "Looking at your screen"))
            }),
            Scenario(name: "2-screen-nudge-regular-answer", driveTour: { tourModel in
                skip(tourModel, to: .showScreen)
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 1.5)
                tourModel.apply(.textDelta(regularReply))
                tourModel.apply(.finished(finalText: regularReply))
            }, driveBar: { reply($0, regularReply) }),
            Scenario(name: "2-screen-completed", driveTour: { tourModel in
                skip(tourModel, to: .showScreen)
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 2.0)
                tourModel.apply(.toolStarted(callID: "1", toolName: "look_at_screen", activityLabel: "Looking at your screen"))
                tourModel.apply(.toolFinished(callID: "1", toolName: "look_at_screen", isError: false))
                tourModel.apply(.toolStarted(callID: "2", toolName: "draw_on_screen", activityLabel: "Drawing on your screen"))
                tourModel.apply(.toolFinished(callID: "2", toolName: "draw_on_screen", isError: false))
            }, driveBar: { reply($0, "It's the Apple logo in the top-left corner of your screen. I circled it.", tools: [("look_at_screen", "Looking at your screen"), ("draw_on_screen", "Drawing on your screen")]) }),

            Scenario(name: "3-agent-waiting", driveTour: { skip($0, to: .handOff) }),
            Scenario(name: "3-agent-approval", driveTour: { tourModel in
                skip(tourModel, to: .handOff)
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 2.4)
                tourModel.apply(.toolStarted(callID: "1", toolName: "spawn_agent", activityLabel: "Starting an agent"))
                tourModel.approvalRequested(kind: .backgroundAgent)
            }, driveBar: { barModel in
                barModel.beginThinking()
                let request = FlowBarApprovalRequest(title: "Start agent?", detail: "Find three good pizza places near me.", kind: .backgroundAgent)
                Task { _ = await barModel.requestApproval(request) }
            }),
            Scenario(name: "3-agent-denied", driveTour: { tourModel in
                skip(tourModel, to: .handOff)
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 2.4)
                tourModel.approvalRequested(kind: .backgroundAgent)
                tourModel.approvalAnswered(isAllowed: false)
                tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: true))
            }),
            Scenario(name: "3-agent-completed", driveTour: { tourModel in
                skip(tourModel, to: .handOff)
                tourModel.shortcutPressed()
                tourModel.shortcutReleased(heldFor: 2.4)
                tourModel.approvalRequested(kind: .backgroundAgent)
                tourModel.approvalAnswered(isAllowed: true)
                tourModel.apply(.toolFinished(callID: "1", toolName: "spawn_agent", isError: false))
            }, driveBar: { barModel in
                barModel.setBackgroundTasks([BackgroundTask(
                    id: UUID(), kind: .ambientAgent, title: "Find three good pizza places near me",
                    status: .running, workingDirectory: nil, startedAt: Date().addingTimeInterval(-6), finishedAt: nil,
                    latestActivity: "Searching the web", result: nil)])
            }),

            Scenario(name: "4-connect-waiting", driveTour: { skip($0, to: .connectApps) }),
            Scenario(name: "4-connect-in-browser", driveTour: { tourModel in
                skip(tourModel, to: .connectApps)
                tourModel.openConnectors()
            }),
            Scenario(name: "4-connect-completed", driveTour: { tourModel in
                skip(tourModel, to: .connectApps)
                tourModel.openConnectors()
                tourModel.connectedAppsChanged(names: ["Gmail"])
            }),

            Scenario(name: "5-edge-waiting", driveTour: { skip($0, to: .placeBar) }, driveBar: { $0.pinHoverForPreview(true) }),
            Scenario(name: "5-edge-idle-hint", driveTour: { tourModel in
                tourModel.idleHintDelay = 0
                skip(tourModel, to: .placeBar)
            }),
            Scenario(name: "5-edge-completed", barEdge: .left, driveTour: { tourModel in
                skip(tourModel, to: .placeBar)
                tourModel.dockEdgeChanged(to: .left)
            }),

            Scenario(name: "6-finished", driveTour: { tourModel in
                skip(tourModel, to: .placeBar)
                tourModel.skipCurrentLesson()
            }),
        ]
    }
}
