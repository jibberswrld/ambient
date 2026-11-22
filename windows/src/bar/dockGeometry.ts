// The arithmetic of docking the bar to a screen edge, kept free of Tauri and the DOM so it can be tested.
//
// Ported from `FlowBarDockGeometry` in Packages/AmbientKit/Sources/AmbientUI/FlowBar/FlowBarDocking.swift.
// The one deliberate difference is the coordinate space. AppKit puts the origin at the bottom-left with y growing
// upward; Windows (and this file) uses logical desktop pixels with the origin at the TOP-left and y growing DOWNWARD.
// So the bottom edge of a work area is at `workArea.y + workArea.height`, the top edge at `workArea.y`, and on the left
// and right edges `positionAlongEdge` 0 is the TOP end (as `BarPlacement` in contract.ts says), 1 the bottom end.

import type { BarPlacement, DockEdge, LogicalRect } from '../host/contract';

export interface ScreenPoint {
  x: number;
  y: number;
}

/** Pointer velocity in logical pixels per second. */
export interface PointerVelocity {
  x: number;
  y: number;
}

export interface SurfaceSize {
  width: number;
  height: number;
}

/** Transparent window space around the bar's glass, so its shadow and glow are not clipped by the window. */
export interface SurfaceMargins {
  /** Between the glass and the screen edge the bar is docked to. */
  edgeSide: number;
  /** On each of the other three sides. */
  otherSides: number;
}

/** Within this distance of an edge's centre, the bar snaps to the exact centre. */
export const centreSnapDistance = 28;

/** On the left and right edges the resting bar stands upright and its content reflows into a column. */
export function isVerticalEdge(edge: DockEdge): boolean {
  return edge === 'left' || edge === 'right';
}

/** The edge of `workArea` closest to `point`. Points outside the work area are clamped into it first. */
export function nearestEdge(point: ScreenPoint, workArea: LogicalRect): DockEdge {
  const clampedPoint = clampPointIntoRect(point, workArea);
  const distanceToEachEdge: [DockEdge, number][] = [
    ['bottom', bottomOf(workArea) - clampedPoint.y],
    ['top', clampedPoint.y - workArea.y],
    ['left', clampedPoint.x - workArea.x],
    ['right', rightOf(workArea) - clampedPoint.x],
  ];
  // Only a strictly smaller distance replaces the current best, so ties resolve bottom, top, left, right (the same
  // order Swift's `min(by:)` gives, which keeps the first of equal elements).
  let closestEdgeAndDistance = distanceToEachEdge[0];
  for (const edgeAndDistance of distanceToEachEdge) {
    if (edgeAndDistance[1] < closestEdgeAndDistance[1]) closestEdgeAndDistance = edgeAndDistance;
  }
  return closestEdgeAndDistance[0];
}

/**
 * The fraction along `edge` that `point` corresponds to, snapping to 0.5 near the centre.
 * `endMargin` keeps the bar's centre this far from either end, so the resting bar never hangs off the screen.
 */
export function positionAlongEdge(point: ScreenPoint, edge: DockEdge, workArea: LogicalRect, endMargin: number): number {
  const usableRange = usableRangeAlongEdge(edge, workArea, endMargin);
  const coordinateAlongEdge = isVerticalEdge(edge) ? point.y : point.x;
  const centreOfEdge = (usableRange.lowerBound + usableRange.upperBound) / 2;
  if (Math.abs(coordinateAlongEdge - centreOfEdge) <= centreSnapDistance) return 0.5;
  const usableLength = usableRange.upperBound - usableRange.lowerBound;
  if (!(usableLength > 0)) return 0.5;
  const fraction = (coordinateAlongEdge - usableRange.lowerBound) / usableLength;
  return clampNumber(fraction, 0, 1);
}

