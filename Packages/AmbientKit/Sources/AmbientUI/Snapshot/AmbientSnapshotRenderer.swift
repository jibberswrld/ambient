import AppKit
import CoreImage
import SwiftUI

/// Renders interface to images without putting anything on screen, for captures and visual checks.
///
/// Live glass is composited by the window server, so an offscreen render cannot see it. These renders paint the
/// backdrop themselves and draw each glass surface over a blurred copy of it, which approximates the material.
@MainActor
public enum AmbientSnapshotRenderer {

    /// The flow bar docked to the middle of `edge` on a canvas filled with `backdrop`, as a view. Host it in an
    /// off-screen window to capture it with text fields and scroll views drawn for real.
    public static func flowBarCanvas(model: FlowBarModel, edge: FlowBarDockEdge, canvasSize: CGSize, backdrop: NSImage, forcesIncreasedContrast: Bool = false) -> some View {
        model.revealsReplyInstantly = true
        model.dockEdge = edge
        model.draggedBarCentreInPanel = nil
        model.barAnchorInPanel = anchorPoint(for: edge, canvasSize: canvasSize)

        let backdropFillingCanvas = scaledToFill(backdrop, canvasSize: canvasSize)
        let snapshotBackdrop = AmbientSnapshotBackdrop(blurredImage: blurred(backdropFillingCanvas, radius: 26), canvasSize: canvasSize)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: backdropFillingCanvas)
                .resizable()
                .frame(width: canvasSize.width, height: canvasSize.height)
            FlowBarRootView(model: model)
                .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .environment(\.ambientSurfaceRenderingMode, .snapshot(snapshotBackdrop))
        .environment(\.ambientForcesIncreasedContrast, forcesIncreasedContrast)
    }

    /// The same canvas rendered straight to an image. Quick, but text fields and scroll views draw as placeholders.
    public static func renderFlowBar(model: FlowBarModel, edge: FlowBarDockEdge, canvasSize: CGSize, backdrop: NSImage, forcesIncreasedContrast: Bool = false, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: flowBarCanvas(model: model, edge: edge, canvasSize: canvasSize, backdrop: backdrop, forcesIncreasedContrast: forcesIncreasedContrast))
        renderer.scale = scale
        return renderer.nsImage
    }

    /// PNG bytes for an image, for writing captures to disk.
    public static func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Where the bar's edge-facing side sits on a canvas of `canvasSize`, the same inset a real screen uses.
    static func anchorPoint(for edge: FlowBarDockEdge, canvasSize: CGSize) -> CGPoint {
        let inset = AmbientDesign.Metrics.insetFromScreenEdge
        switch edge {
        case .bottom: return CGPoint(x: canvasSize.width / 2, y: canvasSize.height - inset)
        case .top: return CGPoint(x: canvasSize.width / 2, y: inset)
        case .left: return CGPoint(x: inset, y: canvasSize.height / 2)
        case .right: return CGPoint(x: canvasSize.width - inset, y: canvasSize.height / 2)
        }
    }

    static func scaledToFill(_ image: NSImage, canvasSize: CGSize) -> NSImage {
        let output = NSImage(size: canvasSize)
        output.lockFocus()
        let imageAspect = image.size.width / max(image.size.height, 1)
        let canvasAspect = canvasSize.width / canvasSize.height
        var drawSize = canvasSize
        if imageAspect > canvasAspect { drawSize.width = canvasSize.height * imageAspect } else { drawSize.height = canvasSize.width / imageAspect }
        let drawOrigin = CGPoint(x: (canvasSize.width - drawSize.width) / 2, y: (canvasSize.height - drawSize.height) / 2)
        image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        output.unlockFocus()
        return output
    }

    static func blurred(_ image: NSImage, radius: Double) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let inputImage = CIImage(cgImage: cgImage)
        // Clamping first stops the blur from pulling transparent pixels in at the edges.
        guard let blurredImage = inputImage.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: inputImage.extent) as CIImage?,
              let outputCGImage = CIContext().createCGImage(blurredImage, from: inputImage.extent)
        else { return image }
        return NSImage(cgImage: outputCGImage, size: image.size)
    }
}

extension AmbientSnapshotRenderer {
    /// The tour as the person sees it: the real bar docked to `barEdge` and the coach card in the corner away from
    /// it, on a canvas filled with `backdrop`. Host it in an off-screen window to capture it.
    public static func tourCanvas(tourModel: AmbientTourModel, barModel: FlowBarModel, barEdge: FlowBarDockEdge, canvasSize: CGSize, backdrop: NSImage) -> some View {
        let corner = AmbientTourCoachCorner.corner(awayFromBarDockedTo: barEdge)
        let inset = AmbientTourPanelController.insetFromScreenEdge
        return ZStack(alignment: .topLeading) {
            flowBarCanvas(model: barModel, edge: barEdge, canvasSize: canvasSize, backdrop: backdrop)
            AmbientTourCoachCard(model: tourModel)
                .padding(inset)
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: corner.cardAlignmentInPanel)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .environment(\.ambientSurfaceRenderingMode, .snapshot(AmbientSnapshotBackdrop(
            blurredImage: blurred(scaledToFill(backdrop, canvasSize: canvasSize), radius: 26), canvasSize: canvasSize)))
    }

    /// Any view (the pointer, for example) on a canvas filled with `backdrop`, with glass drawn as in a capture.
    public static func renderOverBackdrop<Content: View>(_ content: Content, canvasSize: CGSize, backdrop: NSImage, scale: CGFloat = 2) -> NSImage? {
        let backdropFillingCanvas = scaledToFill(backdrop, canvasSize: canvasSize)
        let snapshotBackdrop = AmbientSnapshotBackdrop(blurredImage: blurred(backdropFillingCanvas, radius: 26), canvasSize: canvasSize)
        let canvas = ZStack(alignment: .topLeading) {
            Image(nsImage: backdropFillingCanvas)
                .resizable()
                .frame(width: canvasSize.width, height: canvasSize.height)
            content
                .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .environment(\.ambientSurfaceRenderingMode, .snapshot(snapshotBackdrop))
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        return renderer.nsImage
    }
}

/// The onboarding screens as plain views, for captures and previews without opening the onboarding window.
@MainActor
public enum AmbientOnboardingPreview {
    public static func gate(_ content: AmbientGateContent) -> some View {
        previewRoot(.gate(content))
    }

    public static func permissions(_ permissionsModel: AmbientPermissionsModel) -> some View {
        previewRoot(.permissions(permissionsModel))
    }

    private static func previewRoot(_ screen: AmbientOnboardingCoordinator.Screen) -> some View {
        let coordinator = AmbientOnboardingCoordinator()
        coordinator.screen = screen
        return AmbientOnboardingRootView(coordinator: coordinator)
            .frame(width: AmbientOnboardingWindowController.windowSize.width, height: AmbientOnboardingWindowController.windowSize.height)
    }
}
