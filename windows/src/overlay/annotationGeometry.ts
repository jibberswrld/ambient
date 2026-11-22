// The geometry of what Ambient draws on the screen: each shape's stroke as an SVG path, and where its caption goes.
//
// Ported from `AmbientAnnotationGeometry` in Packages/AmbientKit/Sources/AmbientUI/Pointer/AmbientAnnotationOverlay.swift.
// SwiftUI draws that overlay with the origin at the top-left and y growing downward, which is also SVG's space, so
// every formula carries over unchanged. Coordinates are in the overlay's own pixels.

import type { AnnotationInk, AnnotationShape, CapturePoint, ScreenAnnotation } from '../host/contract';

export interface OverlayPoint {
  x: number;
  y: number;
}

export interface OverlaySize {
  width: number;
  height: number;
}

export interface OverlayRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** The corner radius of a box annotation. */
const boxCornerRadius = 7;

/** The space between a shape and its caption. */
const captionGapFromShape = 10;

/** How close a caption may come to the edge of the display. */
const captionMarginFromDisplayEdge = 6;

/** Captions keep this much clear space from each other on every side. */
const captionClearance = 4;

// Stroke paths --------------------------------------------------------------------------------------------------------

/** The arrow's curve and head, shared by the path and its bounds so both describe exactly the same stroke. */
interface ArrowGeometry {
  tail: OverlayPoint;
  control: OverlayPoint;
  tip: OverlayPoint;
  headEnds: [OverlayPoint, OverlayPoint];
}

function arrowGeometry(tail: CapturePoint, tip: CapturePoint): ArrowGeometry {
  const horizontalRun = tip.x - tail.x;
  const verticalRun = tip.y - tail.y;
  const length = Math.max(1, Math.hypot(horizontalRun, verticalRun));
  // A slight bow, so it reads as drawn rather than ruled.
  const bow = Math.min(26, length * 0.14);
  const control = {
    x: (tail.x + tip.x) / 2 - (verticalRun / length) * bow,
    y: (tail.y + tip.y) / 2 + (horizontalRun / length) * bow,
  };
  // The head follows the curve's direction where it lands.
  const heading = Math.atan2(tip.y - control.y, tip.x - control.x);
  const headLength = Math.min(17, Math.max(9, length * 0.3));
  const headEnds = [-1, 1].map((side) => {
    const headStrokeAngle = heading + Math.PI + side * 0.46;
    return { x: tip.x + Math.cos(headStrokeAngle) * headLength, y: tip.y + Math.sin(headStrokeAngle) * headLength };
  }) as [OverlayPoint, OverlayPoint];
  return { tail, control, tip, headEnds };
}

/** Starts at the top-left and overshoots slightly, the way a hand closes a circle. */
const circleStartDegrees = -130;
const circleEndDegrees = 246;

/**
 * The SVG path `d` for a shape's stroke, the same figure as the Swift `Path`. A label has no stroke and gives "".
 *
 * The circle is an open arc sweeping 376 degrees. One SVG arc command cannot sweep 360 degrees or more, so it is drawn
 * as four 94-degree arcs, each with the large-arc flag off and the sweep flag on (increasing angle, which on a y-down
 * screen is clockwise, matching SwiftUI's `clockwise: false` in its flipped space).
 */
