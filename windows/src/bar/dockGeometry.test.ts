import { describe, expect, it } from 'vitest';
import type { BarPlacement, DockEdge, LogicalRect } from '../host/contract';
import {
  anchorPoint,
  centreSnapDistance,
  indexOfDisplayContaining,
  indexOfDisplayForPlacement,
  nearestEdge,
  positionAlongEdge,
  projectedRestingPoint,
  windowFrameForSurface,
} from './dockGeometry';

// Ported from Packages/AmbientKit/Tests/AmbientUITests/FlowBarDockGeometryTests.swift. Every expectation is translated
// from AppKit's bottom-left, y-up space into Windows' top-left, y-down space: a Swift point (x, y) on the 945-tall
// screen becomes (x, 945 - y) here.

/** A 1512x908 work area above a 37-pixel taskbar at the bottom of a 1512x945 display. */
const workArea: LogicalRect = { x: 0, y: 0, width: 1512, height: 908 };
const workAreaCentreX = 756;
const workAreaCentreY = 454;
const allDockEdges: DockEdge[] = ['bottom', 'top', 'left', 'right'];

describe('nearestEdge', () => {
  it('picks the closest side', () => {
    expect(nearestEdge({ x: 700, y: 885 }, workArea)).toBe('bottom');
    expect(nearestEdge({ x: 700, y: 15 }, workArea)).toBe('top');
    expect(nearestEdge({ x: 20, y: 445 }, workArea)).toBe('left');
    expect(nearestEdge({ x: 1500, y: 445 }, workArea)).toBe('right');
  });

  it('clamps points outside the work area', () => {
    // Released over the taskbar (below the work area): lands on the bottom edge.
    expect(nearestEdge({ x: 700, y: 940 }, workArea)).toBe('bottom');
    // Released far off to the right of this display.
    expect(nearestEdge({ x: 2400, y: 445 }, workArea)).toBe('right');
  });

  it('resolves ties bottom, top, left, right', () => {
    const squareWorkArea: LogicalRect = { x: 0, y: 0, width: 100, height: 100 };
    expect(nearestEdge({ x: 50, y: 50 }, squareWorkArea)).toBe('bottom');
    // Equally near the top and the left: top wins.
    expect(nearestEdge({ x: 10, y: 10 }, squareWorkArea)).toBe('top');
    // Equally near the left and the right on a thin work area: left wins.
    expect(nearestEdge({ x: 5, y: 50 }, { x: 0, y: 0, width: 10, height: 100 })).toBe('left');
  });
});

describe('positionAlongEdge', () => {
  it('snaps to the centre', () => {
    expect(centreSnapDistance).toBe(28);
    expect(positionAlongEdge({ x: workAreaCentreX + 20, y: 885 }, 'bottom', workArea, 40)).toBe(0.5);
    expect(positionAlongEdge({ x: workAreaCentreX + 60, y: 885 }, 'bottom', workArea, 40)).toBeGreaterThan(0.5);
  });

  it('is clamped to the usable range', () => {
    expect(positionAlongEdge({ x: -300, y: 885 }, 'bottom', workArea, 40)).toBe(0);
    expect(positionAlongEdge({ x: 5000, y: 885 }, 'bottom', workArea, 40)).toBe(1);
  });

  it('measures vertical edges along y with 0 at the top end', () => {
    expect(positionAlongEdge({ x: 10, y: 0 + 40 }, 'left', workArea, 40)).toBeCloseTo(0, 4);
    expect(positionAlongEdge({ x: 10, y: 908 - 40 }, 'left', workArea, 40)).toBeCloseTo(1, 4);
  });

  it('treats an edge too short for its margins as all centre', () => {
    const tinyWorkArea: LogicalRect = { x: 0, y: 0, width: 60, height: 60 };
    expect(positionAlongEdge({ x: 0, y: 55 }, 'bottom', tinyWorkArea, 40)).toBe(0.5);
  });
});

