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
    @ObservationIgnored var onCardSizeChanged: ((CGSize) -> Void)?
}

/// Everything inside the coach's panel: the card, with room around it for its shadow.
struct AmbientTourPanelRootView: View {
    var model: AmbientTourModel
    var layout: AmbientTourPanelLayout

    var body: some View {
        AmbientTourCoachCard(model: model)
            // The card takes the height its content needs; the panel is then sized to it, not the reverse.
            .fixedSize(horizontal: false, vertical: true)
            // A preference set inside `.background` never reaches this view, which is how the first version of
            // this panel ended up never learning where its card was.
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { cardSize in layout.onCardSizeChanged?(cardSize) })
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

/// Owns the coach's floating panel. The panel is an ordinary window exactly as large as the card plus its shadow:
/// it always takes clicks, is dragged by its background like any window, and is resized when the card changes
/// height. Nothing here switches mouse handling on and off, because a card that misses a click is worse than a
/// card that covers a little of the screen.
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
    /// The size before the card has been measured.
    static let panelSize = CGSize(width: AmbientTourMetrics.cardWidth + cardMargin * 2, height: 320)

    private let panel: AmbientTourPanel
    private let layout = AmbientTourPanelLayout()
    private var windowMoveObserver: NSObjectProtocol?
    private var pendingShrink: DispatchWorkItem?
    /// Once the person has put the coach somewhere, it stays there instead of following the bar.
    private var hasBeenMovedByPerson = false
    private var isCardAnchoredToTop = true

    public init(model: AmbientTourModel) {
        self.model = model
        panel = AmbientTourPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the bar and its reply card, so an answer can never cover the coach's buttons.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own shadow, shaped like the glass.
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let hostingView = AmbientTourHostingView(rootView: AmbientTourPanelRootView(model: model, layout: layout))
        // The controller sizes the panel from the measured card; SwiftUI must not resize it as well.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        layout.onCardSizeChanged = { [weak self] cardSize in self?.cardSizeChanged(cardSize) }
        windowMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only a move made with the mouse button down is the person's; the controller's own placement is not.
                if NSEvent.pressedMouseButtons & 1 != 0 { self?.hasBeenMovedByPerson = true }
            }
        }
    }

    /// The coach's window, for captures. Do not reconfigure it.
    public var panelWindow: NSWindow { panel }

    public func show(awayFromBarDockedTo barEdge: FlowBarDockEdge, on screen: NSScreen?) {
        hasBeenMovedByPerson = false
        place(awayFromBarDockedTo: barEdge, on: screen)
        panel.orderFrontRegardless()
        model.begin()
    }

    /// The bar moved to another edge: move the coach to the corner away from it, unless the person placed it.
    public func barMoved(to barEdge: FlowBarDockEdge, on screen: NSScreen?) {
        guard !hasBeenMovedByPerson else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        place(awayFromBarDockedTo: barEdge, on: screen, animated: !reduceMotion)
    }

    public func close() {
        pendingShrink?.cancel()
        panel.orderOut(nil)
    }

    // MARK: Placement

    private func place(awayFromBarDockedTo barEdge: FlowBarDockEdge, on screen: NSScreen?, animated: Bool = false) {
        guard let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let corner = AmbientTourCoachCorner.corner(awayFromBarDockedTo: barEdge)
        let panelFrame = corner.panelFrame(panelSize: panel.frame.size, cardMargin: Self.cardMargin, inset: Self.insetFromScreenEdge, within: visibleFrame)
        if animated && panel.isVisible {
            // The card fades across instead of sliding, because a panel gliding over the whole screen would pull
            // the eye away from the bar the person just moved.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isCardAnchoredToTop = corner.isTop
                    self.layout.cardAlignment = corner.cardAlignmentInPanel
                    self.panel.setFrame(panelFrame, display: true)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        self.panel.animator().alphaValue = 1
                    }
                }
            }
        } else {
            isCardAnchoredToTop = corner.isTop
            layout.cardAlignment = corner.cardAlignmentInPanel
            panel.setFrame(panelFrame, display: true)
        }
    }

    // MARK: Sizing

    /// Keeps the panel exactly as tall as the card plus its shadow, holding the card's anchored edge still.
    private func cardSizeChanged(_ cardSize: CGSize) {
        guard cardSize.height > 0 else { return }
        pendingShrink?.cancel()
        let panelHeight = ceil(cardSize.height) + Self.cardMargin * 2
        guard abs(panelHeight - panel.frame.height) > 0.5 else { return }
        if panelHeight > panel.frame.height {
            resizePanel(toHeight: panelHeight)
        } else {
            // The card animates to its shorter height; cutting the window first would clip that animation.
            let shrink = DispatchWorkItem { [weak self] in self?.resizePanel(toHeight: panelHeight) }
            pendingShrink = shrink
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: shrink)
        }
    }

    private func resizePanel(toHeight panelHeight: CGFloat) {
        var frame = panel.frame
        if isCardAnchoredToTop { frame.origin.y = frame.maxY - panelHeight }
        frame.size.height = panelHeight
        panel.setFrame(frame, display: true)
    }
}