/** The point where the middle of the bar's edge-facing side sits, `insetFromEdge` inside the work area. */
export function anchorPoint(
  edge: DockEdge,
  positionAlongEdge: number,
  workArea: LogicalRect,
  endMargin: number,
  insetFromEdge: number,
): ScreenPoint {
  const usableRange = usableRangeAlongEdge(edge, workArea, endMargin);
  const clampedFraction = clampNumber(positionAlongEdge, 0, 1);
  const coordinateAlongEdge = usableRange.lowerBound + (usableRange.upperBound - usableRange.lowerBound) * clampedFraction;
  switch (edge) {
    case 'bottom':
      return { x: coordinateAlongEdge, y: bottomOf(workArea) - insetFromEdge };
    case 'top':
      return { x: coordinateAlongEdge, y: workArea.y + insetFromEdge };
    case 'left':
      return { x: workArea.x + insetFromEdge, y: coordinateAlongEdge };
    case 'right':
      return { x: rightOf(workArea) - insetFromEdge, y: coordinateAlongEdge };
  }
}

/**
 * Where a throw would come to rest: the release point carried forward by the pointer's velocity, decaying the way
 * scrolling does. A flick toward an edge lands on that edge even if released nearer another.
 * `velocity` is in logical pixels per second.
 */
export function projectedRestingPoint(releasePoint: ScreenPoint, velocity: PointerVelocity, decelerationRate = 0.99): ScreenPoint {
  const projectionFactor = decelerationRate / (1 - decelerationRate) / 1000;
  return { x: releasePoint.x + velocity.x * projectionFactor, y: releasePoint.y + velocity.y * projectionFactor };
}

/**
 * The bar window's rectangle. The glass surface (`surfaceSize`) is placed so the middle of its edge-facing side sits on
 * `anchorPoint` and the rest grows away from the edge; the window adds `margins.edgeSide` of transparent space between
 * the glass and the edge, and `margins.otherSides` on the other three sides.
 *
 * Along the edge the window is clamped to stay inside the work area, so a bar parked near a corner slides inward rather
 * than hanging off the screen (Swift's `panelFrame` does the same). Across the edge it is never moved: the anchor alone
 * decides how far the bar sits from its edge, so the clamp can never push the bar off the edge it is docked to.
 */
export function windowFrameForSurface(
  anchorPoint: ScreenPoint,
  edge: DockEdge,
  surfaceSize: SurfaceSize,
  margins: SurfaceMargins,
  workArea: LogicalRect,
): LogicalRect {
  const windowWidth = isVerticalEdge(edge)
    ? surfaceSize.width + margins.edgeSide + margins.otherSides
    : surfaceSize.width + margins.otherSides * 2;
  const windowHeight = isVerticalEdge(edge)
    ? surfaceSize.height + margins.otherSides * 2
    : surfaceSize.height + margins.edgeSide + margins.otherSides;

  let windowLeft: number;
  let windowTop: number;
  switch (edge) {
    case 'bottom':
      // The glass's bottom side sits on the anchor; the edge margin hangs below it, toward the screen edge.
      windowLeft = anchorPoint.x - surfaceSize.width / 2 - margins.otherSides;
      windowTop = anchorPoint.y + margins.edgeSide - windowHeight;
      break;
    case 'top':
      windowLeft = anchorPoint.x - surfaceSize.width / 2 - margins.otherSides;
      windowTop = anchorPoint.y - margins.edgeSide;
      break;
    case 'left':
      windowLeft = anchorPoint.x - margins.edgeSide;
      windowTop = anchorPoint.y - surfaceSize.height / 2 - margins.otherSides;
      break;
    case 'right':
      windowLeft = anchorPoint.x + margins.edgeSide - windowWidth;
      windowTop = anchorPoint.y - surfaceSize.height / 2 - margins.otherSides;
      break;
  }

  if (isVerticalEdge(edge)) {
    windowTop = clampNumber(windowTop, workArea.y, Math.max(workArea.y, bottomOf(workArea) - windowHeight));
  } else {
    windowLeft = clampNumber(windowLeft, workArea.x, Math.max(workArea.x, rightOf(workArea) - windowWidth));
  }
  return { x: windowLeft, y: windowTop, width: windowWidth, height: windowHeight };
}

