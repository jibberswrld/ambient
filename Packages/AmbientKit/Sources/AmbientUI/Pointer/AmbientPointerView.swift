import SwiftUI

/// Which side of the point the label sits on. Integration flips it near the screen's right or bottom edge so
/// the label stays on screen.
public enum AmbientPointerLabelPlacement: Sendable {
    case trailingBelow, trailingAbove, leadingBelow, leadingAbove
}

/// Ambient pointing at something on screen: the ember, the same light that lives in the bar, travels to the
/// target, a ring closes around it like a focus lock, and a smoked-glass label names it.
///
/// The view's centre is the exact point being pointed at, so place it with `.position(targetPoint)` in the
/// overlay window and animate that position while `phase` is `.travelling`. The label draws outside the view's
/// frame and never shifts the point.
///
///     AmbientPointerView(label: "Share button", phase: hasArrived ? .arrived : .travelling)
///         .position(targetPointInOverlay)
public struct AmbientPointerView: View {
    public enum Phase: Equatable, Sendable { case travelling, arrived }

    var label: String?
    var phase: Phase
    var labelPlacement: AmbientPointerLabelPlacement

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    /// The side of the square the view occupies. The point is at its centre.
    public static let footprint: CGFloat = 44

    public init(label: String?, phase: Phase, labelPlacement: AmbientPointerLabelPlacement = .trailingBelow) {
        self.label = label
        self.phase = phase
        self.labelPlacement = labelPlacement
    }

    public var body: some View {
        let hasArrived = phase == .arrived
        ZStack {
            AmbientPointerHalo(isBreathing: hasArrived && !reduceMotion && !isSnapshotRendering)
            // The lock-on ring: closes from wide and faint to tight and bright as the ember lands.
            Circle()
                .strokeBorder(AmbientDesign.Palette.ember.opacity(hasArrived ? 0.95 : 0), lineWidth: 1.5)
                .frame(width: 26, height: 26)
                .scaleEffect(hasArrived || reduceMotion ? 1 : 1.7)
            Circle()
                .strokeBorder(Color.black.opacity(hasArrived ? 0.35 : 0), lineWidth: 0.75)
                .frame(width: 28.5, height: 28.5)
                .scaleEffect(hasArrived || reduceMotion ? 1 : 1.7)
            AmbientPointerCore()
        }
        .frame(width: Self.footprint, height: Self.footprint)
        .overlay(alignment: labelAlignment) {
            if let label, hasArrived {
                AmbientPointerLabel(text: label)
                    .fixedSize()
                    .alignmentGuide(labelAlignment.horizontal) { dimensions in labelHorizontalGuide(dimensions) }
                    .alignmentGuide(labelAlignment.vertical) { dimensions in labelVerticalGuide(dimensions) }
                    .transition(labelTransition)
            }
        }
        .animation(arrivalAnimation, value: phase)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "Pointing at \($0)" } ?? "Pointing")
    }

    private var arrivalAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.9)
    }

    /// The label rises out of the point toward its side, so it reads as coming from the ember.
    private var labelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let horizontalDirection: CGFloat = isTrailing ? -1 : 1
        let verticalDirection: CGFloat = isBelow ? -1 : 1
        return .offset(x: 6 * horizontalDirection, y: 4 * verticalDirection)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.96, anchor: isTrailing ? .leading : .trailing))
    }

    private var isTrailing: Bool { labelPlacement == .trailingBelow || labelPlacement == .trailingAbove }
    private var isBelow: Bool { labelPlacement == .trailingBelow || labelPlacement == .leadingBelow }

    private var labelAlignment: Alignment {
        switch labelPlacement {
        case .trailingBelow: return .bottomTrailing
        case .trailingAbove: return .topTrailing
        case .leadingBelow: return .bottomLeading
        case .leadingAbove: return .topLeading
        }
    }

    /// Puts the label's near edge just past the ring, diagonally from the point.
    private func labelHorizontalGuide(_ dimensions: ViewDimensions) -> CGFloat {
        let gapFromCentre: CGFloat = 10
        let inset = Self.footprint / 2 - gapFromCentre
        return isTrailing ? dimensions[.leading] + inset : dimensions[.trailing] - inset
    }

    private func labelVerticalGuide(_ dimensions: ViewDimensions) -> CGFloat {
        let gapFromCentre: CGFloat = 12
        let inset = Self.footprint / 2 - gapFromCentre
        return isBelow ? dimensions[.top] + inset : dimensions[.bottom] - inset
    }
}

/// The ember itself: a hot core with a crisp dark rim so it reads on white pages as well as dark ones.
private struct AmbientPointerCore: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [AmbientDesign.Palette.emberCore, AmbientDesign.Palette.ember], center: .center, startRadius: 0, endRadius: 6))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
            .shadow(color: AmbientDesign.Palette.ember.opacity(0.9), radius: 4)
    }
}

/// The soft glow around the ember. Breathes slowly once arrived, so a pointer left on screen stays alive.
private struct AmbientPointerHalo: View {
    var isBreathing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isBreathing)) { timeline in
            let breath = isBreathing ? 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8) : 0.6
            Circle()
                .fill(RadialGradient(colors: [AmbientDesign.Palette.ember.opacity(0.42 + 0.14 * breath), AmbientDesign.Palette.ember.opacity(0)], center: .center, startRadius: 2, endRadius: 22))
                .frame(width: 44, height: 44)
        }
    }
}

/// The name of what Ambient is pointing at, on the same smoked glass as the bar.
private struct AmbientPointerLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(AmbientSmokedGlassBackground(cornerRadius: 13, isRaisedCard: false))
            .environment(\.colorScheme, .dark)
    }
}
