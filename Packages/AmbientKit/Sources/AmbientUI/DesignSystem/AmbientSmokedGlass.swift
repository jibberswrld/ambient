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

private struct AmbientSurfaceRenderingModeKey: EnvironmentKey {
    static let defaultValue: AmbientSurfaceRenderingMode = .live
}

public extension EnvironmentValues {
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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var isIncreasedContrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        ZStack {
            materialLayer
            // A rim of light along the top edge, fading down: the glass catching light.
            shape.strokeBorder(rimLightGradient, lineWidth: isIncreasedContrast ? 1 : 0.75)
        }
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
                    .overlay(shape.fill(AmbientDesign.Palette.smoke.opacity(isRaisedCard ? 0.66 : 0.58)))
            case .live:
                liveMaterial
            }
        }
    }

    @ViewBuilder
    private var liveMaterial: some View {
        if #available(macOS 26, *) {
            // Liquid Glass, tinted toward warm graphite so white text reads over any desktop.
            Color.clear
                .glassEffect(.regular.tint(AmbientDesign.Palette.smoke.opacity(isRaisedCard ? 0.62 : 0.52)), in: shape)
        } else {
            BehindWindowBlurView()
                .clipShape(shape)
                .overlay(shape.fill(AmbientDesign.Palette.smoke.opacity(isRaisedCard ? 0.5 : 0.42)))
        }
    }

    private var rimLightGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(isIncreasedContrast ? 0.55 : 0.22), Color.white.opacity(isIncreasedContrast ? 0.35 : 0.05)],
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
