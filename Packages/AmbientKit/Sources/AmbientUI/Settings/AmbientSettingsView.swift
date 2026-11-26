import AmbientContracts
import AppKit
import SwiftUI

/// The services the settings pages read and write. Passed in as the contract protocols.
public struct AmbientSettingsServices {
    public var connectorService: any ConnectorService
    public var memoryStore: any MemoryStore
    public var skillStore: any SkillStore
    public var backgroundTaskStore: any BackgroundTaskStore

    public init(connectorService: any ConnectorService, memoryStore: any MemoryStore, skillStore: any SkillStore, backgroundTaskStore: any BackgroundTaskStore) {
        self.connectorService = connectorService
        self.memoryStore = memoryStore
        self.skillStore = skillStore
        self.backgroundTaskStore = backgroundTaskStore
    }
}

public struct AmbientSettingsView: View {
    @Bindable var model: AmbientSettingsModel
    var services: AmbientSettingsServices

    public init(model: AmbientSettingsModel, services: AmbientSettingsServices) {
        self.model = model
        self.services = services
    }

    public var body: some View {
        HStack(spacing: 0) {
            AmbientSettingsSidebar(selectedSection: $model.selectedSection, appVersion: model.appVersion,
                                   availableUpdateVersion: model.availableUpdateVersion,
                                   onCheckForUpdates: { model.onCheckForUpdates?() })
                .frame(width: 208)
            Rectangle().fill(AmbientDesign.Palette.cardHairline).frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AmbientDesign.Palette.windowBackground)
        }
        .frame(minWidth: 780, minHeight: 560)
        .ignoresSafeArea()
        .environment(\.openURL, OpenURLAction { url in
            model.onOpenURL(url)
            return .handled
        })
    }

    @ViewBuilder
    private var page: some View {
        switch model.selectedSection {
        case .general: AmbientGeneralSettingsPage(model: model)
        case .connectors: AmbientConnectorsSettingsPage(connectorService: services.connectorService, onOpenURL: model.onOpenURL)
        case .memory: AmbientMemorySettingsPage(memoryStore: services.memoryStore)
        case .skills: AmbientSkillsSettingsPage(skillStore: services.skillStore)
        case .activity: AmbientActivitySettingsPage(backgroundTaskStore: services.backgroundTaskStore, selectedTaskID: $model.selectedBackgroundTaskID)
        case .account: AmbientAccountSettingsPage(model: model)
        }
    }
}

// MARK: - Sidebar

struct AmbientSettingsSidebar: View {
    @Binding var selectedSection: AmbientSettingsSection
    var appVersion: String?
    var availableUpdateVersion: String?
    var onCheckForUpdates: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                AmbientMarkView(height: 18)
                Text("Ambient")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                if let appVersion {
                    Text(appVersion)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(AmbientDesign.Palette.tertiaryText)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 50)
            .padding(.bottom, 18)

            ForEach(AmbientSettingsSection.allCases) { section in
                AmbientSidebarRow(section: section, isSelected: section == selectedSection) {
                    selectedSection = section
                }
            }
            Spacer()
            AmbientSidebarUpdateRow(availableUpdateVersion: availableUpdateVersion, action: onCheckForUpdates)
            AmbientSidebarQuitRow()
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AmbientDesign.Palette.sidebarBackground)
    }
}

