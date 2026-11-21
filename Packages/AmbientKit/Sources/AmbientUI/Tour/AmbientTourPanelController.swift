import AppKit
import Observation
import SwiftUI

/// The screen corner the coach sits in.
public enum AmbientTourCoachCorner: Equatable, Sendable {
    case topLeading, topTrailing, bottomTrailing

    /// The corner farthest from wherever the bar and its reply card grow. The bar's cards grow from the middle of
    /// its edge, so any corner on the opposite side of the screen is clear of them.
    public static func corner(awayFromBarDockedTo barEdge: FlowBarDockEdge) -> AmbientTourCoachCorner {
        switch barEdge {
        case .bottom, .left: return .topTrailing
        case .top: return .bottomTrailing
        case .right: return .topLeading
        }
    }

    var isTop: Bool { self != .bottomTrailing }

    /// Where the card sits inside its panel, so the panel's transparent room for growth points away from the corner.
    var cardAlignmentInPanel: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// The panel's frame for this corner of `visibleFrame` (AppKit coordinates), with the card itself `inset` from
    /// the screen edges and `cardMargin` of transparent room for the shadow between the card and the panel edge.
    public func panelFrame(panelSize: CGSize, cardMargin: CGFloat, inset: CGFloat, within visibleFrame: CGRect) -> CGRect {
        let originX: CGFloat
        switch self {
        case .topLeading: originX = visibleFrame.minX + inset - cardMargin
        case .topTrailing, .bottomTrailing: originX = visibleFrame.maxX - inset + cardMargin - panelSize.width
        }
        let originY = isTop
            ? visibleFrame.maxY - inset + cardMargin - panelSize.height
            : visibleFrame.minY + inset - cardMargin
        return CGRect(origin: CGPoint(x: originX, y: originY), size: panelSize)
    }
}

/// Layout and hooks shared between the panel controller and the SwiftUI inside it.
@MainActor
@Observable
final class AmbientTourPanelLayout {
    var cardAlignment: Alignment = .topTrailing
    @ObservationIgnored var onCardFrameChanged: ((CGRect) -> Void)?
    @ObservationIgnored var onCardDragChanged: (() -> Void)?
    @ObservationIgnored var onCardDragEnded: (() -> Void)?
}

private struct AmbientTourCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Everything inside the coach's panel: the card in its corner, with room around it for the shadow and for the
/// card to grow without the window resizing under it.
struct AmbientTourPanelRootView: View {
    var model: AmbientTourModel
    var layout: AmbientTourPanelLayout

    var body: some View {
        AmbientTourCoachCard(model: model)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AmbientTourCardFramePreferenceKey.self, value: geometry.frame(in: .global))
            })
            .onPreferenceChange(AmbientTourCardFramePreferenceKey.self) { cardFrame in layout.onCardFrameChanged?(cardFrame) }
            // The card moves with the pointer from wherever it was grabbed. Buttons still take plain clicks
            // because the drag only starts after the pointer has moved.
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in layout.onCardDragChanged?() }
                    .onEnded { _ in layout.onCardDragEnded?() }
            )
            .padding(AmbientTourPanelController.cardMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.cardAlignment)
    }
}

/// Accepts the first click even though the panel never becomes active, so buttons work on the first press.
private final class AmbientTourHostingView: NSHostingView<AmbientTourPanelRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A panel that floats over other apps but never becomes key, so the coach never takes focus or keystrokes from
/// the app the person is working in.
private final class AmbientTourPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the coach's floating panel: where it sits relative to the bar, letting clicks through everywhere except
/// the card, and moving it when the person drags it.
///
///     let tourController = AmbientTourPanelController(model: tourModel)
///     tourController.show(awayFromBarDockedTo: .bottom, on: flowBarController.dockedScreen)
///     tourController.close()
@MainActor
public final class AmbientTourPanelController {
    public let model: AmbientTourModel

    /// Transparent room around the card for its shadow.
    static let cardMargin: CGFloat = 28
    /// Gap between the card and the edges of the usable screen.
    static let insetFromScreenEdge: CGFloat = 14
    /// Tall enough for the tallest card (the cheat sheet) plus its margin. Only the card takes clicks.
    static let panelSize = CGSize(width: AmbientTourMetrics.cardWidth + cardMargin * 2, height: 520)

    private let panel: AmbientTourPanel
    private let layout = AmbientTourPanelLayout()
    private var cardFrameInPanelContent: CGRect = .zero
    private var eventMonitors: [Any] = []
    private var dragStart: (panelOrigin: CGPoint, pointerLocation: CGPoint)?
    /// Once the person has put the coach somewhere, it stays there instead of following the bar.
    private var hasBeenMovedByPerson = false

