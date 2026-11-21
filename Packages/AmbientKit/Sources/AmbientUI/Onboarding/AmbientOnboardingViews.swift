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
            VStack(alignment: .leading, spacing: 16) {
                AmbientGateHeroStage()
                gateNote
            }
        } footer: {
            gateButtons
        }
        .animation(.easeOut(duration: 0.2), value: content)
    }

    @ViewBuilder
    private var gateNote: some View {
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
    }

    @ViewBuilder
    private var gateButtons: some View {
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

    private func capsuleProminence(_ prominence: AmbientGateButton.Prominence) -> AmbientCapsuleButton.Prominence {
        switch prominence {
        case .primary: return .primary
        case .secondary: return .secondary
        case .quiet: return .quiet
        }
    }
}

/// The gate's picture: a miniature desktop with the real bar resting on it, showing what the person is
/// signing in to before they have it.
struct AmbientGateHeroStage: View {
    @State private var heroBarModel = FlowBarModel()

    var body: some View {
        GeometryReader { geometry in
            FlowBarRootView(model: heroBarModel)
                .onAppear { placeHeroBar(in: geometry.size) }
                .onChange(of: geometry.size) { _, newSize in placeHeroBar(in: newSize) }
        }
        .frame(height: 150)
        .background(AmbientOnboardingStageBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func placeHeroBar(in stageSize: CGSize) {
        heroBarModel.dockEdge = .bottom
        heroBarModel.barAnchorInPanel = CGPoint(x: stageSize.width / 2, y: stageSize.height - 14)
        heroBarModel.pinHoverForPreview(true)
    }
}

/// The miniature desktop behind the onboarding pictures: a dusk wallpaper, so the smoked glass has colour to sit on.
struct AmbientOnboardingStageBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.15, blue: 0.20), Color(red: 0.09, green: 0.085, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.42, green: 0.30, blue: 0.55).opacity(0.35), .clear], center: UnitPoint(x: 0.8, y: 1.0), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [AmbientDesign.Palette.ember.opacity(0.10), .clear], center: UnitPoint(x: 0.15, y: 0.0), startRadius: 0, endRadius: 200)
        }
    }
}

// MARK: - Permissions

struct AmbientPermissionsScreen: View {
    var model: AmbientPermissionsModel

    var body: some View {
        AmbientOnboardingScreenShell(
            title: "What Ambient needs",
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
            if model.areRequiredPermissionsGranted {
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
                HStack(spacing: 7) {
                    Text(kind.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                    if !kind.isRequired {
                        Text("Optional")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule(style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))
                    }
                }
                Text(kind.reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            statusControl
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
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
