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
    case microphone, accessibility, screenRecording, speechRecognition
    public var id: String { rawValue }

    /// Speech Recognition is optional: without it, recordings are transcribed by publik instead of on this Mac.
    public var isRequired: Bool { self != .speechRecognition }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .speechRecognition: return "Speech Recognition"
        }
    }

    /// Why Ambient needs it, in one plain line.
    var reason: String {
        switch self {
        case .microphone: return "To hear you while you hold the keys. Never otherwise."
        case .accessibility: return "To notice the shortcut in any app and point at things."
        case .screenRecording: return "To see your screen when you ask about it."
        case .speechRecognition: return "To turn what you say into text on this Mac."
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .speechRecognition: return "waveform"
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

    /// Every permission Ambient cannot work without. Speech Recognition is optional and does not count.
    public var areRequiredPermissionsGranted: Bool {
        AmbientPermissionKind.allCases.filter(\.isRequired).allSatisfy { status(of: $0) == .granted }
    }

    /// The row whose button is the one ember action: the first required permission still missing.
    var firstMissingPermission: AmbientPermissionKind? {
        AmbientPermissionKind.allCases.first { $0.isRequired && status(of: $0) != .granted }
    }
}
