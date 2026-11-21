import AppKit
import SwiftUI

/// A borderless panel that floats over everything, on every Space and beside full-screen apps, and only becomes key
/// while the person is typing into it.
final class FlowBarPanel: NSPanel {
    var allowsKeyFocus = false
    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click even though the panel is never active, so buttons work on the first press.
private final class FlowBarHostingView: NSHostingView<FlowBarRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    /// A stable identifier for the display, so a placement can be restored to the same monitor after a restart.
    var ambientDisplayIdentifier: String {
        guard let displayNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return localizedName }
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        guard let displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "display-\(displayID)" }
        return CFUUIDCreateString(nil, displayUUID) as String
    }
}

/// Owns the flow bar's window: where it docks, what takes clicks, hover, dragging between edges and displays.
///
/// Create one with the model the app drives, then call `show()`:
///
///     let flowBarModel = FlowBarModel()
///     let flowBarController = FlowBarPanelController(model: flowBarModel)
///     flowBarController.show()
@MainActor
public final class FlowBarPanelController {
    public let model: FlowBarModel
    public private(set) var placement: FlowBarDockPlacement

    private let placementStore: FlowBarPlacementStore
    private let panel: FlowBarPanel
    private var surfaceFrameInPanelContent: CGRect = .zero
    private var eventMonitors: [Any] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var pointerPollingTimer: Timer?
    private var pendingHoverChange: DispatchWorkItem?
    private var dragSession: DragSession?
    private var landingSettleWorkItem: DispatchWorkItem?

    /// Big enough for the largest card plus its shadow. Only the drawn glass takes clicks.
    static let panelSizeForHorizontalEdges = CGSize(width: 500, height: 560)
    static let panelSizeForVerticalEdges = CGSize(width: 470, height: 600)
    /// Keeps the bar's centre this far from the ends of an edge so it never hangs off the screen.
    static let edgeEndMargin: CGFloat = 40
    /// Extra room around the glass that still counts as "over the bar". Larger at rest because the resting bar is tiny.
    static let restingHoverSlop: CGFloat = 12
    static let expandedHoverSlop: CGFloat = 4

    private struct DragSession {
        var screen: NSScreen
        var pointerSamples: [(location: CGPoint, time: TimeInterval)] = []

        mutating func record(_ location: CGPoint) {
            pointerSamples.append((location, ProcessInfo.processInfo.systemUptime))
            if pointerSamples.count > 6 { pointerSamples.removeFirst(pointerSamples.count - 6) }
        }

        /// Points per second over the last few samples.
        var releaseVelocity: CGVector {
            guard let first = pointerSamples.first, let last = pointerSamples.last, last.time - first.time > 0.005 else { return .zero }
            let elapsed = last.time - first.time
            // A pointer that stopped before release carries no momentum.
            if ProcessInfo.processInfo.systemUptime - last.time > 0.08 { return .zero }
            return CGVector(dx: (last.location.x - first.location.x) / elapsed, dy: (last.location.y - first.location.y) / elapsed)
        }
    }

