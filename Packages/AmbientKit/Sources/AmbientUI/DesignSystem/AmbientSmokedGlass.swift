import AppKit
import SwiftUI

/// How glass surfaces draw themselves.
///
/// Live glass is composited by the window server from whatever is behind the window, so an offscreen render
/// (used to capture the interface to PNG without screen-recording permission) cannot see it. In snapshot mode the
/// surface instead draws a pre-blurred copy of a known backdrop at its own position, which approximates the glass.
public enum AmbientSurfaceRenderingMode {
    case live
    case snapshot(AmbientSnapshotBackdrop)
}

/// A blurred image that fills the whole render canvas, for snapshot rendering.
public struct AmbientSnapshotBackdrop {
    public var blurredImage: NSImage
    public var canvasSize: CGSize
    public init(blurredImage: NSImage, canvasSize: CGSize) {
        self.blurredImage = blurredImage
        self.canvasSize = canvasSize
    }
}

private struct AmbientForcesIncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AmbientSurfaceRenderingModeKey: EnvironmentKey {
    static let defaultValue: AmbientSurfaceRenderingMode = .live
}

public extension EnvironmentValues {
    /// Draws surfaces as if Increase Contrast were on. SwiftUI's own contrast value cannot be set from code, so still
    /// captures use this to check the high-contrast look.
    var ambientForcesIncreasedContrast: Bool {
        get { self[AmbientForcesIncreasedContrastKey.self] }
        set { self[AmbientForcesIncreasedContrastKey.self] = newValue }
    }

    var ambientSurfaceRenderingMode: AmbientSurfaceRenderingMode {
        get { self[AmbientSurfaceRenderingModeKey.self] }
        set { self[AmbientSurfaceRenderingModeKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// True when rendering for a still capture: indicators jump to their resting values instead of animating in.
    var isAmbientSnapshotRendering: Bool {
        if case .snapshot = ambientSurfaceRenderingMode { return true }
        return false
    }
}

/// The smoked glass every Ambient surface on the desktop is made of.
struct AmbientSmokedGlassBackground: View {
    var cornerRadius: CGFloat
    /// Bigger surfaces read as thicker material: a deeper tint and a longer shadow.
    var isRaisedCard: Bool

    @Environment(\.ambientSurfaceRenderingMode) private var renderingMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.ambientForcesIncreasedContrast) private var forcesIncreasedContrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var isIncreasedContrast: Bool { colorSchemeContrast == .increased || forcesIncreasedContrast }

    var body: some View {
        ZStack {
            materialLayer
            // A rim of light along the top edge, fading down: the glass catching light.
            shape.strokeBorder(rimLightGradient, lineWidth: isIncreasedContrast ? 1 : 0.75)
        }
        // A tight contact shadow draws the edge on a white page, where the soft shadow alone leaves it fuzzy.
        .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(isRaisedCard ? 0.30 : 0.22), radius: isRaisedCard ? 22 : 10, y: isRaisedCard ? 10 : 4)
    }

    @ViewBuilder
    private var materialLayer: some View {
        if reduceTransparency || isIncreasedContrast {
            // Solid when the person asked for less transparency or more contrast.
            shape.fill(Color(white: isIncreasedContrast ? 0.04 : 0.09))
        } else {
            switch renderingMode {
            case .snapshot(let backdrop):
                SnapshotBackdropFill(backdrop: backdrop)
                    .clipShape(shape)
                    .overlay(shape.fill(AmbientDesign.Palette.smoke.opacity(smokeDensity)))
            case .live:
                liveMaterial
            }
        }
    }

    @ViewBuilder
    private var liveMaterial: some View {
        if #available(macOS 26, *) {
            // Liquid Glass lightens itself over a bright page, which turned the bar into pale grey with white text
            // on it. The glass keeps the refraction; the smoke laid over it is what guarantees the darkness.
            Color.clear
                .glassEffect(.regular.tint(AmbientDesign.Palette.smoke.opacity(0.5)), in: shape)
                .overlay(shape.fill(AmbientDesign.Palette.smoke.opacity(smokeDensity)))
        } else {
            BehindWindowBlurView()
                .clipShape(shape)
                .overlay(shape.fill(AmbientDesign.Palette.smoke.opacity(smokeDensity - 0.12)))
        }
    }

    /// How much smoke is in the glass. Dense enough that the bar is near-black over a white page (0.72 over white
    /// came out mid-grey, and page text showed through behind the bar's own text), with a trace of the desktop's
    /// colour still coming through. Cards are denser than pills because they carry paragraphs.
    private var smokeDensity: Double { isRaisedCard ? 0.90 : 0.86 }

    /// The rim: brighter on pills so the tiny resting bar is always findable, like a lit edge of glass.
    private var rimLightGradient: LinearGradient {
        let topOpacity = isIncreasedContrast ? 0.6 : (isRaisedCard ? 0.20 : 0.32)
        let bottomOpacity = isIncreasedContrast ? 0.4 : (isRaisedCard ? 0.06 : 0.12)
        return LinearGradient(
            colors: [Color.white.opacity(topOpacity), Color.white.opacity(bottomOpacity)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Draws the blurred backdrop at this view's own position on the canvas, so it looks like glass in a capture.
private struct SnapshotBackdropFill: View {
    var backdrop: AmbientSnapshotBackdrop

    var body: some View {
        GeometryReader { geometry in
            let frameOnCanvas = geometry.frame(in: .global)
            Image(nsImage: backdrop.blurredImage)
                .resizable()
                .frame(width: backdrop.canvasSize.width, height: backdrop.canvasSize.height)
                .offset(x: -frameOnCanvas.minX, y: -frameOnCanvas.minY)
        }
        .saturation(1.4)
    }
}

/// The macOS 14 and 15 fallback: the HUD material, blending with whatever is behind the window.
struct BehindWindowBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .darkAqua)
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
