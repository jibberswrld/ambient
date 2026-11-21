import AppKit
import SwiftUI
import AmbientUI

@MainActor
final class AmbientPointerWindowController {
    private var window: NSWindow?
    private var removalTask: Task<Void, Never>?

    func show(at location: CGPoint, displayFrame: CGRect, label: String) {
        hide()
        let window = NSPanel(contentRect: displayFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let target = CGPoint(x: location.x - displayFrame.minX, y: displayFrame.maxY - location.y)
        let leading = target.x > displayFrame.width / 2
        let above = target.y > displayFrame.height - 70
        let labelPlacement: AmbientPointerLabelPlacement = leading
            ? (above ? .leadingAbove : .leadingBelow) : (above ? .trailingAbove : .trailingBelow)
        let hostingView = NSHostingView(rootView:
            AmbientPointerView(label: label, phase: .arrived, labelPlacement: labelPlacement)
                .position(target)
                .frame(width: displayFrame.width, height: displayFrame.height)
        )
        hostingView.sizingOptions = []
        window.contentView = hostingView
        self.window = window
        window.orderFrontRegardless()
        NSLog("Ambient pointer shown: %@ at %@ on %@", label, NSStringFromPoint(location), NSStringFromRect(displayFrame))
        removalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        removalTask?.cancel()
        removalTask = nil
        if window != nil { NSLog("Ambient pointer removed") }
        window?.orderOut(nil)
        window = nil
    }
}