export function annotationPathData(shape: AnnotationShape): string {
  switch (shape.kind) {
    case 'arrow': {
      const arrow = arrowGeometry(shape.tail, shape.tip);
      return [
        `M ${formatPoint(arrow.tail)} Q ${formatPoint(arrow.control)} ${formatPoint(arrow.tip)}`,
        ...arrow.headEnds.map((headEnd) => `M ${formatPoint(arrow.tip)} L ${formatPoint(headEnd)}`),
      ].join(' ');
    }
    case 'circle': {
      const numberOfArcSegments = 4;
      const degreesPerSegment = (circleEndDegrees - circleStartDegrees) / numberOfArcSegments;
      const radius = shape.radius;
      const commands = [`M ${formatPoint(pointOnCircle(shape.center, radius, circleStartDegrees))}`];
      for (let segmentIndex = 1; segmentIndex <= numberOfArcSegments; segmentIndex += 1) {
        const segmentEnd = pointOnCircle(shape.center, radius, circleStartDegrees + degreesPerSegment * segmentIndex);
        commands.push(`A ${formatNumber(radius)} ${formatNumber(radius)} 0 0 1 ${formatPoint(segmentEnd)}`);
      }
      return commands.join(' ');
    }
    case 'box':
      return roundedRectPathData(shape);
    case 'underline':
      return `M ${formatPoint(shape.from)} L ${formatPoint(shape.to)}`;
    case 'path': {
      if (shape.points.length === 0) return '';
      const [firstPoint, ...remainingPoints] = shape.points;
      const commands = [`M ${formatPoint(firstPoint)}`, ...remainingPoints.map((point) => `L ${formatPoint(point)}`)];
      if (shape.isClosed) commands.push('Z');
      return commands.join(' ');
    }
    case 'label':
      return '';
  }
}

/** A rounded rectangle traced clockwise from the end of the top-left corner, as `Path.addRoundedRect` draws it. */
function roundedRectPathData(rect: OverlayRect): string {
  // A corner can be at most half the side it sits on, the same clamp Core Graphics applies.
  const cornerRadius = Math.max(0, Math.min(boxCornerRadius, rect.width / 2, rect.height / 2));
  const left = rect.x;
  const top = rect.y;
  const right = rect.x + rect.width;
  const bottom = rect.y + rect.height;
  const corner = formatNumber(cornerRadius);
  return [
    `M ${formatNumber(left + cornerRadius)} ${formatNumber(top)}`,
    `L ${formatNumber(right - cornerRadius)} ${formatNumber(top)}`,
    `A ${corner} ${corner} 0 0 1 ${formatNumber(right)} ${formatNumber(top + cornerRadius)}`,
    `L ${formatNumber(right)} ${formatNumber(bottom - cornerRadius)}`,
    `A ${corner} ${corner} 0 0 1 ${formatNumber(right - cornerRadius)} ${formatNumber(bottom)}`,
    `L ${formatNumber(left + cornerRadius)} ${formatNumber(bottom)}`,
    `A ${corner} ${corner} 0 0 1 ${formatNumber(left)} ${formatNumber(bottom - cornerRadius)}`,
    `L ${formatNumber(left)} ${formatNumber(top + cornerRadius)}`,
    `A ${corner} ${corner} 0 0 1 ${formatNumber(left + cornerRadius)} ${formatNumber(top)}`,
    'Z',
  ].join(' ');
}

function pointOnCircle(center: CapturePoint, radius: number, angleInDegrees: number): OverlayPoint {
  const angleInRadians = (angleInDegrees * Math.PI) / 180;
  return { x: center.x + Math.cos(angleInRadians) * radius, y: center.y + Math.sin(angleInRadians) * radius };
}

/** Three decimals is far below a pixel and keeps the path strings short and stable in tests. */
function formatNumber(value: number): string {
  const rounded = Math.round(value * 1000) / 1000;
  // `Object.is` turns -0 into "0" so a path never contains "-0".
  return String(Object.is(rounded, -0) ? 0 : rounded);
}

function formatPoint(point: OverlayPoint): string {
  return `${formatNumber(point.x)} ${formatNumber(point.y)}`;
}

// Bounds --------------------------------------------------------------------------------------------------------------

/**
 * The tight bounding box of a shape's stroke, what Swift gets from `Path.boundingRect`; null for a label, which draws
 * nothing. For the arrow this is the exact box of the quadratic curve (its extremes found analytically, not its control
 * polygon, which would overstate the bow) together with the two head strokes.
 */
