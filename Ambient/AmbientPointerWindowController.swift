import AppKit
import SwiftUI
import AmbientUI

/// The click-through window Ambient points and draws in. It covers one display and holds one thing at a time.
@MainActor
final class AmbientPointerWindowController {
    private var window: NSWindow?
    private var removalTask: Task<Void, Never>?

    func show(at location: CGPoint, displayFrame: CGRect, label: String) {
        let target = CGPoint(x: location.x - displayFrame.minX, y: displayFrame.maxY - location.y)
        let leading = target.x > displayFrame.width / 2
        let above = target.y > displayFrame.height - 70
        let labelPlacement: AmbientPointerLabelPlacement = leading
            ? (above ? .leadingAbove : .leadingBelow) : (above ? .trailingAbove : .trailingBelow)
        present(AmbientPointerView(label: label, phase: .arrived, labelPlacement: labelPlacement).position(target),
                displayFrame: displayFrame, lifetime: .seconds(4))
        NSLog("Ambient pointer shown: %@ at %@ on %@", label, NSStringFromPoint(location), NSStringFromRect(displayFrame))
    }

    /// Drawings stay long enough to follow along, and go when the person starts the next request.
    func show(annotations: [AmbientScreenAnnotation], displayFrame: CGRect) {
        present(AmbientAnnotationOverlayView(annotations: annotations), displayFrame: displayFrame, lifetime: .seconds(45))
        NSLog("Ambient drawing shown: %ld annotations on %@", annotations.count, NSStringFromRect(displayFrame))
    }

    private func present(_ content: some View, displayFrame: CGRect, lifetime: Duration) {
        hide()
        let window = NSPanel(contentRect: displayFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(rootView: content.frame(width: displayFrame.width, height: displayFrame.height))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        self.window = window
        window.orderFrontRegardless()
        removalTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        removalTask?.cancel()
        removalTask = nil
        if window != nil { NSLog("Ambient overlay removed") }
        window?.orderOut(nil)
        window = nil
    }
}
