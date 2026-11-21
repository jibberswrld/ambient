import AmbientUI
import AppKit
import SwiftUI

/// The desktops the bar is captured over. Each has a busy app window under the bar, because text behind
/// translucent glass is the hardest case for legibility.
enum DemoBackdrop: String, CaseIterable {
    case dark, light

    func image(canvasSize: CGSize, barEdge: FlowBarDockEdge) -> NSImage {
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        drawWallpaper(in: CGRect(origin: .zero, size: canvasSize))
        drawAppWindow(canvasSize: canvasSize, barEdge: barEdge)
        image.unlockFocus()
        return image
    }

    private func drawWallpaper(in canvasRect: CGRect) {
        let colors: [NSColor]
        switch self {
        case .dark:
            colors = [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.30, green: 0.16, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.06, green: 0.07, blue: 0.12, alpha: 1)]
        case .light:
            colors = [NSColor(srgbRed: 0.86, green: 0.90, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.98, green: 0.90, blue: 0.84, alpha: 1), NSColor(srgbRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)]
        }
        NSGradient(colors: colors)?.draw(in: canvasRect, angle: -35)
        // Two soft blobs so the glass has colour to pick up, like a real wallpaper.
        let blobColor = self == .dark ? NSColor(srgbRed: 0.35, green: 0.45, blue: 0.95, alpha: 0.35) : NSColor(srgbRed: 1.0, green: 0.70, blue: 0.55, alpha: 0.35)
        NSGradient(starting: blobColor, ending: blobColor.withAlphaComponent(0))?
            .draw(fromCenter: CGPoint(x: canvasRect.width * 0.25, y: canvasRect.height * 0.3), radius: 0,
                  toCenter: CGPoint(x: canvasRect.width * 0.25, y: canvasRect.height * 0.3), radius: canvasRect.width * 0.45, options: [])
    }

    /// A document window with lines of text, placed so the bar sits over part of it.
    private func drawAppWindow(canvasSize: CGSize, barEdge: FlowBarDockEdge) {
        let windowRect: CGRect
        switch barEdge {
        case .bottom: windowRect = CGRect(x: canvasSize.width * 0.30, y: -40, width: canvasSize.width * 0.62, height: canvasSize.height * 0.78)
        case .top: windowRect = CGRect(x: canvasSize.width * 0.30, y: canvasSize.height * 0.25, width: canvasSize.width * 0.62, height: canvasSize.height * 0.85)
        case .left: windowRect = CGRect(x: -40, y: canvasSize.height * 0.12, width: canvasSize.width * 0.55, height: canvasSize.height * 0.66)
        case .right: windowRect = CGRect(x: canvasSize.width * 0.5, y: canvasSize.height * 0.12, width: canvasSize.width * 0.6, height: canvasSize.height * 0.66)
        }
        let windowPath = NSBezierPath(roundedRect: windowRect, xRadius: 12, yRadius: 12)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowColor = NSColor.black.withAlphaComponent(self == .dark ? 0.5 : 0.18)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        (self == .dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.995, alpha: 1)).setFill()
        windowPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Title bar dots, so it reads as a real Mac window.
        let titleBarY = windowRect.maxY - 22
        for (dotIndex, dotColor) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            dotColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: windowRect.minX + 16 + CGFloat(dotIndex) * 20, y: titleBarY - 6, width: 12, height: 12)).fill()
        }

        // Lines of text: dark lines on the light window, light lines on the dark one.
        let textColor = self == .dark ? NSColor(white: 0.85, alpha: 0.55) : NSColor(white: 0.1, alpha: 0.55)
        let headingAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: textColor.withAlphaComponent(0.9)]
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: textColor]
        ("Launch plan" as NSString).draw(at: CGPoint(x: windowRect.minX + 40, y: titleBarY - 56), withAttributes: headingAttributes)
        let sentence = "The review moves to Thursday. Pricing page ships first, then the onboarding copy, then the docs. "
        var lineY = titleBarY - 84
        var lineIndex = 0
        while lineY > windowRect.minY + 20 {
            let lineText = String((sentence + sentence).dropFirst((lineIndex * 17) % sentence.count).prefix(Int((windowRect.width - 80) / 6.4)))
            (lineText as NSString).draw(at: CGPoint(x: windowRect.minX + 40, y: lineY), withAttributes: bodyAttributes)
            lineY -= 21
            lineIndex += 1
        }
    }
}