    public init(model: AmbientTourModel) {
        self.model = model
        panel = AmbientTourPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Below the bar (status bar level), so the coach can never cover the bar or its reply card.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own shadow, shaped like the glass.
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let hostingView = AmbientTourHostingView(rootView: AmbientTourPanelRootView(model: model, layout: layout))
        // The panel's size is fixed; SwiftUI must not resize it to fit the card.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        layout.onCardFrameChanged = { [weak self] cardFrame in
            self?.cardFrameInPanelContent = cardFrame
            self?.updateClickThrough()
        }
        layout.onCardDragChanged = { [weak self] in self?.cardDragChanged() }
        layout.onCardDragEnded = { [weak self] in self?.cardDragEnded() }
    }

    /// The coach's window, for captures. Do not reconfigure it.
    public var panelWindow: NSWindow { panel }

    public func show(awayFromBarDockedTo barEdge: FlowBarDockEdge, on screen: NSScreen?) {
        hasBeenMovedByPerson = false
        place(awayFromBarDockedTo: barEdge, on: screen)
        panel.orderFrontRegardless()
        installPointerMonitors()
        model.begin()
    }

    /// The bar moved to another edge: move the coach to the corner away from it, unless the person placed it.
    public func barMoved(to barEdge: FlowBarDockEdge, on screen: NSScreen?) {
        guard !hasBeenMovedByPerson else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        place(awayFromBarDockedTo: barEdge, on: screen, animated: !reduceMotion)
    }

    public func close() {
        removePointerMonitors()
        panel.orderOut(nil)
    }

    // MARK: Placement

    private func place(awayFromBarDockedTo barEdge: FlowBarDockEdge, on screen: NSScreen?, animated: Bool = false) {
        guard let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let corner = AmbientTourCoachCorner.corner(awayFromBarDockedTo: barEdge)
        let panelFrame = corner.panelFrame(panelSize: Self.panelSize, cardMargin: Self.cardMargin, inset: Self.insetFromScreenEdge, within: visibleFrame)
        if animated && panel.isVisible {
            // The card fades across instead of sliding, because a panel this size gliding over the whole screen
            // would pull the eye away from the bar the person just moved.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.layout.cardAlignment = corner.cardAlignmentInPanel
                    self.panel.setFrame(panelFrame, display: true)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        self.panel.animator().alphaValue = 1
                    }
                }
            }
        } else {
            layout.cardAlignment = corner.cardAlignmentInPanel
            panel.setFrame(panelFrame, display: true)
        }
    }

    // MARK: Pointer: click-through

    private func installPointerMonitors() {
        guard eventMonitors.isEmpty else { return }
        let pointerEventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEventMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }) {
            eventMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEventMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateClickThrough() }
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    private func removePointerMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    /// The panel is larger than the card so the card can grow; only the card itself takes clicks.
    private func updateClickThrough() {
        guard dragStart == nil else { return }
        let cardFrameOnScreen = FlowBarDockGeometry.screenRect(fromPanelContentRect: cardFrameInPanelContent, panelFrame: panel.frame)
        panel.ignoresMouseEvents = !cardFrameOnScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: Dragging

    private func cardDragChanged() {
        let pointerLocation = NSEvent.mouseLocation
        guard let dragStart else {
            self.dragStart = (panel.frame.origin, pointerLocation)
            return
        }
        hasBeenMovedByPerson = true
        let proposedOrigin = CGPoint(
            x: dragStart.panelOrigin.x + pointerLocation.x - dragStart.pointerLocation.x,
            y: dragStart.panelOrigin.y + pointerLocation.y - dragStart.pointerLocation.y
        )
        panel.setFrameOrigin(proposedOrigin)
    }

    private func cardDragEnded() {
        dragStart = nil
        keepCardOnScreen()
        updateClickThrough()
    }

    /// A card let go partly off a display slides back so all of it is visible.
    private func keepCardOnScreen() {
        let cardFrameOnScreen = FlowBarDockGeometry.screenRect(fromPanelContentRect: cardFrameInPanelContent, panelFrame: panel.frame)
        let screenUnderCard = NSScreen.screens.first { $0.frame.intersects(cardFrameOnScreen) } ?? NSScreen.main
        guard let visibleFrame = screenUnderCard?.visibleFrame else { return }
        var correction = CGVector.zero
        if cardFrameOnScreen.minX < visibleFrame.minX { correction.dx = visibleFrame.minX - cardFrameOnScreen.minX }
        if cardFrameOnScreen.maxX > visibleFrame.maxX { correction.dx = visibleFrame.maxX - cardFrameOnScreen.maxX }
        if cardFrameOnScreen.minY < visibleFrame.minY { correction.dy = visibleFrame.minY - cardFrameOnScreen.minY }
        if cardFrameOnScreen.maxY > visibleFrame.maxY { correction.dy = visibleFrame.maxY - cardFrameOnScreen.maxY }
        guard correction != .zero else { return }
        var correctedFrame = panel.frame
        correctedFrame.origin.x += correction.dx
        correctedFrame.origin.y += correction.dy
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().setFrame(correctedFrame, display: true)
        }
    }
}
