import AppKit
import SwiftUI

// Small controls shared by the flow bar, settings and onboarding. Every one shows the pointing-hand cursor on
// hover and gives press feedback on mouse-down, because the interface should feel like it heard the click.

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view.
    func ambientPointingHandCursor() -> some View {
        // set() rather than push()/pop(): a view that disappears while hovered would otherwise leave the
        // cursor stack unbalanced and the hand stuck on screen.
        onHover { isHovering in
            if isHovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

/// Scales slightly on press. The scale is small so it reads as a physical press, not an effect.
struct AmbientPressScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(AmbientDesign.Motion.pressFeedback, value: configuration.isPressed)
    }
}

/// A round icon button for use on smoked glass.
struct AmbientGlassIconButton: View {
    var systemImageName: String
    var accessibilityLabelText: String
    var diameter: CGFloat = 26
    var symbolPointSize: CGFloat = 12
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: symbolPointSize, weight: .semibold))
                .foregroundStyle(isHovering ? AmbientDesign.Palette.onSmokePrimary : AmbientDesign.Palette.onSmokeSecondary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(isHovering ? AmbientDesign.Palette.onSmokeFillHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.9))
        .onHover { hovering in withAnimation(AmbientDesign.Motion.hoverFeedback) { isHovering = hovering } }
        .ambientPointingHandCursor()
        .help(accessibilityLabelText)
        .accessibilityLabel(accessibilityLabelText)
    }
}

/// A capsule text button. `.primary` is the ember action; there is at most one per surface.
struct AmbientCapsuleButton: View {
    enum Prominence { case primary, secondary, quiet }
    /// Smoked glass surfaces are always dark; window surfaces follow the system appearance.
    enum Surface { case smokedGlass, window }

    var title: String
    var systemImageName: String?
    var prominence: Prominence = .secondary
    var surface: Surface = .smokedGlass
    var isCompact = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImageName {
                    Image(systemName: systemImageName).font(.system(size: isCompact ? 10.5 : 11.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: isCompact ? 12 : 13, weight: prominence == .primary ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isCompact ? 10 : 14)
            .frame(height: isCompact ? 26 : 30)
            .background(Capsule(style: .continuous).fill(backgroundColor))
            .overlay {
                if prominence == .secondary && surface == .window {
                    Capsule(style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.97))
        .onHover { hovering in withAnimation(AmbientDesign.Motion.hoverFeedback) { isHovering = hovering } }
        .ambientPointingHandCursor()
    }

    private var foregroundColor: Color {
        switch (prominence, surface) {
        case (.primary, _): return AmbientDesign.Palette.emberInk
        case (.secondary, .smokedGlass): return AmbientDesign.Palette.onSmokePrimary
        case (.quiet, .smokedGlass): return isHovering ? AmbientDesign.Palette.onSmokePrimary : AmbientDesign.Palette.onSmokeSecondary
        case (.secondary, .window): return AmbientDesign.Palette.primaryText
        case (.quiet, .window): return isHovering ? AmbientDesign.Palette.primaryText : AmbientDesign.Palette.secondaryText
        }
    }

    private var backgroundColor: Color {
        switch (prominence, surface) {
        case (.primary, _):
            return isHovering ? AmbientDesign.Palette.ember.opacity(0.88) : AmbientDesign.Palette.ember
        case (.secondary, .smokedGlass):
            return isHovering ? AmbientDesign.Palette.onSmokeFillPressed : AmbientDesign.Palette.onSmokeFillHover
        case (.quiet, .smokedGlass):
            return isHovering ? AmbientDesign.Palette.onSmokeFill : .clear
        case (.secondary, .window):
            return isHovering ? AmbientDesign.Palette.selectedRow : AmbientDesign.Palette.cardBackground
        case (.quiet, .window):
            return isHovering ? AmbientDesign.Palette.rowHover : .clear
        }
    }
}

/// A keycap for a modifier key, used wherever Ambient teaches its shortcut.
struct AmbientKeycap: View {
    var systemImageName: String
    var label: String?
    var size: CGFloat = 20
    var isPressed = false
    /// Keycaps on smoked glass are light-on-dark; on a window they follow the appearance.
    var isOnSmokedGlass = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImageName)
                .font(.system(size: size * 0.5, weight: .semibold))
            if let label {
                Text(label).font(.system(size: size * 0.46, weight: .medium))
            }
        }
        .foregroundStyle(isPressed ? AmbientDesign.Palette.emberInk : (isOnSmokedGlass ? AmbientDesign.Palette.onSmokePrimary : AmbientDesign.Palette.primaryText))
        .padding(.horizontal, label == nil ? 0 : size * 0.3)
        .frame(minWidth: size, minHeight: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(isPressed ? AmbientDesign.Palette.ember : (isOnSmokedGlass ? Color.white.opacity(0.11) : AmbientDesign.Palette.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(isOnSmokedGlass ? Color.white.opacity(0.16) : AmbientDesign.Palette.cardHairline, lineWidth: 0.75)
        )
        // The keycap's lower lip: a key is a physical object with depth.
        .shadow(color: .black.opacity(isOnSmokedGlass ? 0.35 : 0.10), radius: 0, y: isPressed ? 0 : 1)
        .offset(y: isPressed ? 1 : 0)
    }
}

/// A switch in Ambient's own style. The track turns ember when on.
struct AmbientSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            AmbientSwitchTrack(isOn: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
                .ambientPointingHandCursor()
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

private struct AmbientSwitchTrack: View {
    var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? AmbientDesign.Palette.ember : AmbientDesign.Palette.quietFill)
                .overlay(Capsule(style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: isOn ? 0 : 1))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                .padding(2)
        }
        .frame(width: 34, height: 20)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.85), value: isOn)
    }
}

/// The Ambient mark: an ember inside a smoked capsule. Used at the top of onboarding and the settings sidebar.
struct AmbientMarkView: View {
    var height: CGFloat = 28

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
            Circle()
                .fill(RadialGradient(colors: [AmbientDesign.Palette.emberCore, AmbientDesign.Palette.ember], center: .center, startRadius: 0, endRadius: height * 0.2))
                .frame(width: height * 0.32, height: height * 0.32)
                .shadow(color: AmbientDesign.Palette.ember.opacity(0.9), radius: height * 0.18)
        }
        .frame(width: height * 1.75, height: height)
        .accessibilityHidden(true)
    }
}