describe('anchorPoint', () => {
  it('round-trips with positionAlongEdge on every edge', () => {
    for (const edge of allDockEdges) {
      const anchor = anchorPoint(edge, 0.27, workArea, 40, 8);
      expect(positionAlongEdge(anchor, edge, workArea, 40), `edge ${edge}`).toBeCloseTo(0.27, 4);
    }
  });

  it('sits inside the work area by the inset', () => {
    expect(anchorPoint('bottom', 0.5, workArea, 40, 8)).toEqual({ x: workAreaCentreX, y: 900 });
    expect(anchorPoint('top', 0.5, workArea, 40, 8)).toEqual({ x: workAreaCentreX, y: 8 });
    expect(anchorPoint('left', 0.5, workArea, 40, 8)).toEqual({ x: 8, y: workAreaCentreY });
    expect(anchorPoint('right', 0.5, workArea, 40, 8)).toEqual({ x: 1504, y: workAreaCentreY });
  });

  it('puts position 0 at the top end of a vertical edge', () => {
    expect(anchorPoint('left', 0, workArea, 40, 8)).toEqual({ x: 8, y: 40 });
    expect(anchorPoint('right', 1, workArea, 40, 8)).toEqual({ x: 1504, y: 868 });
  });

  it('honours a work area that does not start at the origin', () => {
    const secondDisplayWorkArea: LogicalRect = { x: 1512, y: -200, width: 1920, height: 1040 };
    expect(anchorPoint('bottom', 0.5, secondDisplayWorkArea, 40, 8)).toEqual({ x: 1512 + 960, y: -200 + 1040 - 8 });
    expect(anchorPoint('top', 0, secondDisplayWorkArea, 40, 8)).toEqual({ x: 1512 + 40, y: -200 + 8 });
  });
});

describe('projectedRestingPoint', () => {
  it('carries a flick toward the edge it was thrown at', () => {
    // Released nearer the bottom but flicked hard to the right.
    const releasePoint = { x: 1100, y: 745 };
    const projectedPoint = projectedRestingPoint(releasePoint, { x: 4000, y: 0 });
    expect(nearestEdge(releasePoint, workArea)).toBe('bottom');
    expect(nearestEdge(projectedPoint, workArea)).toBe('right');
  });

  it('stays put without velocity', () => {
    const releasePoint = { x: 300, y: 645 };
    expect(projectedRestingPoint(releasePoint, { x: 0, y: 0 })).toEqual(releasePoint);
  });
});