private struct AmbientSidebarRow: View {
    var section: AmbientSettingsSection
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AmbientDesign.Palette.accentText : AmbientDesign.Palette.secondaryText)
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AmbientDesign.Palette.selectedRow : (isHovering ? AmbientDesign.Palette.rowHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .ambientPointingHandCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Updates live at the foot of the sidebar so they are on every page. Normally a quiet "Check for updates";
/// while a newer version is waiting it becomes the one ember thing in the sidebar.
private struct AmbientSidebarUpdateRow: View {
    var availableUpdateVersion: String?
    var action: () -> Void
    @State private var isHovering = false

    private var isUpdateWaiting: Bool { availableUpdateVersion != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isUpdateWaiting ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(availableUpdateVersion.map { "Update to \($0)" } ?? "Check for updates")
                    .font(.system(size: 13, weight: isUpdateWaiting ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(backgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .ambientPointingHandCursor()
    }

    private var foregroundColor: Color {
        if isUpdateWaiting { return AmbientDesign.Palette.accentText }
        return isHovering ? AmbientDesign.Palette.primaryText : AmbientDesign.Palette.secondaryText
    }

    private var backgroundColor: Color {
        if isUpdateWaiting { return AmbientDesign.Palette.ember.opacity(isHovering ? 0.20 : 0.12) }
        return isHovering ? AmbientDesign.Palette.rowHover : .clear
    }
}

/// Quit sits at the foot of the sidebar on every page: the menu bar icon is easy to lose behind the notch.
private struct AmbientSidebarQuitRow: View {
    @State private var isHovering = false

    var body: some View {
        Button { NSApplication.shared.terminate(nil) } label: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text("Quit Ambient")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? AmbientDesign.Palette.primaryText : AmbientDesign.Palette.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? AmbientDesign.Palette.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .ambientPointingHandCursor()
    }
}

// MARK: - Page scaffolding

/// A settings page: a title, one line of what it is for, then its content.
struct AmbientSettingsPage<Content: View, Accessory: View>: View {
    var section: AmbientSettingsSection
    var scrolls = true
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title)
                        .font(AmbientDesign.Typeface.windowTitle)
                        .tracking(AmbientDesign.Typeface.windowTitleTracking)
                        .foregroundStyle(AmbientDesign.Palette.primaryText)
                    Text(section.subtitle)
                        .font(AmbientDesign.Typeface.body)
                        .foregroundStyle(AmbientDesign.Palette.secondaryText)
                }
                Spacer(minLength: 12)
                accessory
            }
            content
        }
        .padding(.horizontal, 36)
        .padding(.top, 46)
        .padding(.bottom, 32)
        .frame(maxWidth: 640, alignment: .leading)

        if scrolls {
            ScrollView(.vertical) { stack.frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension AmbientSettingsPage where Accessory == EmptyView {
    init(section: AmbientSettingsSection, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.section = section
        self.scrolls = scrolls
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// A rounded group of rows with hairline separators.
struct AmbientSettingsGroup<Content: View>: View {
    var label: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label)
                    .font(AmbientDesign.Typeface.sectionLabel)
                    .foregroundStyle(AmbientDesign.Palette.secondaryText)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AmbientDesign.Palette.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))
        }
    }
}

/// The hairline between two rows in a group.
struct AmbientGroupDivider: View {
    var body: some View {
        Rectangle().fill(AmbientDesign.Palette.cardHairline).frame(height: 1).padding(.leading, 14)
    }
}

/// A row: title and optional one-line explanation on the left, a control on the right.
struct AmbientSettingsRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(AmbientDesign.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
    }
}

/// A switch row. The whole row is the label for the switch.
struct AmbientSwitchRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        AmbientSettingsRow(title: title, detail: detail) {
            // The row already shows the title; the custom style would draw the label a second time, so the toggle
            // gets an empty label and carries the title for VoiceOver instead.
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(AmbientSwitchToggleStyle())
                .accessibilityLabel(title)
        }
    }
}

// MARK: - General

struct AmbientGeneralSettingsPage: View {
    @Bindable var model: AmbientSettingsModel