    public init(model: FlowBarModel, placementStore: FlowBarPlacementStore = FlowBarPlacementStore()) {
        self.model = model
        self.placementStore = placementStore
        self.placement = placementStore.loadPlacement() ?? .defaultPlacement

        panel = FlowBarPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSizeForHorizontalEdges),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own shadow, shaped like the glass.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let hostingView = FlowBarHostingView(rootView: FlowBarRootView(model: model))
        // The panel's size is ours to decide; SwiftUI must not resize it to fit the bar.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        connectModelHooks()
        observeSystemChanges()
    }

    // MARK: Public

    public func show() {
        applyPlacement()
        panel.orderFrontRegardless()
        installPointerMonitors()
    }

    public func hide() {
        panel.orderOut(nil)
        removePointerMonitors()
    }

    /// Moves the bar to `edge` on its current display, centred. Used by settings and onboarding.
    public func dock(to edge: FlowBarDockEdge) {
        let previousEdge = placement.edge
        placement.edge = edge
        placement.positionAlongEdge = 0.5
        placementStore.savePlacement(placement)
        applyPlacement()
        if edge != previousEdge { model.onDockEdgeChanged?(edge) }
    }

    /// The bar's window, for captures. Do not reconfigure it.
    public var panelWindow: NSWindow { panel }

    /// The display the bar is docked to.
    public var dockedScreen: NSScreen? { resolvedScreen() }

    /// Where the drawn glass is right now, in screen coordinates (origin bottom-left).
    public var barSurfaceFrameOnScreen: CGRect { surfaceFrameOnScreen }

    // MARK: Placement

    private func resolvedScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let screenIndex = FlowBarDockGeometry.indexOfDisplay(
            for: placement,
            displayIdentifiers: screens.map(\.ambientDisplayIdentifier),
            mainDisplayIndex: 0
        ) else { return nil }
        return screens[screenIndex]
    }

    /// Puts the panel where the placement says, without animation. `visibleFrame` keeps clear of the menu bar,
    /// the notch and the Dock.
    private func applyPlacement() {
        guard let screen = resolvedScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let anchorOnScreen = FlowBarDockGeometry.anchorPoint(
            for: placement.edge,
            positionAlongEdge: placement.positionAlongEdge,
            within: visibleFrame,
            endMargin: Self.edgeEndMargin,
            insetFromEdge: AmbientDesign.Metrics.insetFromScreenEdge
        )
        let panelSize = placement.edge.isVertical ? Self.panelSizeForVerticalEdges : Self.panelSizeForHorizontalEdges
        let panelFrame = FlowBarDockGeometry.panelFrame(anchorPoint: anchorOnScreen, edge: placement.edge, panelSize: panelSize, within: visibleFrame)
        withoutAnimation {
            panel.setFrame(panelFrame, display: true)
            model.dockEdge = placement.edge
            model.barAnchorInPanel = FlowBarDockGeometry.pointInPanelContent(anchorOnScreen, panelFrame: panelFrame)
            model.draggedBarCentreInPanel = nil
        }
    }

    // MARK: Model hooks

    private func connectModelHooks() {
        model.onSurfaceFrameChanged = { [weak self] surfaceFrame in
            self?.surfaceFrameInPanelContent = surfaceFrame
            self?.evaluatePointer()
        }
        model.onBarDragChanged = { [weak self] in self?.barDragChanged() }
        model.onBarDragEnded = { [weak self] in self?.barDragEnded() }
        model.onTypingStateChanged = { [weak self] isTyping in self?.typingStateChanged(isTyping) }
    }

    private func typingStateChanged(_ isTyping: Bool) {
        if isTyping {
            panel.allowsKeyFocus = true
            panel.ignoresMouseEvents = false
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.allowsKeyFocus = false
            if panel.isKeyWindow {
                // Ordering out and back in hands keyboard focus back to the app the person was using.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    private func observeSystemChanges() {
        let notificationCenter = NotificationCenter.default
        notificationObservers.append(notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A display was added, removed or rearranged: re-resolve (falling back to the main display).
                guard let self, self.dragSession == nil else { return }
                self.applyPlacement()
            }
        })
        notificationObservers.append(notificationCenter.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Clicking anywhere else ends typing, like any text field losing focus.
                self?.model.endTyping()
            }
        })
    }

    // MARK: Pointer: click-through and hover

    private func installPointerMonitors() {
        guard eventMonitors.isEmpty else { return }
        let pointerEventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEventMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluatePointer() }
        }) {
            eventMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEventMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.evaluatePointer() }
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    private func removePointerMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        pointerPollingTimer?.invalidate()
        pointerPollingTimer = nil
    }

    private var surfaceFrameOnScreen: CGRect {
        FlowBarDockGeometry.screenRect(fromPanelContentRect: surfaceFrameInPanelContent, panelFrame: panel.frame)
    }

    /// Lets clicks through everywhere except the glass, and turns hover on and off.
    private func evaluatePointer() {
        guard dragSession == nil else { return }
        let pointerLocation = NSEvent.mouseLocation
        let hoverSlop = model.presentation == .resting ? Self.restingHoverSlop : Self.expandedHoverSlop
        let isPointerOverBar = surfaceFrameOnScreen.insetBy(dx: -hoverSlop, dy: -hoverSlop).contains(pointerLocation)

        panel.ignoresMouseEvents = !isPointerOverBar && !model.isTyping
        updatePointerPolling(isPointerOverBar: isPointerOverBar)
        scheduleHoverChange(isPointerOverBar)
    }

    /// While the pointer is over the panel, moved events go to this app and may not reach the monitors, so poll
    /// briefly to notice it leaving.
    private func updatePointerPolling(isPointerOverBar: Bool) {
        if isPointerOverBar, pointerPollingTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluatePointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerPollingTimer = timer
        } else if !isPointerOverBar {
            pointerPollingTimer?.invalidate()
            pointerPollingTimer = nil
        }
    }

    /// Hover starts after a short pause so a pointer passing through does not make the bar jump, and ends after a
    /// longer one so a pointer wobbling at the edge does not make it flicker.
    private func scheduleHoverChange(_ isPointerOverBar: Bool) {
        guard isPointerOverBar != model.isPointerHovering else {
            pendingHoverChange?.cancel()
            pendingHoverChange = nil
            return
        }
        guard pendingHoverChange == nil else { return }
        let hoverChange = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingHoverChange = nil
                self.model.setPointerHovering(isPointerOverBar)
            }
        }
        pendingHoverChange = hoverChange
        DispatchQueue.main.asyncAfter(deadline: .now() + (isPointerOverBar ? 0.07 : 0.28), execute: hoverChange)
    }

    // MARK: Dragging to another edge or display

    private func screen(containing point: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = FlowBarDockGeometry.indexOfDisplay(containing: point, displayFrames: screens.map(\.frame)) else { return nil }
        return screens[index]
    }

    private func barDragChanged() {
        let pointerLocation = NSEvent.mouseLocation
        if dragSession == nil {
            beginDrag(at: pointerLocation)
            return
        }
        guard var session = dragSession else { return }
        if let screenUnderPointer = screen(containing: pointerLocation), screenUnderPointer != session.screen {
            // Crossing to another display: the panel jumps to cover that display and the bar keeps following.
            session.screen = screenUnderPointer
            withoutAnimation {
                panel.setFrame(screenUnderPointer.frame, display: true)
                model.draggedBarCentreInPanel = FlowBarDockGeometry.pointInPanelContent(pointerLocation, panelFrame: panel.frame)
            }
        }
        session.record(pointerLocation)
        dragSession = session
        withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.9)) {
            model.draggedBarCentreInPanel = FlowBarDockGeometry.pointInPanelContent(pointerLocation, panelFrame: panel.frame)
        }
    }

    /// The panel grows to cover the whole display for the duration of the drag so the bar can travel anywhere,
    /// and the docked position is re-expressed in the new frame so nothing moves on screen.
    private func beginDrag(at pointerLocation: CGPoint) {
        landingSettleWorkItem?.cancel()
        pendingHoverChange?.cancel()
        pendingHoverChange = nil
        guard let dragScreen = screen(containing: pointerLocation) ?? panel.screen else { return }
        let surfaceCentreOnScreen = CGPoint(x: surfaceFrameOnScreen.midX, y: surfaceFrameOnScreen.midY)
        let anchorOnScreen = CGPoint(
            x: panel.frame.minX + model.barAnchorInPanel.x,
            y: panel.frame.maxY - model.barAnchorInPanel.y
        )
        var session = DragSession(screen: dragScreen)
        session.record(pointerLocation)
        dragSession = session
        panel.ignoresMouseEvents = false
        withoutAnimation {
            panel.setFrame(dragScreen.frame, display: true)
            model.barAnchorInPanel = FlowBarDockGeometry.pointInPanelContent(anchorOnScreen, panelFrame: panel.frame)
            model.draggedBarCentreInPanel = FlowBarDockGeometry.pointInPanelContent(surfaceCentreOnScreen, panelFrame: panel.frame)
        }
        // Next frame: the bar lifts and glides under the pointer.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragSession != nil else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    self.model.draggedBarCentreInPanel = FlowBarDockGeometry.pointInPanelContent(NSEvent.mouseLocation, panelFrame: self.panel.frame)
                }
            }
        }
    }

    private func barDragEnded() {
        guard let session = dragSession else { return }
        dragSession = nil
        let releaseLocation = NSEvent.mouseLocation
        let projectedLocation = FlowBarDockGeometry.projectedRestingPoint(from: releaseLocation, velocity: session.releaseVelocity)
        let landingScreen = session.screen
        let visibleFrame = landingScreen.visibleFrame
        let landingEdge = FlowBarDockGeometry.nearestEdge(to: projectedLocation, within: visibleFrame)
        let landingPosition = FlowBarDockGeometry.positionAlongEdge(for: projectedLocation, on: landingEdge, within: visibleFrame, endMargin: Self.edgeEndMargin)
        let previousEdge = placement.edge

        placement = FlowBarDockPlacement(displayIdentifier: landingScreen.ambientDisplayIdentifier, edge: landingEdge, positionAlongEdge: landingPosition)
        placementStore.savePlacement(placement)

        let anchorOnScreen = FlowBarDockGeometry.anchorPoint(
            for: landingEdge,
            positionAlongEdge: landingPosition,
            within: visibleFrame,
            endMargin: Self.edgeEndMargin,
            insetFromEdge: AmbientDesign.Metrics.insetFromScreenEdge
        )
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(AmbientDesign.Motion.dockLanding(reduceMotion: reduceMotion)) {
            model.dockEdge = landingEdge
            model.barAnchorInPanel = FlowBarDockGeometry.pointInPanelContent(anchorOnScreen, panelFrame: panel.frame)
            model.draggedBarCentreInPanel = nil
        }
        // The full-display panel must not swallow clicks while the bar lands.
        panel.ignoresMouseEvents = true
        if landingEdge != previousEdge { model.onDockEdgeChanged?(landingEdge) }

        // Once the landing spring has settled, shrink the panel back to its docked size. The bar is already exactly
        // where the docked layout puts it, so this is invisible.
        let settle = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragSession == nil else { return }
                self.applyPlacement()
                self.evaluatePointer()
            }
        }
        landingSettleWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: settle)
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}