export function annotationBounds(shape: AnnotationShape): OverlayRect | null {
  switch (shape.kind) {
    case 'arrow': {
      const arrow = arrowGeometry(shape.tail, shape.tip);
      return boundsOfPoints([
        ...quadraticCurveExtremes(arrow.tail, arrow.control, arrow.tip),
        ...arrow.headEnds,
      ]);
    }
    case 'circle': {
      // The arc sweeps more than a full turn, so it covers the whole circle.
      const radius = Math.abs(shape.radius);
      return { x: shape.center.x - radius, y: shape.center.y - radius, width: radius * 2, height: radius * 2 };
    }
    case 'box':
      return { x: shape.x, y: shape.y, width: shape.width, height: shape.height };
    case 'underline':
      return boundsOfPoints([shape.from, shape.to]);
    case 'path':
      return shape.points.length === 0 ? null : boundsOfPoints(shape.points);
    case 'label':
      return null;
  }
}

/** The curve's end points plus, on each axis, the point where the curve turns back (if it does between them). */
function quadraticCurveExtremes(start: OverlayPoint, control: OverlayPoint, end: OverlayPoint): OverlayPoint[] {
  const extremes = [start, end];
  for (const axis of ['x', 'y'] as const) {
    const denominator = start[axis] - 2 * control[axis] + end[axis];
    if (denominator === 0) continue;
    const curveParameter = (start[axis] - control[axis]) / denominator;
    if (curveParameter > 0 && curveParameter < 1) extremes.push(pointOnQuadraticCurve(start, control, end, curveParameter));
  }
  return extremes;
}

function pointOnQuadraticCurve(start: OverlayPoint, control: OverlayPoint, end: OverlayPoint, curveParameter: number): OverlayPoint {
  const remaining = 1 - curveParameter;
  return {
    x: remaining * remaining * start.x + 2 * remaining * curveParameter * control.x + curveParameter * curveParameter * end.x,
    y: remaining * remaining * start.y + 2 * remaining * curveParameter * control.y + curveParameter * curveParameter * end.y,
  };
}

function boundsOfPoints(points: OverlayPoint[]): OverlayRect {
  const leftmost = Math.min(...points.map((point) => point.x));
  const topmost = Math.min(...points.map((point) => point.y));
  const rightmost = Math.max(...points.map((point) => point.x));
  const bottommost = Math.max(...points.map((point) => point.y));
  return { x: leftmost, y: topmost, width: rightmost - leftmost, height: bottommost - topmost };
}

// Captions ------------------------------------------------------------------------------------------------------------

/** Counts what a person sees as characters, like Swift's `String.count`, so an emoji is one character, not two. */
function visibleCharacterCount(text: string): number {
  return Array.from(new Intl.Segmenter().segment(text)).length;
}

/** Half the caption pill's size: wide enough for its words (and step number), never wider than half the display. */
export function captionHalfSize(text: string, hasStepNumber: boolean, size: OverlaySize): OverlaySize {
  // The caption face at 12.5 px averages a little under 7 pixels a character.
  return {
    width: Math.min(size.width / 2, (visibleCharacterCount(text) * 6.9 + (hasStepNumber ? 46 : 22)) / 2),
    height: 14,
  };
}

function hasCaption(annotation: ScreenAnnotation): boolean {
  return annotation.text !== null && annotation.text.length > 0;
}

/**
 * Where every caption sits, in order, null for an annotation without one. Each takes the first of its shape's places
 * that does not cover a caption placed before it.
 */
export function captionCenters(annotations: ScreenAnnotation[], size: OverlaySize): (OverlayPoint | null)[] {
  // The middle of everything drawn, weighted by corners: the bounding box's centre would sit exactly on the long side
  // of a right triangle and could not tell its inside from its outside.
  const corners: OverlayPoint[] = [];
  for (const annotation of annotations) {
    if (annotation.shape.kind === 'path') {
      corners.push(...annotation.shape.points);
    } else {
      const bounds = annotationBounds(annotation.shape);
      // Like `CGRect.isEmpty`, a box with no width or no height (a level underline) does not count.
      if (bounds !== null && bounds.width > 0 && bounds.height > 0) {
        corners.push({ x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 });
      }
    }
  }
  const figureCentre =
    corners.length === 0
      ? { x: size.width / 2, y: size.height / 2 }
      : {
          x: corners.reduce((sum, corner) => sum + corner.x, 0) / corners.length,
          y: corners.reduce((sum, corner) => sum + corner.y, 0) / corners.length,
        };
  const numbersSteps = annotations.filter(hasCaption).length > 1;
  const placedCaptionRects: OverlayRect[] = [];
  return annotations.map((annotation) => {
    if (annotation.text === null || annotation.text.length === 0) return null;
    const halfSize = captionHalfSize(annotation.text, numbersSteps, size);
    const captionRect = (captionCentre: OverlayPoint): OverlayRect => ({
      x: captionCentre.x - halfSize.width - captionClearance,
      y: captionCentre.y - halfSize.height - captionClearance,
      width: halfSize.width * 2 + captionClearance * 2,
      height: halfSize.height * 2 + captionClearance * 2,
    });
    const places = captionPlaces(annotation.shape, halfSize, figureCentre, size);
    const chosenPlace =
      places.find((place) => !placedCaptionRects.some((placedRect) => rectsIntersect(placedRect, captionRect(place)))) ?? places[0];
    placedCaptionRects.push(captionRect(chosenPlace));
    return chosenPlace;
  });
}

