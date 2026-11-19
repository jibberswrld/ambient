import CoreGraphics
import Foundation

/// The screen edge the flow bar lives on.
public enum FlowBarDockEdge: String, Codable, CaseIterable, Sendable {
    case bottom, top, left, right

    /// On the left and right edges the resting bar stands upright and its content reflows into a column.
    public var isVertical: Bool { self == .left || self == .right }

    /// A short, plain name for settings and onboarding.
    public var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Where the bar lives: which display, which edge of it, and how far along that edge.
public struct FlowBarDockPlacement: Codable, Equatable, Sendable {
    /// A stable identifier for the display (its UUID). Nil means the main display.
    public var displayIdentifier: String?
    public var edge: FlowBarDockEdge
    /// 0 is the start of the edge (left end of horizontal edges, bottom end of vertical edges), 1 the end,
    /// 0.5 the centre. Stored as a fraction so it survives a resolution change.
    public var positionAlongEdge: Double

    public init(displayIdentifier: String?, edge: FlowBarDockEdge, positionAlongEdge: Double) {
        self.displayIdentifier = displayIdentifier
        self.edge = edge
        self.positionAlongEdge = positionAlongEdge
    }

    public static let defaultPlacement = FlowBarDockPlacement(displayIdentifier: nil, edge: .bottom, positionAlongEdge: 0.5)
}

/// The arithmetic of docking, kept free of AppKit so it can be tested.
/// Points and frames are in AppKit screen coordinates (origin bottom-left, y grows upward) unless a name says otherwise.
public enum FlowBarDockGeometry {

    /// Within this distance of an edge's centre, the bar snaps to the exact centre.
    public static let centreSnapDistance: CGFloat = 28

    /// The edge of `visibleFrame` closest to `point`. Points outside the frame are clamped into it first.
    public static func nearestEdge(to point: CGPoint, within visibleFrame: CGRect) -> FlowBarDockEdge {
        let clampedPoint = clamp(point, into: visibleFrame)
        let distanceToEachEdge: [(FlowBarDockEdge, CGFloat)] = [
            (.bottom, clampedPoint.y - visibleFrame.minY),
            (.top, visibleFrame.maxY - clampedPoint.y),
            (.left, clampedPoint.x - visibleFrame.minX),
            (.right, visibleFrame.maxX - clampedPoint.x),
        ]
        // min(by:) keeps the first of equal elements, so ties resolve bottom, top, left, right.
        return distanceToEachEdge.min(by: { $0.1 < $1.1 })!.0
    }

    /// The fraction along `edge` that `point` corresponds to, snapping to 0.5 near the centre.
    /// `endMargin` keeps the bar's centre this far from either end, so the resting bar never hangs off the screen.
    public static func positionAlongEdge(for point: CGPoint, on edge: FlowBarDockEdge, within visibleFrame: CGRect, endMargin: CGFloat) -> Double {
        let usableRange = usableRangeAlongEdge(edge, within: visibleFrame, endMargin: endMargin)
        let coordinateAlongEdge = edge.isVertical ? point.y : point.x
        let centreOfEdge = (usableRange.lowerBound + usableRange.upperBound) / 2
        if abs(coordinateAlongEdge - centreOfEdge) <= centreSnapDistance { return 0.5 }
        let usableLength = usableRange.upperBound - usableRange.lowerBound
        guard usableLength > 0 else { return 0.5 }
        let fraction = (coordinateAlongEdge - usableRange.lowerBound) / usableLength
        return Double(min(max(fraction, 0), 1))
    }

    /// The point where the middle of the bar's edge-facing side sits, `insetFromEdge` inside the visible frame.
    public static func anchorPoint(for edge: FlowBarDockEdge, positionAlongEdge: Double, within visibleFrame: CGRect, endMargin: CGFloat, insetFromEdge: CGFloat) -> CGPoint {
        let usableRange = usableRangeAlongEdge(edge, within: visibleFrame, endMargin: endMargin)
        let clampedFraction = CGFloat(min(max(positionAlongEdge, 0), 1))
        let coordinateAlongEdge = usableRange.lowerBound + (usableRange.upperBound - usableRange.lowerBound) * clampedFraction
        switch edge {
        case .bottom: return CGPoint(x: coordinateAlongEdge, y: visibleFrame.minY + insetFromEdge)
        case .top: return CGPoint(x: coordinateAlongEdge, y: visibleFrame.maxY - insetFromEdge)
        case .left: return CGPoint(x: visibleFrame.minX + insetFromEdge, y: coordinateAlongEdge)
        case .right: return CGPoint(x: visibleFrame.maxX - insetFromEdge, y: coordinateAlongEdge)
        }
    }

