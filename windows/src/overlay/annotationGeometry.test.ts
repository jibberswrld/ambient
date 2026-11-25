import { describe, expect, it } from 'vitest';
import type { AnnotationInk, AnnotationShape, ScreenAnnotation } from '../host/contract';
import {
  annotationBounds,
  annotationInkColor,
  annotationPathData,
  captionCenter,
  captionCenters,
  captionHalfSize,
  captionPlaces,
  scaleAnnotationToView,
} from './annotationGeometry';

// Ported from Packages/AmbientKit/Tests/AmbientUITests/AnnotationOverlayTests.swift. The Swift snapshot tests render
// PNGs; here the same drawings are checked through the geometry the overlay draws them with.

function annotation(shape: AnnotationShape, text: string | null = null, ink: AnnotationInk = 'ember', isFilled = false): ScreenAnnotation {
  return { shape, text, ink, isFilled };
}

/** Every number in an SVG path string, in order. */
function numbersInPath(pathData: string): number[] {
  return (pathData.match(/-?\d+(\.\d+)?/g) ?? []).map(Number);
}

describe('captions', () => {
  it('stay on the display', () => {
    const size = { width: 800, height: 500 };
    const nearCorner = captionCenter({ kind: 'circle', center: { x: 790, y: 490 }, radius: 20 }, 'Click the Share button', true, size);
    // A caption with no room below its shape goes above it.
    expect(nearCorner.y).toBeLessThan(470);
    expect(nearCorner.x).toBeLessThanOrEqual(800 - (22 * 6.9) / 2);
    const arrowCaption = captionCenter({ kind: 'arrow', tail: { x: 300, y: 300 }, tip: { x: 400, y: 300 } }, 'Here', false, size);
    // An arrow's caption sits beyond its tail, away from the target.
    expect(arrowCaption.x).toBeLessThan(300);
  });

  it('size to their words and never exceed half the display', () => {
    expect(captionHalfSize('Here', false, { width: 800, height: 500 })).toEqual({ width: (4 * 6.9 + 22) / 2, height: 14 });
    expect(captionHalfSize('Here', true, { width: 800, height: 500 })).toEqual({ width: (4 * 6.9 + 46) / 2, height: 14 });
    expect(captionHalfSize('x'.repeat(400), false, { width: 300, height: 500 }).width).toBe(150);
    // An emoji is one character, as Swift counts it.
    expect(captionHalfSize('👍🏽', false, { width: 800, height: 500 }).width).toBe((6.9 + 22) / 2);
  });

  it('go below a shape, or above when there is no room below', () => {
    const size = { width: 800, height: 500 };
    const halfSize = { width: 40, height: 14 };
    const centre = { x: 400, y: 250 };
    const boxPlaces = captionPlaces({ kind: 'box', x: 100, y: 100, width: 200, height: 50 }, halfSize, centre, size);
    expect(boxPlaces).toEqual([
      { x: 200, y: 150 + 10 + 14 },
      { x: 200, y: 100 - 10 - 14 },
    ]);
    const lowBoxPlaces = captionPlaces({ kind: 'box', x: 100, y: 440, width: 200, height: 50 }, halfSize, centre, size);
    expect(lowBoxPlaces[0].y).toBe(440 - 10 - 14);
    expect(captionPlaces({ kind: 'label', at: { x: 2, y: 2 } }, halfSize, centre, size)).toEqual([{ x: 46, y: 20 }]);
  });

  it('do not cover each other', () => {
    const size = { width: 800, height: 500 };
    const centres = captionCenters(
      [
        annotation({ kind: 'label', at: { x: 300, y: 200 } }, 'First'),
        annotation({ kind: 'box', x: 250, y: 140, width: 100, height: 30 }, 'Second'),
      ],
      size,
    );
    // The box's first choice (just below it) would sit on the label, so it takes its second, above.
    expect(centres[1]).toEqual({ x: 300, y: 140 - 10 - 14 });
  });
});

describe('every shape renders', () => {
  const size = { width: 900, height: 560 };
  const annotations: ScreenAnnotation[] = [
    annotation({ kind: 'box', x: 610, y: 60, width: 150, height: 36 }, 'Click Share'),
    annotation({ kind: 'arrow', tail: { x: 330, y: 330 }, tip: { x: 470, y: 248 } }, 'Then pick a person'),
    annotation({ kind: 'circle', center: { x: 160, y: 420 }, radius: 30 }, 'Send'),
    annotation({ kind: 'underline', from: { x: 560, y: 430 }, to: { x: 760, y: 430 } }),
    annotation({ kind: 'label', at: { x: 660, y: 500 } }, 'Link settings live here'),
    annotation(
      { kind: 'path', points: [{ x: 60, y: 250 }, { x: 60, y: 90 }, { x: 260, y: 250 }], isClosed: true },
      'Right triangle',
      'red',
      true,
    ),
    annotation({ kind: 'path', points: [{ x: 60, y: 232 }, { x: 78, y: 232 }, { x: 78, y: 250 }], isClosed: false }, null, 'white'),
  ];

  it('draws a stroke for every shape but the label', () => {
    for (const eachAnnotation of annotations) {
      const pathData = annotationPathData(eachAnnotation.shape);
      if (eachAnnotation.shape.kind === 'label') expect(pathData).toBe('');
      else expect(pathData.startsWith('M ')).toBe(true);
      expect(pathData).not.toContain('NaN');
    }
  });

  it('places a caption on the display for every annotation with text, and none for the rest', () => {
    const centres = captionCenters(annotations, size);
    expect(centres).toHaveLength(annotations.length);
    annotations.forEach((eachAnnotation, annotationIndex) => {
      const centre = centres[annotationIndex];
      if (eachAnnotation.text === null) {
        expect(centre).toBeNull();
        return;
      }
      expect(centre).not.toBeNull();
      expect(centre!.x).toBeGreaterThan(0);
      expect(centre!.x).toBeLessThan(size.width);
      expect(centre!.y).toBeGreaterThan(0);
      expect(centre!.y).toBeLessThan(size.height);
    });
  });
});

