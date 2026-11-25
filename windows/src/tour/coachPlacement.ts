import type { DockEdge, LogicalRect } from '../host/contract';

// Where the tour's coach card sits, ported from AmbientTourCoachCorner in AmbientTourPanelController.swift, in
// top-left-origin, y-down logical desktop pixels.

export type CoachCorner = 'topLeading' | 'topTrailing' | 'bottomTrailing';

/** Transparent room around the card for its shadow. */
export const coachCardMargin = 28;
/** Gap between the card and the edges of the usable screen. */
export const coachInsetFromScreenEdge = 14;
export const coachCardWidth = 340;

/**
 * The corner farthest from wherever the bar and its reply card grow. The bar's cards grow from the middle of its edge,
 * so any corner on the opposite side of the screen is clear of them.
 */
export function coachCornerAwayFromBar(barEdge: DockEdge): CoachCorner {
  switch (barEdge) {
    case 'bottom':
    case 'left':
      return 'topTrailing';
    case 'top':
      return 'bottomTrailing';
    case 'right':
      return 'topLeading';
  }
}

export function isTopCorner(corner: CoachCorner): boolean {
  return corner !== 'bottomTrailing';
}

/**
 * The coach window's frame for `corner` of `workArea`, with the card itself `inset` from the screen edges and
 * `cardMargin` of transparent room for its shadow between the card and the window edge.
 */
export function coachWindowFrame(corner: CoachCorner, windowSize: { width: number; height: number }, cardMargin: number, inset: number, workArea: LogicalRect): LogicalRect {
  const windowLeft =
    corner === 'topLeading' ? workArea.x + inset - cardMargin : workArea.x + workArea.width - inset + cardMargin - windowSize.width;
  const windowTop = isTopCorner(corner) ? workArea.y + inset - cardMargin : workArea.y + workArea.height - inset + cardMargin - windowSize.height;
  return { x: windowLeft, y: windowTop, width: windowSize.width, height: windowSize.height };
}
