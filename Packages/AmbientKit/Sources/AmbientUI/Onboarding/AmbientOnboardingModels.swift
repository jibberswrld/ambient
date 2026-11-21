import AppKit
import Foundation
import Observation

// MARK: - Sign-in gate

/// One button on the gate screen. `actionID` is what `present` returns when it is pressed.
public struct AmbientGateButton: Identifiable, Equatable, Sendable {
    public enum Prominence: Equatable, Sendable { case primary, secondary, quiet }
    public var id: String { actionID }
    public var actionID: String
    public var label: String
    public var prominence: Prominence

    public init(actionID: String, label: String, prominence: Prominence = .secondary) {
        self.actionID = actionID
        self.label = label
        self.prominence = prominence
    }
}

/// What the gate screen says. The publik sign-in module decides all of it; the gate only draws it.
public struct AmbientGateContent: Equatable, Sendable {
    public var title: String
    public var bodyText: String
    /// A small line under the body, such as "Waiting for you to finish in the browser."
    public var note: String?
    /// Shows the breathing ember beside the note while something happens elsewhere (the browser sign-in).
    public var isWaiting: Bool
    public var buttons: [AmbientGateButton]

    public init(title: String, bodyText: String, note: String? = nil, isWaiting: Bool = false, buttons: [AmbientGateButton]) {
        self.title = title
        self.bodyText = bodyText
        self.note = note
        self.isWaiting = isWaiting
        self.buttons = buttons
    }
}

// MARK: - Permissions

public enum AmbientPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case microphone, accessibility, screenRecording
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// Why Ambient needs it, in one plain line.
    var reason: String {
        switch self {
        case .microphone: return "To hear you while you hold the keys. Never otherwise."
        case .accessibility: return "To notice the shortcut in any app and point at things."
        case .screenRecording: return "To see your screen when you ask about it."
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }
}

public enum AmbientPermissionStatus: Equatable, Sendable {
    case granted
    case notYetAsked
    /// Turned off, or asked before: only System Settings can change it now.
    case deniedInSystemSettings
    /// Waiting for the person to answer the system prompt, or for System Settings to report back.
    case waiting
}

/// The permissions step. The app supplies each status and does the granting; this only draws and reports.
@MainActor
@Observable
public final class AmbientPermissionsModel {
    public var statuses: [AmbientPermissionKind: AmbientPermissionStatus]
    /// The person pressed Allow (or Open Settings) on a row. The app asks the system and updates `statuses`.
    public var onGrant: ((AmbientPermissionKind) -> Void)?
    /// The person pressed Continue or Not now.
    public var onContinue: (() -> Void)?

    public init(statuses: [AmbientPermissionKind: AmbientPermissionStatus] = [:]) {
        self.statuses = statuses
    }

    public func status(of kind: AmbientPermissionKind) -> AmbientPermissionStatus {
        statuses[kind] ?? .notYetAsked
    }

    public var areAllGranted: Bool {
        AmbientPermissionKind.allCases.allSatisfy { status(of: $0) == .granted }
    }

    /// The row whose button is the one ember action: the first permission still missing.
    var firstMissingPermission: AmbientPermissionKind? {
        AmbientPermissionKind.allCases.first { status(of: $0) != .granted }
    }
}

// MARK: - First run

/// The first-run moment: learn the one gesture, then choose the edge.
@MainActor
@Observable
public final class AmbientFirstRunModel {
    public enum Step: Equatable, Sendable { case gesture, edge }

    public var shortcut: AmbientPushToTalkShortcut
    public var chosenEdge: FlowBarDockEdge {
        didSet { if chosenEdge != oldValue { onDockEdgeChosen?(chosenEdge) } }
    }
    /// True while both keys are down. The onboarding window watches the keys itself while it is focused; the app
    /// may also set this from its global shortcut monitor.
    public var isShortcutHeld = false {
        didSet {
            guard isShortcutHeld != oldValue else { return }
            if isShortcutHeld {
                shortcutHeldSince = Date()
            } else if let shortcutHeldSince, Date().timeIntervalSince(shortcutHeldSince) > 0.35 {
                // A real hold and release: the person has done the gesture once.
                hasCompletedGesture = true
            }
            if !isShortcutHeld { shortcutHeldSince = nil }
        }
    }
    /// The live microphone level while the keys are held, 0 to 1. When the app does not supply it, the practice
    /// waveform shows a gentle idle motion instead.
    public var audioLevel: Double?
    public private(set) var hasCompletedGesture = false
    public internal(set) var step: Step = .gesture

    public var onDockEdgeChosen: ((FlowBarDockEdge) -> Void)?
    /// The person finished the first run.
    public var onFinish: (() -> Void)?

    private var shortcutHeldSince: Date?

    public init(shortcut: AmbientPushToTalkShortcut = .controlOption, chosenEdge: FlowBarDockEdge = .bottom) {
        self.shortcut = shortcut
        self.chosenEdge = chosenEdge
    }

    func advanceToEdgeStep() { step = .edge }
    func returnToGestureStep() { step = .gesture }
    func finish() { onFinish?() }

    /// Whether a set of pressed modifier keys is exactly the push-to-talk shortcut.
    static func modifierFlags(_ pressedFlags: NSEvent.ModifierFlags, match shortcut: AmbientPushToTalkShortcut) -> Bool {
        let relevantFlags = pressedFlags.intersection([.control, .option, .command, .shift])
        switch shortcut {
        case .controlOption: return relevantFlags == [.control, .option]
        case .optionCommand: return relevantFlags == [.option, .command]
        case .controlCommand: return relevantFlags == [.control, .command]
        }
    }
}