describe('a sketch', () => {
  // The drawing the live app produced for "show me how to draw a right triangle", stroke by stroke.
  it('puts captions beside their strokes, outside the figure', () => {
    const size = { width: 900, height: 560 };
    const corner = { x: 300, y: 430 };
    const top = { x: 300, y: 150 };
    const end = { x: 600, y: 430 };
    const annotations = [
      annotation({ kind: 'path', points: [corner, end], isClosed: false }, 'Draw a horizontal base', 'yellow'),
      annotation({ kind: 'path', points: [corner, top], isClosed: false }, 'Draw a vertical side', 'blue'),
      annotation({ kind: 'path', points: [top, end], isClosed: false }, 'Connect the ends', 'green'),
      annotation({ kind: 'path', points: [{ x: 300, y: 405 }, { x: 325, y: 405 }, { x: 325, y: 430 }], isClosed: false }, null, 'white'),
    ];
    const centres = captionCenters(annotations, size).filter((centre) => centre !== null);
    expect(centres).toHaveLength(3);
    // The base is named below itself, outside the triangle.
    expect(centres[0].y).toBeGreaterThan(430);
    // The vertical side is named to its left, outside the triangle.
    expect(centres[1].x).toBeLessThan(300);
    // The hypotenuse is named on its outer side.
    expect(centres[2].x).toBeGreaterThan(450);
    expect(centres[2].y).toBeLessThan(290);
  });
});

describe('annotationPathData', () => {
  it('draws an underline as one line', () => {
    expect(annotationPathData({ kind: 'underline', from: { x: 10, y: 20 }, to: { x: 110, y: 20.5 } })).toBe('M 10 20 L 110 20.5');
  });

  it('draws a path as a polyline, closed with Z when asked', () => {
    const points = [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }];
    expect(annotationPathData({ kind: 'path', points, isClosed: false })).toBe('M 0 0 L 10 0 L 10 10');
    expect(annotationPathData({ kind: 'path', points, isClosed: true })).toBe('M 0 0 L 10 0 L 10 10 Z');
    expect(annotationPathData({ kind: 'path', points: [], isClosed: true })).toBe('');
  });

  it('draws a box as a rounded rectangle with 7 pixel corners', () => {
    expect(annotationPathData({ kind: 'box', x: 10, y: 20, width: 100, height: 40 })).toBe(
      'M 17 20 L 103 20 A 7 7 0 0 1 110 27 L 110 53 A 7 7 0 0 1 103 60 L 17 60 A 7 7 0 0 1 10 53 L 10 27 A 7 7 0 0 1 17 20 Z',
    );
    // A box too small for its corners gets corners of half its side.
    expect(annotationPathData({ kind: 'box', x: 0, y: 0, width: 8, height: 40 })).toContain('A 4 4 0 0 1');
  });

  it('draws a circle as an open arc from -130 degrees that overshoots to 246 degrees', () => {
    const pathData = annotationPathData({ kind: 'circle', center: { x: 100, y: 100 }, radius: 50 });
    const arcCommands = pathData.match(/A /g) ?? [];
    expect(arcCommands).toHaveLength(4);
    expect(pathData).not.toContain('Z');
    const numbers = numbersInPath(pathData);
    const startAngle = (-130 * Math.PI) / 180;
    const endAngle = (246 * Math.PI) / 180;
    // Starts at the top-left.
    expect(numbers[0]).toBeCloseTo(100 + Math.cos(startAngle) * 50, 2);
    expect(numbers[1]).toBeCloseTo(100 + Math.sin(startAngle) * 50, 2);
    expect(numbers[0]).toBeLessThan(100);
    expect(numbers[1]).toBeLessThan(100);
    // Ends a little past where it started.
    expect(numbers[numbers.length - 2]).toBeCloseTo(100 + Math.cos(endAngle) * 50, 2);
    expect(numbers[numbers.length - 1]).toBeCloseTo(100 + Math.sin(endAngle) * 50, 2);
  });

  it('draws an arrow as a bowed curve with two head strokes from the tip', () => {
    const pathData = annotationPathData({ kind: 'arrow', tail: { x: 0, y: 0 }, tip: { x: 100, y: 0 } });
    // Length 100: the bow is 14 pixels, to the arrow's right of travel (downward on screen for a rightward arrow).
    expect(pathData.startsWith('M 0 0 Q 50 14 100 0 M 100 0 L ')).toBe(true);
    expect(pathData.match(/M 100 0 L /g)).toHaveLength(2);
    // The path ends "M 100 0 L firstX firstY M 100 0 L secondX secondY".
    const [, , firstHeadEndX, , , , secondHeadEndX] = numbersInPath(pathData).slice(-8);
    // Both head strokes point back toward the tail.
    expect(firstHeadEndX).toBeLessThan(100);
    expect(secondHeadEndX).toBeLessThan(100);
  });

  it('draws nothing for a label', () => {
    expect(annotationPathData({ kind: 'label', at: { x: 5, y: 5 } })).toBe('');
  });
});

