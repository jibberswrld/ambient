import AppKit
import SwiftUI

// Onboarding is always drawn dark, in the same smoked material and ember light as the bar, because it is the
// person's first look at Ambient and should already feel like it.

// MARK: - Shell

/// The frame every onboarding screen shares: the mark, a title, a line of body text, the screen's own content,
/// and a footer of buttons with the primary one last.
struct AmbientOnboardingScreenShell<Content: View, Footer: View>: View {
    var title: String
    var bodyText: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AmbientMarkView(height: 26)
                .padding(.bottom, 26)
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Text(bodyText)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 26)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 52)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The window's backdrop: warm graphite with the faint glow of the ember behind the mark.
struct AmbientOnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.070, green: 0.066, blue: 0.062)
            RadialGradient(
                colors: [AmbientDesign.Palette.ember.opacity(0.13), AmbientDesign.Palette.ember.opacity(0)],
                center: UnitPoint(x: 0.12, y: 0.0),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Gate

/// The sign-in gate. The publik sign-in module decides the words and the buttons; this draws them and reports the
/// button pressed.
struct AmbientGateScreen: View {
    var content: AmbientGateContent
    var onButtonPressed: (String) -> Void

    var body: some View {
        AmbientOnboardingScreenShell(title: content.title, bodyText: content.bodyText) {
            if let note = content.note {
                HStack(spacing: 8) {
                    if content.isWaiting {
                        AmbientEmberIndicator(activity: .thinking, diameter: 12)
                    }
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        } footer: {
            ForEach(content.buttons) { gateButton in
                let button = AmbientCapsuleButton(title: gateButton.label, prominence: capsuleProminence(gateButton.prominence)) {
                    onButtonPressed(gateButton.actionID)
                }
                if gateButton.prominence == .primary {
                    button.keyboardShortcut(.defaultAction)
                } else {
                    button
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: content)
    }

    private func capsuleProminence(_ prominence: AmbientGateButton.Prominence) -> AmbientCapsuleButton.Prominence {
        switch prominence {
        case .primary: return .primary
        case .secondary: return .secondary
        case .quiet: return .quiet
        }
    }
}

// MARK: - Permissions

struct AmbientPermissionsScreen: View {
    var model: AmbientPermissionsModel

    var body: some View {
        AmbientOnboardingScreenShell(
            title: "Three things Ambient needs",
            bodyText: "Each one is used only when you ask for something. You can change them any time in System Settings."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(AmbientPermissionKind.allCases.enumerated()), id: \.element) { rowIndex, kind in
                    if rowIndex > 0 {
                        Rectangle().fill(AmbientDesign.Palette.onSmokeHairline).frame(height: 1).padding(.leading, 58)
                    }
                    AmbientPermissionRow(kind: kind, status: model.status(of: kind), isTheNextStep: model.firstMissingPermission == kind) {
                        model.onGrant?(kind)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))
        } footer: {
            if model.areAllGranted {
                AmbientCapsuleButton(title: "Continue", prominence: .primary) { model.onContinue?() }
                    .keyboardShortcut(.defaultAction)
            } else {
                AmbientCapsuleButton(title: "Not now", prominence: .quiet) { model.onContinue?() }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.statuses)
    }
}

struct AmbientPermissionRow: View {
    var kind: AmbientPermissionKind
    var status: AmbientPermissionStatus
    /// The first missing permission carries the screen's one ember button.
    var isTheNextStep: Bool
    var onGrant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                Text(kind.reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            statusControl
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusControl: some View {
        switch status {
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold))
                Text("Allowed").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        case .waiting:
            HStack(spacing: 7) {
                AmbientRunningArc(diameter: 11)
                Text("Waiting").font(.system(size: 12.5, weight: .medium)).foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
            }
        case .notYetAsked:
            AmbientCapsuleButton(title: "Allow", prominence: isTheNextStep ? .primary : .secondary, isCompact: true, action: onGrant)
        case .deniedInSystemSettings:
            AmbientCapsuleButton(title: "Open Settings", systemImageName: "arrow.up.right", prominence: isTheNextStep ? .primary : .secondary, isCompact: true, action: onGrant)
        }
    }
}

// MARK: - First run

struct AmbientFirstRunScreen: View {
    var model: AmbientFirstRunModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch model.step {
            case .gesture:
                AmbientFirstRunGestureStep(model: model)
                    .transition(stepTransition(movingForward: false))
            case .edge:
                AmbientFirstRunEdgeStep(model: model)
                    .transition(stepTransition(movingForward: true))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 1.0), value: model.step)
    }

    /// Forward slides the next step in from the right; back reverses the same path.
    private func stepTransition(movingForward: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        let travel: CGFloat = 36
        return .asymmetric(
            insertion: .offset(x: movingForward ? travel : -travel).combined(with: .opacity),
            removal: .offset(x: movingForward ? travel : -travel).combined(with: .opacity)
        )
    }
}

struct AmbientFirstRunGestureStep: View {
    var model: AmbientFirstRunModel

    var body: some View {
        AmbientOnboardingScreenShell(
            title: "Hold \(model.shortcut.spokenName.replacingOccurrences(of: " + ", with: " and ")), then talk.",
            bodyText: model.hasCompletedGesture
                ? "That is all there is to it. Ambient answers in the bar and keeps working in the background."
                : "Let go when you are done and Ambient gets to work. Try it now."
        ) {
            AmbientGesturePracticeStage(model: model)
        } footer: {
            if model.hasCompletedGesture {
                AmbientCapsuleButton(title: "Continue", prominence: .primary) { model.advanceToEdgeStep() }
                    .keyboardShortcut(.defaultAction)
            } else {
                AmbientCapsuleButton(title: "Skip", prominence: .quiet) { model.advanceToEdgeStep() }
            }
        }
    }
}

/// A miniature desktop with the two keycaps and the real flow bar, which answers the person's practice hold.
struct AmbientGesturePracticeStage: View {
    var model: AmbientFirstRunModel
    @State private var practiceBarModel = FlowBarModel()
    @State private var practiceReplyTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let stageHeight: CGFloat = 190

    var body: some View {
        ZStack(alignment: .top) {
            stageBackground
            HStack(spacing: 8) {
                ForEach(model.shortcut.keycapSymbolNames, id: \.self) { symbolName in
                    AmbientKeycap(systemImageName: symbolName, label: keycapLabel(for: symbolName), size: 40, isPressed: model.isShortcutHeld)
                }
            }
            .padding(.top, 30)
            .animation(.easeOut(duration: 0.1), value: model.isShortcutHeld)
            GeometryReader { geometry in
                FlowBarRootView(model: practiceBarModel)
                    .onAppear { placePracticeBar(in: geometry.size) }
                    .onChange(of: geometry.size) { _, newSize in placePracticeBar(in: newSize) }
            }
        }
        .frame(height: Self.stageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))
        .onChange(of: model.isShortcutHeld) { _, isHeld in practiceHoldChanged(isHeld: isHeld) }
        .task(id: model.isShortcutHeld) { await feedPracticeAudioLevelWhileHeld() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.isShortcutHeld ? "Listening" : "Practice area. Hold the keys to try.")
    }

    private var stageBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.15, blue: 0.20), Color(red: 0.09, green: 0.085, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.42, green: 0.30, blue: 0.55).opacity(0.35), .clear], center: UnitPoint(x: 0.8, y: 1.0), startRadius: 0, endRadius: 260)
        }
    }

    private func keycapLabel(for symbolName: String) -> String {
        switch symbolName {
        case "control": return "control"
        case "option": return "option"
        case "command": return "command"
        default: return ""
        }
    }

    private func placePracticeBar(in stageSize: CGSize) {
        practiceBarModel.dockEdge = .bottom
        practiceBarModel.barAnchorInPanel = CGPoint(x: stageSize.width / 2, y: stageSize.height - 12)
    }

    private func practiceHoldChanged(isHeld: Bool) {
        practiceReplyTask?.cancel()
        if isHeld {
            practiceBarModel.beginListening()
            return
        }
        practiceBarModel.beginTranscribing()
        // A real reply would come from the agent; here the bar answers with a short, true line about itself.
        practiceReplyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            practiceBarModel.beginThinking()
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            practiceBarModel.finishedReplyLingerDuration = 0
            practiceBarModel.apply(.textDelta("Got it. Hold the keys whenever you need me."))
            practiceBarModel.apply(.finished(finalText: "Got it. Hold the keys whenever you need me."))
        }
    }

    /// While held, pushes the app's real level when it supplies one, or a soft speech-like motion when it does not.
    private func feedPracticeAudioLevelWhileHeld() async {
        guard model.isShortcutHeld else { return }
        let holdStart = Date()
        while !Task.isCancelled && model.isShortcutHeld {
            if let suppliedLevel = model.audioLevel {
                practiceBarModel.updateAudioLevel(suppliedLevel)
            } else if !reduceMotion {
                let elapsedSeconds = Date().timeIntervalSince(holdStart)
                let syllable = max(0, sin(elapsedSeconds * 2 * .pi * 3.6))
                practiceBarModel.updateAudioLevel(0.12 + 0.5 * syllable * (0.6 + 0.4 * sin(elapsedSeconds * 1.7)))
            } else {
                practiceBarModel.updateAudioLevel(0.35)
            }
            try? await Task.sleep(nanoseconds: 22_000_000)
        }
    }
}

