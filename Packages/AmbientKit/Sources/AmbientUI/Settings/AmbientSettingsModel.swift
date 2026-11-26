import AmbientContracts
import AppKit
import Foundation
import Observation

/// The two-key shortcut held to talk.
public enum AmbientPushToTalkShortcut: String, Codable, CaseIterable, Sendable {
    case controlOption
    case optionCommand
    case controlCommand

    /// SF Symbol names for the keycaps, in the order they are pressed.
    public var keycapSymbolNames: [String] {
        switch self {
        case .controlOption: return ["control", "option"]
        case .optionCommand: return ["option", "command"]
        case .controlCommand: return ["control", "command"]
        }
    }

    public var spokenName: String {
        switch self {
        case .controlOption: return "Control + Option"
        case .optionCommand: return "Option + Command"
        case .controlCommand: return "Control + Command"
        }
    }
}

/// Everything on the General page. The app owns the truth; settings edits a copy and reports each change.
public struct AmbientGeneralSettings: Equatable, Sendable {
    public var pushToTalkShortcut: AmbientPushToTalkShortcut
    public var dockEdge: FlowBarDockEdge
    public var speaksReplies: Bool
    public var runsCommandsWithoutAsking: Bool
    public var launchesAtLogin: Bool
    public var sharesAnonymousUsageStats: Bool

    public init(pushToTalkShortcut: AmbientPushToTalkShortcut = .controlOption, dockEdge: FlowBarDockEdge = .bottom, speaksReplies: Bool = true, runsCommandsWithoutAsking: Bool = false, launchesAtLogin: Bool = false, sharesAnonymousUsageStats: Bool = true) {
        self.pushToTalkShortcut = pushToTalkShortcut
        self.dockEdge = dockEdge
        self.speaksReplies = speaksReplies
        self.runsCommandsWithoutAsking = runsCommandsWithoutAsking
        self.launchesAtLogin = launchesAtLogin
        self.sharesAnonymousUsageStats = sharesAnonymousUsageStats
    }
}

/// The publik account, as the Account page shows it. Usage is a percentage only, never money.
public struct AmbientAccountSummary: Equatable, Sendable {
    public var publikHandle: String?
    public var planName: String?
    /// 0 to 1. Nil while unknown.
    public var usageRemainingFraction: Double?
    /// When the allowance refills, if known.
    public var usageResetsOn: Date?
    public var manageAccountURL: URL

    public init(publikHandle: String?, planName: String?, usageRemainingFraction: Double?, usageResetsOn: Date? = nil, manageAccountURL: URL) {
        self.publikHandle = publikHandle
        self.planName = planName
        self.usageRemainingFraction = usageRemainingFraction
        self.usageResetsOn = usageResetsOn
        self.manageAccountURL = manageAccountURL
    }
}

public enum AmbientSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, connectors, memory, skills, activity, account
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .connectors: return "Connectors"
        case .memory: return "Memory"
        case .skills: return "Skills"
        case .activity: return "Activity"
        case .account: return "Account"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .connectors: return "point.3.connected.trianglepath.dotted"
        case .memory: return "brain.head.profile"
        case .skills: return "puzzlepiece.extension"
        case .activity: return "clock.arrow.circlepath"
        case .account: return "person.crop.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How you talk to Ambient and where it lives."
        case .connectors: return "Apps Ambient can use for you."
        case .memory: return "What Ambient knows about you. Delete anything."
        case .skills: return "Instructions Ambient can load when a task calls for them."
        case .activity: return "Agents and commands that ran in the background."
        case .account: return "Your publik account and plan."
        }
    }
}

/// State for the settings window that is not owned by one of the stores.
@MainActor
@Observable
public final class AmbientSettingsModel {
    public var generalSettings: AmbientGeneralSettings {
        didSet { if generalSettings != oldValue { onGeneralSettingsChanged?(generalSettings) } }
    }
    public var account: AmbientAccountSummary?
    public var selectedBackgroundTaskID: UUID?
    public var selectedSection: AmbientSettingsSection = .general
    /// The version of the running app, for the Updates row.
    public var appVersion: String?
    /// The newer version the updater has found, or nil when this is the latest.
    public var availableUpdateVersion: String?
    /// Asks the updater to check now. When an update is already known, this is what installs it.
    public var onCheckForUpdates: (() -> Void)?

    /// Called after every change on the General page.
    public var onGeneralSettingsChanged: ((AmbientGeneralSettings) -> Void)?
    /// Opens a URL (manage account, connector authorisation). Defaults to the browser.
    public var onOpenURL: (URL) -> Void = { url in NSWorkspace.shared.open(url) }

    public init(generalSettings: AmbientGeneralSettings = AmbientGeneralSettings(), account: AmbientAccountSummary? = nil) {
        self.generalSettings = generalSettings
        self.account = account
    }
}