/** The best place for one caption, with nothing else on screen. */
export function captionCenter(shape: AnnotationShape, text: string, hasStepNumber: boolean, size: OverlaySize): OverlayPoint {
  return captionPlaces(shape, captionHalfSize(text, hasStepNumber, size), { x: size.width / 2, y: size.height / 2 }, size)[0];
}

/** Places for a caption just outside its shape, best first, each clamped so it stays on the display. */
export function captionPlaces(shape: AnnotationShape, halfSize: OverlaySize, figureCentre: OverlayPoint, size: OverlaySize): OverlayPoint[] {
  const halfHeight = halfSize.height;
  /** Below the shape, or above it when there is no room below; the other one is the second choice. */
  const belowThenAbove = (centreX: number, shapeTop: number, shapeBottom: number): OverlayPoint[] => {
    const below = { x: centreX, y: shapeBottom + captionGapFromShape + halfHeight };
    const above = { x: centreX, y: shapeTop - captionGapFromShape - halfHeight };
    return below.y + halfHeight > size.height ? [above, below] : [below, above];
  };

  let places: OverlayPoint[];
  switch (shape.kind) {
    case 'arrow': {
      // Beyond the tail, away from what the arrow points at.
      const length = Math.max(1, Math.hypot(shape.tail.x - shape.tip.x, shape.tail.y - shape.tip.y));
      const distanceBeyondTail = captionGapFromShape + halfHeight;
      places = [
        {
          x: shape.tail.x + ((shape.tail.x - shape.tip.x) / length) * distanceBeyondTail,
          y: shape.tail.y + ((shape.tail.y - shape.tip.y) / length) * distanceBeyondTail,
        },
      ];
      break;
    }
    case 'circle':
      places = belowThenAbove(shape.center.x, shape.center.y - shape.radius, shape.center.y + shape.radius);
      break;
    case 'box':
      places = belowThenAbove(shape.x + shape.width / 2, shape.y, shape.y + shape.height);
      break;
    case 'underline':
      places = belowThenAbove((shape.from.x + shape.to.x) / 2, Math.min(shape.from.y, shape.to.y) - 12, Math.max(shape.from.y, shape.to.y));
      break;
    case 'path': {
      if (shape.points.length === 2) {
        // A single stroke is named beside its middle, on the side facing away from the rest of the figure.
        const [strokeStart, strokeEnd] = shape.points;
        const middle = { x: (strokeStart.x + strokeEnd.x) / 2, y: (strokeStart.y + strokeEnd.y) / 2 };
        const length = Math.max(1, Math.hypot(strokeEnd.x - strokeStart.x, strokeEnd.y - strokeStart.y));
        const normal = { x: -(strokeEnd.y - strokeStart.y) / length, y: (strokeEnd.x - strokeStart.x) / length };
        // Far enough along the normal that the caption's rectangle clears the stroke.
        const distanceFromStroke = captionGapFromShape + Math.abs(normal.x) * halfSize.width + Math.abs(normal.y) * halfHeight;
        const sides = [1, -1].map((sideSign) => ({
          x: middle.x + normal.x * distanceFromStroke * sideSign,
          y: middle.y + normal.y * distanceFromStroke * sideSign,
        }));
        const distanceFromFigureCentre = (place: OverlayPoint) => Math.hypot(place.x - figureCentre.x, place.y - figureCentre.y);
        // Farthest from the figure first; a stable sort keeps the first side when both are equally far, like Swift.
        places = sides.sort((firstSide, secondSide) => distanceFromFigureCentre(secondSide) - distanceFromFigureCentre(firstSide));
      } else {
        const xValues = shape.points.map((point) => point.x);
        const yValues = shape.points.map((point) => point.y);
        const hasPoints = shape.points.length > 0;
        places = belowThenAbove(
          hasPoints ? (Math.min(...xValues) + Math.max(...xValues)) / 2 : 0,
          hasPoints ? Math.min(...yValues) : 0,
          hasPoints ? Math.max(...yValues) : 0,
        );
      }
      break;
    }
    case 'label':
      places = [shape.at];
      break;
  }
  return places.map((place) => ({
    x: Math.min(Math.max(place.x, halfSize.width + captionMarginFromDisplayEdge), size.width - halfSize.width - captionMarginFromDisplayEdge),
    y: Math.min(Math.max(place.y, halfHeight + captionMarginFromDisplayEdge), size.height - halfHeight - captionMarginFromDisplayEdge),
  }));
}