describe('windowFrameForSurface', () => {
  const horizontalSurface = { width: 360, height: 52 };
  const verticalSurface = { width: 52, height: 360 };
  const margins = { edgeSide: 8, otherSides: 24 };

  it('places the glass on the anchor for the bottom edge', () => {
    const windowFrame = windowFrameForSurface({ x: workAreaCentreX, y: 900 }, 'bottom', horizontalSurface, margins, workArea);
    expect(windowFrame).toEqual({ x: 552, y: 824, width: 408, height: 84 });
    // The glass's bottom side is on the anchor, with the edge margin below it reaching the work area's bottom.
    expect(windowFrame.y + windowFrame.height - margins.edgeSide).toBe(900);
    expect(windowFrame.y + windowFrame.height).toBe(908);
  });

  it('places the glass on the anchor for the top edge', () => {
    const windowFrame = windowFrameForSurface({ x: workAreaCentreX, y: 8 }, 'top', horizontalSurface, margins, workArea);
    expect(windowFrame).toEqual({ x: 552, y: 0, width: 408, height: 84 });
  });

  it('places the glass on the anchor for the left edge', () => {
    const windowFrame = windowFrameForSurface({ x: 8, y: workAreaCentreY }, 'left', verticalSurface, margins, workArea);
    expect(windowFrame).toEqual({ x: 0, y: 250, width: 84, height: 408 });
  });

  it('places the glass on the anchor for the right edge', () => {
    const windowFrame = windowFrameForSurface({ x: 1504, y: workAreaCentreY }, 'right', verticalSurface, margins, workArea);
    expect(windowFrame).toEqual({ x: 1428, y: 250, width: 84, height: 408 });
    expect(windowFrame.x + windowFrame.width).toBe(1512);
  });

  it('stays inside the work area near a corner', () => {
    const nearLeftEnd = windowFrameForSurface({ x: 40, y: 900 }, 'bottom', horizontalSurface, margins, workArea);
    expect(nearLeftEnd.x).toBe(0);
    expect(nearLeftEnd.y + nearLeftEnd.height).toBe(908);
    const nearBottomOfRightEdge = windowFrameForSurface({ x: 1504, y: 900 }, 'right', verticalSurface, margins, workArea);
    expect(nearBottomOfRightEdge.x + nearBottomOfRightEdge.width).toBe(1512);
    expect(nearBottomOfRightEdge.y + nearBottomOfRightEdge.height).toBe(908);
    const nearTopOfLeftEdge = windowFrameForSurface({ x: 8, y: 10 }, 'left', verticalSurface, margins, workArea);
    expect(nearTopOfLeftEdge.y).toBe(0);
    const nearRightEndOfTop = windowFrameForSurface({ x: 1500, y: 8 }, 'top', horizontalSurface, margins, workArea);
    expect(nearRightEndOfTop.x + nearRightEndOfTop.width).toBe(1512);
  });

  it('never moves the bar across its edge, only along it', () => {
    // Anchored right on the bottom edge: the transparent edge margin may extend past the work area, but the glass
    // stays exactly where the anchor put it.
    const windowFrame = windowFrameForSurface({ x: workAreaCentreX, y: 908 }, 'bottom', horizontalSurface, margins, workArea);
    expect(windowFrame.y + windowFrame.height).toBe(916);
  });

  it('keeps the window at the start of an edge shorter than the window', () => {
    const narrowWorkArea: LogicalRect = { x: 100, y: 0, width: 200, height: 908 };
    const windowFrame = windowFrameForSurface({ x: 200, y: 900 }, 'bottom', horizontalSurface, margins, narrowWorkArea);
    expect(windowFrame.x).toBe(100);
  });
});

describe('display selection', () => {
  it('finds the saved display or falls back to the primary', () => {
    const placementOnSecondDisplay: BarPlacement = { displayIdentifier: 'B', edge: 'left', positionAlongEdge: 0.2 };
    expect(indexOfDisplayForPlacement(placementOnSecondDisplay, ['A', 'B'], 0)).toBe(1);
    // The second display was unplugged.
    expect(indexOfDisplayForPlacement(placementOnSecondDisplay, ['A'], 0)).toBe(0);
    expect(indexOfDisplayForPlacement(placementOnSecondDisplay, [], 0)).toBeNull();
    // No saved display means the primary one, clamped into range.
    const placementOnPrimaryDisplay: BarPlacement = { displayIdentifier: null, edge: 'bottom', positionAlongEdge: 0.5 };
    expect(indexOfDisplayForPlacement(placementOnPrimaryDisplay, ['A', 'B'], 1)).toBe(1);
    expect(indexOfDisplayForPlacement(placementOnPrimaryDisplay, ['A', 'B'], 7)).toBe(1);
  });

  it('finds the display containing a point, else the nearest', () => {
    const displayBounds: LogicalRect[] = [
      { x: 0, y: 0, width: 1512, height: 982 },
      { x: 1512, y: 0, width: 2560, height: 1440 },
    ];
    expect(indexOfDisplayContaining({ x: 2000, y: 700 }, displayBounds)).toBe(1);
    // In the gap below the shorter display (the two are top-aligned).
    expect(indexOfDisplayContaining({ x: 1000, y: 1300 }, displayBounds)).toBe(0);
    // The shared border belongs to the display on its right, like CGRect.contains.
    expect(indexOfDisplayContaining({ x: 1512, y: 100 }, displayBounds)).toBe(1);
    expect(indexOfDisplayContaining({ x: 10, y: 10 }, [])).toBeNull();
  });
});