describe('annotationBounds', () => {
  it('bounds every shape', () => {
    expect(annotationBounds({ kind: 'box', x: 10, y: 20, width: 30, height: 40 })).toEqual({ x: 10, y: 20, width: 30, height: 40 });
    expect(annotationBounds({ kind: 'circle', center: { x: 100, y: 100 }, radius: 30 })).toEqual({ x: 70, y: 70, width: 60, height: 60 });
    expect(annotationBounds({ kind: 'underline', from: { x: 560, y: 430 }, to: { x: 760, y: 430 } })).toEqual({ x: 560, y: 430, width: 200, height: 0 });
    expect(annotationBounds({ kind: 'path', points: [{ x: 60, y: 250 }, { x: 60, y: 90 }, { x: 260, y: 250 }], isClosed: true })).toEqual({
      x: 60,
      y: 90,
      width: 200,
      height: 160,
    });
    expect(annotationBounds({ kind: 'label', at: { x: 5, y: 5 } })).toBeNull();
  });

  it('bounds an arrow by its curve, not its control point', () => {
    const bounds = annotationBounds({ kind: 'arrow', tail: { x: 0, y: 0 }, tip: { x: 1000, y: 0 } })!;
    // The control point is the full 26 pixel bow below the line; the quadratic curve itself reaches half of that.
    expect(bounds.y + bounds.height).toBeCloseTo(13, 5);
    expect(bounds.x).toBe(0);
    expect(bounds.x + bounds.width).toBe(1000);
    // The head strokes rise above the line.
    expect(bounds.y).toBeLessThan(0);
  });
});

describe('scaleAnnotationToView', () => {
  it('maps capture pixels to view pixels', () => {
    const scaled = scaleAnnotationToView(annotation({ kind: 'box', x: 100, y: 50, width: 200, height: 40 }, 'Hi', 'blue', true), 0.5, 0.25);
    expect(scaled).toEqual(annotation({ kind: 'box', x: 50, y: 12.5, width: 100, height: 10 }, 'Hi', 'blue', true));
    expect(scaleAnnotationToView(annotation({ kind: 'arrow', tail: { x: 10, y: 20 }, tip: { x: 30, y: 40 } }), 2, 3).shape).toEqual({
      kind: 'arrow',
      tail: { x: 20, y: 60 },
      tip: { x: 60, y: 120 },
    });
    expect(scaleAnnotationToView(annotation({ kind: 'underline', from: { x: 1, y: 2 }, to: { x: 3, y: 4 } }), 2, 2).shape).toEqual({
      kind: 'underline',
      from: { x: 2, y: 4 },
      to: { x: 6, y: 8 },
    });
    expect(scaleAnnotationToView(annotation({ kind: 'path', points: [{ x: 1, y: 1 }], isClosed: true }), 2, 4).shape).toEqual({
      kind: 'path',
      points: [{ x: 2, y: 4 }],
      isClosed: true,
    });
    expect(scaleAnnotationToView(annotation({ kind: 'label', at: { x: 10, y: 10 } }), 0.5, 0.5).shape).toEqual({ kind: 'label', at: { x: 5, y: 5 } });
  });

  it('scales a radius by the mean of the two scales', () => {
    expect(scaleAnnotationToView(annotation({ kind: 'circle', center: { x: 100, y: 100 }, radius: 40 }), 0.5, 1).shape).toEqual({
      kind: 'circle',
      center: { x: 50, y: 100 },
      radius: 30,
    });
  });
});

describe('annotationInkColor', () => {
  it('matches the Swift ink colours', () => {
    expect(annotationInkColor('ember')).toBe('rgb(255, 149, 74)');
    expect(annotationInkColor('red')).toBe('rgb(255, 69, 59)');
    expect(annotationInkColor('white')).toBe('rgb(255, 255, 255)');
    expect(annotationInkColor('black')).toBe('rgb(20, 20, 20)');
    const allInks: AnnotationInk[] = ['ember', 'red', 'yellow', 'green', 'blue', 'purple', 'white', 'black'];
    expect(new Set(allInks.map(annotationInkColor)).size).toBe(allInks.length);
  });
});