    var body: some View {
        AmbientSettingsPage(section: .general) {
            AmbientSettingsGroup(label: "Talking") {
                AmbientSettingsRow(title: "Hold to talk", detail: "Hold both keys, speak, then let go.") {
                    AmbientShortcutPicker(selectedShortcut: $model.generalSettings.pushToTalkShortcut)
                }
                AmbientGroupDivider()
                AmbientSwitchRow(title: "Read replies out loud", detail: nil, isOn: $model.generalSettings.speaksReplies)
            }
            AmbientSettingsGroup(label: "The bar") {
                AmbientSettingsRow(title: "Screen edge", detail: "You can also drag the bar to any edge.") {
                    AmbientEdgePicker(selectedEdge: $model.generalSettings.dockEdge, isCompact: true)
                }
            }
            AmbientSettingsGroup(label: "Permissions") {
                AmbientSwitchRow(
                    title: "Run commands without asking",
                    detail: model.generalSettings.runsCommandsWithoutAsking
                        ? "Ambient runs commands on this Mac straight away."
                        : "Ambient shows you each command and waits for you to allow it.",
                    isOn: $model.generalSettings.runsCommandsWithoutAsking
                )
                AmbientGroupDivider()
                AmbientSwitchRow(title: "Open at login", detail: nil, isOn: $model.generalSettings.launchesAtLogin)
            }
            AmbientSettingsGroup(label: "Privacy") {
                AmbientSwitchRow(title: "Share anonymous usage stats",
                    detail: "Helps improve setup. Sends steps and command outcomes to PostHog, never your requests or account.",
                    isOn: $model.generalSettings.sharesAnonymousUsageStats)
            }
        }
    }
}

/// Three shortcut choices, each shown as its keycaps.
struct AmbientShortcutPicker: View {
    @Binding var selectedShortcut: AmbientPushToTalkShortcut

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AmbientPushToTalkShortcut.allCases, id: \.self) { shortcut in
                let isSelected = shortcut == selectedShortcut
                Button { selectedShortcut = shortcut } label: {
                    HStack(spacing: 3) {
                        ForEach(shortcut.keycapSymbolNames, id: \.self) { symbolName in
                            AmbientKeycap(systemImageName: symbolName, size: 20, isOnSmokedGlass: false)
                        }
                    }
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? AmbientDesign.Palette.ember.opacity(0.16) : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isSelected ? AmbientDesign.Palette.ember.opacity(0.9) : AmbientDesign.Palette.cardHairline, lineWidth: isSelected ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(AmbientPressScaleButtonStyle())
                .ambientPointingHandCursor()
                .help(shortcut.spokenName)
                .accessibilityLabel(shortcut.spokenName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A small picture of a screen; click an edge to put the bar there.
struct AmbientEdgePicker: View {
    @Binding var selectedEdge: FlowBarDockEdge
    var isCompact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let screenSize = isCompact ? CGSize(width: 132, height: 84) : CGSize(width: 300, height: 188)
        ZStack {
            RoundedRectangle(cornerRadius: isCompact ? 8 : 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.33, green: 0.27, blue: 0.24), Color(red: 0.13, green: 0.12, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
            // The menu bar, so top reads as top.
            VStack {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: isCompact ? 5 : 10)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? 8 : 14, style: .continuous))

            ForEach(FlowBarDockEdge.allCases, id: \.self) { edge in
                edgeTarget(edge, screenSize: screenSize)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.82), value: selectedEdge)
    }

    private func edgeTarget(_ edge: FlowBarDockEdge, screenSize: CGSize) -> some View {
        let isSelected = edge == selectedEdge
        let barLength: CGFloat = isCompact ? (isSelected ? 30 : 18) : (isSelected ? 64 : 34)
        let barThickness: CGFloat = isCompact ? (isSelected ? 6 : 4) : (isSelected ? 12 : 6)
        let inset: CGFloat = isCompact ? 7 : 13
        let menuBarHeight: CGFloat = isCompact ? 5 : 10
        let size = edge.isVertical ? CGSize(width: barThickness, height: barLength) : CGSize(width: barLength, height: barThickness)
        let position: CGPoint
        switch edge {
        case .bottom: position = CGPoint(x: screenSize.width / 2, y: screenSize.height - inset)
        case .top: position = CGPoint(x: screenSize.width / 2, y: menuBarHeight + inset)
        case .left: position = CGPoint(x: inset, y: (screenSize.height + menuBarHeight) / 2)
        case .right: position = CGPoint(x: screenSize.width - inset, y: (screenSize.height + menuBarHeight) / 2)
        }
        return Button { selectedEdge = edge } label: {
            Capsule(style: .continuous)
                .fill(isSelected ? AmbientDesign.Palette.ember : Color.white.opacity(0.30))
                .frame(width: size.width, height: size.height)
                .shadow(color: isSelected ? AmbientDesign.Palette.ember.opacity(0.7) : .clear, radius: isCompact ? 4 : 8)
                // A generous hit area: the target is much bigger than the drawn bar.
                .frame(width: edge.isVertical ? (isCompact ? 22 : 40) : (isCompact ? 56 : 120), height: edge.isVertical ? (isCompact ? 50 : 100) : (isCompact ? 20 : 34))
                .contentShape(Rectangle())
        }
        .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.92))
        .ambientPointingHandCursor()
        .position(position)
        .accessibilityLabel("\(edge.displayName) edge")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Account

struct AmbientAccountSettingsPage: View {
    var model: AmbientSettingsModel

    var body: some View {
        AmbientSettingsPage(section: .account) {
            if let account = model.account {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        Text(account.publikHandle.map { String($0.prefix(1)).uppercased() } ?? "P")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AmbientDesign.Palette.emberInk)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(LinearGradient(colors: [AmbientDesign.Palette.emberCore, AmbientDesign.Palette.ember], startPoint: .top, endPoint: .bottom)))
                        VStack(alignment: .leading, spacing: 3) {
                            if let handle = account.publikHandle {
                                Text("@\(handle)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                            }
                            if let planName = account.planName {
                                Text("\(planName) plan")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(AmbientDesign.Palette.secondaryText)
                            }
                        }
                        Spacer()
                        AmbientCapsuleButton(title: "Manage", systemImageName: "arrow.up.right", prominence: .secondary, surface: .window) {
                            model.onOpenURL(account.manageAccountURL)
                        }
                    }
                    .padding(18)
                    if account.usageRemainingFraction != nil {
                        Rectangle().fill(AmbientDesign.Palette.cardHairline).frame(height: 1)
                        AmbientUsageMeter(remainingFraction: account.usageRemainingFraction, resetsOn: account.usageResetsOn)
                            .padding(18)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AmbientDesign.Palette.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))
            } else {
                AmbientEmptyState(symbolName: "person.crop.circle.badge.questionmark", title: "Account details", message: "Your account details have not loaded yet. Open Settings again to retry.")
            }
        }
    }
}

