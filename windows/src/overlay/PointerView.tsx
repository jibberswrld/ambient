// Ambient pointing at something on screen, ported from AmbientPointerView.swift: the ember, the same light that lives
// in the bar, lands on the target, a ring closes around it like a focus lock, and a smoked-glass label names it.
// The view's centre is the exact point; the label hangs off the corner on the side with room.

export type PointerLabelPlacement = 'trailingBelow' | 'trailingAbove' | 'leadingBelow' | 'leadingAbove';

/** The side of the square the pointer occupies. The point is at its centre. */
const pointerFootprint = 44;

/**
 * The label goes on the side with room: leading (to the left) in the right half of the display, above when the point
 * is within 70 px of the bottom, as AmbientPointerWindowController.swift decides.
 */
export function pointerLabelPlacement(pointX: number, pointY: number, viewWidth: number, viewHeight: number): PointerLabelPlacement {
  const isLeading = pointX > viewWidth / 2;
  const isAbove = pointY > viewHeight - 70;
  if (isLeading) return isAbove ? 'leadingAbove' : 'leadingBelow';
  return isAbove ? 'trailingAbove' : 'trailingBelow';
}

export function PointerView(props: { x: number; y: number; label: string | null; labelPlacement: PointerLabelPlacement }) {
  return (
    <div
      className={`pointer-view placement-${props.labelPlacement}`}
      style={{ left: props.x - pointerFootprint / 2, top: props.y - pointerFootprint / 2 }}
      role="img"
      aria-label={props.label ? `Pointing at ${props.label}` : 'Pointing'}
    >
      <span className="pointer-halo" />
      <span className="pointer-ring" />
      <span className="pointer-ring-shadow" />
      <span className="pointer-core" />
      {props.label ? <span className="pointer-label smoked-glass">{props.label}</span> : null}
    </div>
  );
}
