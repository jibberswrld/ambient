import type { DockEdge } from '../host/contract';

/**
 * A miniature Windows screen with the bar on its real edge, so the "Put it where you like" lesson shows where the bar
 * is now. Not interactive: in the tour the person drags the real bar. A taskbar strip along the bottom says which way
 * is down.
 */
export function EdgePictureForTour(props: { dockEdge: DockEdge }) {
  const allEdges: DockEdge[] = ['bottom', 'top', 'left', 'right'];
  return (
    <span className="tour-edge-picture" aria-hidden>
      <span className="tour-edge-picture-taskbar" />
      {allEdges.map((edge) => (
        <span key={edge} className={`tour-edge-picture-bar edge-${edge}${edge === props.dockEdge ? ' is-selected' : ''}`} />
      ))}
    </span>
  );
}