/// Usage as a percentage remaining. Never shows money.
struct AmbientUsageMeter: View {
    var remainingFraction: Double?
    var resetsOn: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(remainingFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Checking")
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .tracking(-0.6)
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                Text("remaining")
                    .font(.system(size: 13))
                    .foregroundStyle(AmbientDesign.Palette.secondaryText)
                Spacer()
                if let resetsOn {
                    Text("Refills \(resetsOn.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.system(size: 12))
                        .foregroundStyle(AmbientDesign.Palette.tertiaryText)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(AmbientDesign.Palette.quietFill)
                    Capsule(style: .continuous)
                        .fill(meterColor)
                        .frame(width: max(6, geometry.size.width * CGFloat(remainingFraction ?? 0)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    /// Ember while there is plenty, red when it is nearly gone.
    private var meterColor: Color {
        guard let remainingFraction else { return AmbientDesign.Palette.quietFill }
        return remainingFraction < 0.1 ? AmbientDesign.Palette.alert : AmbientDesign.Palette.ember
    }
}

/// A centred message for empty lists, errors and signed-out states.
struct AmbientEmptyState<Action: View>: View {
    var symbolName: String
    var title: String
    var message: String
    var isError = false
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isError ? AmbientDesign.Palette.alertDeep : AmbientDesign.Palette.tertiaryText)
                .frame(width: 48, height: 48)
                .background(Circle().fill(AmbientDesign.Palette.quietFill))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AmbientDesign.Palette.primaryText)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(AmbientDesign.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

extension AmbientEmptyState where Action == EmptyView {
    init(symbolName: String, title: String, message: String, isError: Bool = false) {
        self.init(symbolName: symbolName, title: title, message: message, isError: isError) { EmptyView() }
    }
}