    /// Where a throw would come to rest: the release point carried forward by the pointer's velocity, decaying the
    /// way scrolling does. A flick toward an edge lands on that edge even if released nearer another.
    /// `velocity` is in points per second.
    public static func projectedRestingPoint(from releasePoint: CGPoint, velocity: CGVector, decelerationRate: CGFloat = 0.99) -> CGPoint {
        let projectionFactor = decelerationRate / (1 - decelerationRate) / 1000
        return CGPoint(x: releasePoint.x + velocity.dx * projectionFactor, y: releasePoint.y + velocity.dy * projectionFactor)
    }

    /// The panel's frame: `panelSize`, extending away from the edge, centred on the anchor along the edge, and kept
    /// inside the visible frame.
    public static func panelFrame(anchorPoint: CGPoint, edge: FlowBarDockEdge, panelSize: CGSize, within visibleFrame: CGRect) -> CGRect {
        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: anchorPoint.x - panelSize.width / 2, y: visibleFrame.minY)
        case .top: origin = CGPoint(x: anchorPoint.x - panelSize.width / 2, y: visibleFrame.maxY - panelSize.height)
        case .left: origin = CGPoint(x: visibleFrame.minX, y: anchorPoint.y - panelSize.height / 2)
        case .right: origin = CGPoint(x: visibleFrame.maxX - panelSize.width, y: anchorPoint.y - panelSize.height / 2)
        }
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        return CGRect(origin: origin, size: panelSize)
    }

    /// Converts a screen point into a panel's SwiftUI space (origin top-left, y grows downward).
    public static func pointInPanelContent(_ screenPoint: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - panelFrame.minX, y: panelFrame.maxY - screenPoint.y)
    }

    /// Converts a rectangle in a panel's SwiftUI space back to screen coordinates.
    public static func screenRect(fromPanelContentRect contentRect: CGRect, panelFrame: CGRect) -> CGRect {
        CGRect(x: panelFrame.minX + contentRect.minX, y: panelFrame.maxY - contentRect.maxY, width: contentRect.width, height: contentRect.height)
    }

    /// Picks the display for a saved placement: the one with the saved identifier, else the main display
    /// (index `mainDisplayIndex`). Returns nil only when there are no displays.
    public static func indexOfDisplay(for placement: FlowBarDockPlacement, displayIdentifiers: [String], mainDisplayIndex: Int) -> Int? {
        guard !displayIdentifiers.isEmpty else { return nil }
        if let savedIdentifier = placement.displayIdentifier, let savedIndex = displayIdentifiers.firstIndex(of: savedIdentifier) {
            return savedIndex
        }
        return min(max(mainDisplayIndex, 0), displayIdentifiers.count - 1)
    }

    /// The display under `point`, or the nearest one when the point falls in a gap between displays.
    public static func indexOfDisplay(containing point: CGPoint, displayFrames: [CGRect]) -> Int? {
        if let containingIndex = displayFrames.firstIndex(where: { $0.contains(point) }) { return containingIndex }
        return displayFrames.indices.min(by: { distance(from: point, to: displayFrames[$0]) < distance(from: point, to: displayFrames[$1]) })
    }

    // MARK: Helpers

    private static func usableRangeAlongEdge(_ edge: FlowBarDockEdge, within visibleFrame: CGRect, endMargin: CGFloat) -> ClosedRange<CGFloat> {
        let start = edge.isVertical ? visibleFrame.minY : visibleFrame.minX
        let end = edge.isVertical ? visibleFrame.maxY : visibleFrame.maxX
        let lowerBound = start + endMargin
        let upperBound = end - endMargin
        if lowerBound > upperBound {
            let middle = (start + end) / 2
            return middle...middle
        }
        return lowerBound...upperBound
    }

    private static func clamp(_ point: CGPoint, into frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }

    private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let horizontalGap = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let verticalGap = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return (horizontalGap * horizontalGap + verticalGap * verticalGap).squareRoot()
    }
}

/// Saves and restores the bar's placement across launches.
public final class FlowBarPlacementStore {
    private let userDefaults: UserDefaults
    private let storageKey: String

    public init(userDefaults: UserDefaults = .standard, storageKey: String = "ambient.flowBar.dockPlacement") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    public func loadPlacement() -> FlowBarDockPlacement? {
        guard let storedData = userDefaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(FlowBarDockPlacement.self, from: storedData)
    }

    public func savePlacement(_ placement: FlowBarDockPlacement) {
        guard let encodedData = try? JSONEncoder().encode(placement) else { return }
        userDefaults.set(encodedData, forKey: storageKey)
    }
}