/**
 * Picks the display for a saved placement: the one with the saved identifier, else the primary display (index
 * `primaryDisplayIndex`, clamped into range). Returns null only when there are no displays.
 */
export function indexOfDisplayForPlacement(
  placement: BarPlacement,
  displayIdentifiers: string[],
  primaryDisplayIndex: number,
): number | null {
  if (displayIdentifiers.length === 0) return null;
  if (placement.displayIdentifier !== null) {
    const savedDisplayIndex = displayIdentifiers.indexOf(placement.displayIdentifier);
    if (savedDisplayIndex >= 0) return savedDisplayIndex;
  }
  return clampNumber(primaryDisplayIndex, 0, displayIdentifiers.length - 1);
}

/** The display under `point`, or the nearest one when the point falls in a gap between displays. */
export function indexOfDisplayContaining(point: ScreenPoint, displayBounds: LogicalRect[]): number | null {
  const containingDisplayIndex = displayBounds.findIndex((bounds) => rectContainsPoint(bounds, point));
  if (containingDisplayIndex >= 0) return containingDisplayIndex;
  if (displayBounds.length === 0) return null;
  let nearestDisplayIndex = 0;
  for (let displayIndex = 1; displayIndex < displayBounds.length; displayIndex += 1) {
    if (distanceFromPointToRect(point, displayBounds[displayIndex]) < distanceFromPointToRect(point, displayBounds[nearestDisplayIndex])) {
      nearestDisplayIndex = displayIndex;
    }
  }
  return nearestDisplayIndex;
}

// Helpers -------------------------------------------------------------------------------------------------------------

interface CoordinateRange {
  lowerBound: number;
  upperBound: number;
}

/** The stretch of the edge the bar's centre may occupy. Collapses to the middle when the edge is too short for the margins. */
function usableRangeAlongEdge(edge: DockEdge, workArea: LogicalRect, endMargin: number): CoordinateRange {
  const startOfEdge = isVerticalEdge(edge) ? workArea.y : workArea.x;
  const endOfEdge = isVerticalEdge(edge) ? bottomOf(workArea) : rightOf(workArea);
  const lowerBound = startOfEdge + endMargin;
  const upperBound = endOfEdge - endMargin;
  if (lowerBound > upperBound) {
    const middleOfEdge = (startOfEdge + endOfEdge) / 2;
    return { lowerBound: middleOfEdge, upperBound: middleOfEdge };
  }
  return { lowerBound, upperBound };
}

function rightOf(rect: LogicalRect): number {
  return rect.x + rect.width;
}

function bottomOf(rect: LogicalRect): number {
  return rect.y + rect.height;
}

function clampNumber(value: number, lowest: number, highest: number): number {
  return Math.min(Math.max(value, lowest), highest);
}

function clampPointIntoRect(point: ScreenPoint, rect: LogicalRect): ScreenPoint {
  return { x: clampNumber(point.x, rect.x, rightOf(rect)), y: clampNumber(point.y, rect.y, bottomOf(rect)) };
}

/** Half-open like `CGRect.contains`: a point on the shared border of two side-by-side displays belongs to the second. */
function rectContainsPoint(rect: LogicalRect, point: ScreenPoint): boolean {
  return point.x >= rect.x && point.x < rightOf(rect) && point.y >= rect.y && point.y < bottomOf(rect);
}

function distanceFromPointToRect(point: ScreenPoint, rect: LogicalRect): number {
  const horizontalGap = Math.max(rect.x - point.x, 0, point.x - rightOf(rect));
  const verticalGap = Math.max(rect.y - point.y, 0, point.y - bottomOf(rect));
  return Math.hypot(horizontalGap, verticalGap);
}