/// Renders every flow bar state to PNG without putting anything on screen.
@MainActor
enum DemoCaptureRunner {

    static func captureFlowBarStates(into directory: URL, edges: [FlowBarDockEdge], states: [DemoFlowBarState], backdrops: [DemoBackdrop], includeIncreasedContrast: Bool) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for edge in edges {
            let canvasSize = edge.isVertical ? CGSize(width: 620, height: 620) : CGSize(width: 760, height: 560)
            for backdrop in backdrops {
                let backdropImage = backdrop.image(canvasSize: canvasSize, barEdge: edge)
                for state in states {
                    let model = FlowBarModel()
                    model.revealsReplyInstantly = true
                    DemoScenarioDirector.apply(state, to: model)
                    if DemoScenarioDirector.needsAsyncSettle(state) {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                    }
                    await write(model: model, edge: edge, canvasSize: canvasSize, backdropImage: backdropImage, forcesIncreasedContrast: false,
                                to: directory.appendingPathComponent("flowbar-\(edge.rawValue)-\(backdrop.rawValue)-\(state.rawValue).png"))
                }
                if includeIncreasedContrast {
                    for state in [DemoFlowBarState.hovering, .reply, .working] {
                        let model = FlowBarModel()
                        model.revealsReplyInstantly = true
                        DemoScenarioDirector.apply(state, to: model)
                        await write(model: model, edge: edge, canvasSize: canvasSize, backdropImage: backdropImage, forcesIncreasedContrast: true,
                                    to: directory.appendingPathComponent("flowbar-\(edge.rawValue)-\(backdrop.rawValue)-\(state.rawValue)-contrast.png"))
                    }
                }
            }
        }
    }

    /// Renders through an off-screen window rather than ImageRenderer, because ImageRenderer cannot draw AppKit-backed
    /// pieces (the text field, scroll views) and the bar uses both.
    private static func write(model: FlowBarModel, edge: FlowBarDockEdge, canvasSize: CGSize, backdropImage: NSImage, forcesIncreasedContrast: Bool, to fileURL: URL) async {
        let canvas = AmbientSnapshotRenderer.flowBarCanvas(model: model, edge: edge, canvasSize: canvasSize, backdrop: backdropImage, forcesIncreasedContrast: forcesIncreasedContrast)
        await captureWindowContent(canvas, size: canvasSize, appearance: .darkAqua, settleSeconds: 0.25, to: fileURL)
    }

    /// Renders a window's SwiftUI content to PNG in an off-screen window, so AppKit-backed controls (text fields,
    /// scroll views) draw for real. The window is placed far outside every display and never ordered front.
    static func captureWindowContent<Content: View>(_ content: Content, size: CGSize, appearance: NSAppearance.Name, settleSeconds: Double, afterInstall: () -> Void = {}, to fileURL: URL) async {
        let offscreenWindow = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // Created in code, so it must not release itself on close: ARC owns it, and a double release crashes.
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.appearance = NSAppearance(named: appearance)
        let hostingView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        hostingView.frame = CGRect(origin: .zero, size: size)
        offscreenWindow.contentView = hostingView
        // Some states (a held shortcut) are reached by changing the model after the view is on its window.
        try? await Task.sleep(nanoseconds: 50_000_000)
        afterInstall()
        // Lets async page loads (the fake services answer after a short delay) finish before the capture.
        try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: fileURL)
        offscreenWindow.close()
    }
}