struct AmbientFirstRunEdgeStep: View {
    @Bindable var model: AmbientFirstRunModel

    var body: some View {
        AmbientOnboardingScreenShell(
            title: "Where should Ambient live?",
            bodyText: "Pick an edge of your screen. You can drag the bar to any edge later."
        ) {
            HStack(alignment: .center, spacing: 28) {
                AmbientEdgePicker(selectedEdge: $model.chosenEdge)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FlowBarDockEdge.allCases, id: \.self) { edge in
                        AmbientEdgeChoiceRow(edge: edge, isSelected: edge == model.chosenEdge) { model.chosenEdge = edge }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            AmbientCapsuleButton(title: "Back", prominence: .quiet) { model.returnToGestureStep() }
            AmbientCapsuleButton(title: "Start using Ambient", prominence: .primary) { model.finish() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A named edge beside the picture, so the choice can also be made by name (and by VoiceOver).
private struct AmbientEdgeChoiceRow: View {
    var edge: FlowBarDockEdge
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(isSelected ? AmbientDesign.Palette.ember : Color.clear)
                    .overlay(Circle().strokeBorder(isSelected ? Color.clear : AmbientDesign.Palette.onSmokeTertiary, lineWidth: 1.25))
                    .frame(width: 9, height: 9)
                Text(edge.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AmbientDesign.Palette.onSmokePrimary : AmbientDesign.Palette.onSmokeSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 128, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? AmbientDesign.Palette.onSmokeFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.98))
        .onHover { hovering in withAnimation(AmbientDesign.Motion.hoverFeedback) { isHovering = hovering } }
        .ambientPointingHandCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
