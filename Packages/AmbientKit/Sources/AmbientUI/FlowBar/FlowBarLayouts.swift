import SwiftUI

/// Places the bar so the middle of its edge-facing side sits on the anchor point, and the rest of it grows away
/// from the edge. Near a corner it slides the surface along the edge just enough to stay inside the panel.
struct FlowBarAnchoredLayout: Layout {
    var edge: FlowBarDockEdge
    var anchorPoint: CGPoint
    /// While dragging, the surface is centred here instead.
    var draggedCentre: CGPoint?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let surface = subviews.first else { return }
        let surfaceSize = surface.sizeThatFits(ProposedViewSize(width: bounds.width, height: bounds.height))
        var origin: CGPoint
        if let draggedCentre {
            origin = CGPoint(x: draggedCentre.x - surfaceSize.width / 2, y: draggedCentre.y - surfaceSize.height / 2)
        } else {
            switch edge {
            case .bottom: origin = CGPoint(x: anchorPoint.x - surfaceSize.width / 2, y: anchorPoint.y - surfaceSize.height)
            case .top: origin = CGPoint(x: anchorPoint.x - surfaceSize.width / 2, y: anchorPoint.y)
            case .left: origin = CGPoint(x: anchorPoint.x, y: anchorPoint.y - surfaceSize.height / 2)
            case .right: origin = CGPoint(x: anchorPoint.x - surfaceSize.width, y: anchorPoint.y - surfaceSize.height / 2)
            }
            // Keep the whole surface inside the panel along the edge; never push it off the edge itself.
            let edgeMargin: CGFloat = 6
            if edge.isVertical {
                origin.y = min(max(origin.y, edgeMargin), max(edgeMargin, bounds.height - surfaceSize.height - edgeMargin))
            } else {
                origin.x = min(max(origin.x, edgeMargin), max(edgeMargin, bounds.width - surfaceSize.width - edgeMargin))
            }
        }
        surface.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading, proposal: ProposedViewSize(surfaceSize))
    }
}

/// Tags each state's content so the morphing container knows which one is current.
struct FlowBarPresentationLayoutKey: LayoutValueKey {
    static let defaultValue: FlowBarPresentation? = nil
}

/// Sizes the glass to the current state's content only. The outgoing state's content keeps its own size while it
/// fades, and is clipped by the glass, so the surface never jumps to the union of two layouts mid-transition.
struct FlowBarMorphingContentLayout: Layout {
    var currentPresentation: FlowBarPresentation
    /// Content sits against the docked edge, so growth always reads as moving away from it.
    var edge: FlowBarDockEdge

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let currentSubview = subviews.last(where: { $0[FlowBarPresentationLayoutKey.self] == currentPresentation }) ?? subviews.last
        return currentSubview?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(proposal)
            let origin: CGPoint
            switch edge {
            case .bottom: origin = CGPoint(x: bounds.midX - subviewSize.width / 2, y: bounds.maxY - subviewSize.height)
            case .top: origin = CGPoint(x: bounds.midX - subviewSize.width / 2, y: bounds.minY)
            case .left: origin = CGPoint(x: bounds.minX, y: bounds.midY - subviewSize.height / 2)
            case .right: origin = CGPoint(x: bounds.maxX - subviewSize.width, y: bounds.midY - subviewSize.height / 2)
            }
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(subviewSize))
        }
    }
}

/// Marks a child of `FlowBarCardStack` that should stretch to the card's width instead of setting it
/// (footers with spacers, full-width code blocks).
struct FlowBarCardStretchesToWidthKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    func stretchesToCardWidth() -> some View {
        layoutValue(key: FlowBarCardStretchesToWidthKey.self, value: true)
    }
}

/// A vertical stack whose width hugs its content: a three-word answer gets a small card, a long one gets the
/// maximum width. Children marked `stretchesToCardWidth()` take whatever width the others settled on.
struct FlowBarCardStack: Layout {
    var maximumWidth: CGFloat
    /// A floor so a three-word reply still has room for its footer without crowding it.
    var minimumWidth: CGFloat = 0
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cardWidth = settledWidth(proposal: proposal, subviews: subviews)
        let childHeights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height }
        let totalHeight = childHeights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: cardWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cardWidth = bounds.width
        var nextTop = bounds.minY
        for subview in subviews {
            let childSize = subview.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: nextTop), anchor: .topLeading, proposal: ProposedViewSize(width: cardWidth, height: childSize.height))
            nextTop += childSize.height + spacing
        }
    }

    private func settledWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let availableWidth = min(proposal.width ?? maximumWidth, maximumWidth)
        var widestContent: CGFloat = 0
        for subview in subviews {
            if subview[FlowBarCardStretchesToWidthKey.self] {
                widestContent = max(widestContent, subview.sizeThatFits(.unspecified).width)
            } else {
                widestContent = max(widestContent, subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil)).width)
            }
        }
        return min(max(widestContent, minimumWidth), availableWidth)
    }
}

/// Caps the size proposed to its child without making the child greedy (unlike `.frame(maxWidth:)`).
struct AmbientProposalLimit: Layout {
    var maximumWidth: CGFloat = .infinity
    var maximumHeight: CGFloat = .infinity

    private func limitedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maximumWidth, maximumWidth), height: min(proposal.height ?? maximumHeight, maximumHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(limitedProposal(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
