import { describe, expect, it } from 'vitest';
import { coachCornerAwayFromBar, coachWindowFrame } from './coachPlacement';

describe('coach placement', () => {
  it('sits in the corner away from the bar', () => {
    expect(coachCornerAwayFromBar('bottom')).toBe('topTrailing');
    expect(coachCornerAwayFromBar('left')).toBe('topTrailing');
    expect(coachCornerAwayFromBar('top')).toBe('bottomTrailing');
    expect(coachCornerAwayFromBar('right')).toBe('topLeading');
  });

  it('puts the card inset from the corner', () => {
    const workArea = { x: 0, y: 0, width: 1440, height: 875 };
    const windowSize = { width: 396, height: 520 };
    const topTrailing = coachWindowFrame('topTrailing', windowSize, 28, 14, workArea);
    expect(topTrailing.x + topTrailing.width - 28).toBe(1440 - 14);
    expect(topTrailing.y + 28).toBe(14);
    const bottomTrailing = coachWindowFrame('bottomTrailing', windowSize, 28, 14, workArea);
    expect(bottomTrailing.y + bottomTrailing.height - 28).toBe(875 - 14);
    const topLeading = coachWindowFrame('topLeading', windowSize, 28, 14, workArea);
    expect(topLeading.x + 28).toBe(14);
  });

  it('works on a monitor that does not start at the origin', () => {
    const workArea = { x: -1920, y: 200, width: 1920, height: 1040 };
    const frame = coachWindowFrame('topLeading', { width: 396, height: 400 }, 28, 14, workArea);
    expect(frame.x).toBe(-1920 + 14 - 28);
    expect(frame.y).toBe(200 + 14 - 28);
  });
});