/** Like `CGRect.intersects`: rectangles that only touch along an edge do not intersect. */
function rectsIntersect(firstRect: OverlayRect, secondRect: OverlayRect): boolean {
  return (
    firstRect.x < secondRect.x + secondRect.width &&
    secondRect.x < firstRect.x + firstRect.width &&
    firstRect.y < secondRect.y + secondRect.height &&
    secondRect.y < firstRect.y + firstRect.height
  );
}

// Scaling and ink -----------------------------------------------------------------------------------------------------

/**
 * Maps an annotation from the pixels of the capture it was drawn on to the overlay view's pixels. A circle's radius
 * scales by the mean of the two scales, so a slightly non-uniform scale still gives a round circle near the right size.
 */
export function scaleAnnotationToView(annotation: ScreenAnnotation, scaleX: number, scaleY: number): ScreenAnnotation {
  const scalePoint = (point: CapturePoint): CapturePoint => ({ x: point.x * scaleX, y: point.y * scaleY });
  const shape = annotation.shape;
  let scaledShape: AnnotationShape;
  switch (shape.kind) {
    case 'arrow':
      scaledShape = { kind: 'arrow', tail: scalePoint(shape.tail), tip: scalePoint(shape.tip) };
      break;
    case 'circle':
      scaledShape = { kind: 'circle', center: scalePoint(shape.center), radius: (shape.radius * (scaleX + scaleY)) / 2 };
      break;
    case 'box':
      scaledShape = { kind: 'box', x: shape.x * scaleX, y: shape.y * scaleY, width: shape.width * scaleX, height: shape.height * scaleY };
      break;
    case 'underline':
      scaledShape = { kind: 'underline', from: scalePoint(shape.from), to: scalePoint(shape.to) };
      break;
    case 'path':
      scaledShape = { kind: 'path', points: shape.points.map(scalePoint), isClosed: shape.isClosed };
      break;
    case 'label':
      scaledShape = { kind: 'label', at: scalePoint(shape.at) };
      break;
  }
  return { ...annotation, shape: scaledShape };
}

/** The CSS colour of each ink, the Swift `Ink.color` values rounded to whole 0 to 255 channels. */
export function annotationInkColor(ink: AnnotationInk): string {
  switch (ink) {
    case 'ember':
      return 'rgb(255, 149, 74)';
    case 'red':
      return 'rgb(255, 69, 59)';
    case 'yellow':
      return 'rgb(255, 214, 10)';
    case 'green':
      return 'rgb(48, 209, 89)';
    case 'blue':
      return 'rgb(10, 133, 255)';
    case 'purple':
      return 'rgb(191, 89, 242)';
    case 'white':
      return 'rgb(255, 255, 255)';
    case 'black':
      return 'rgb(20, 20, 20)';
  }
}
