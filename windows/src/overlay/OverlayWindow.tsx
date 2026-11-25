import { useEffect, useState } from 'react';
import type { AmbientHost, OverlayDrawing, OverlayPoint } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { AnnotationOverlay } from './AnnotationOverlay';
import { PointerView, pointerLabelPlacement } from './PointerView';
import './overlay.css';

/** A pointer is removed after four seconds; a drawing stays until it is cleared or replaced. */
const pointerLifetimeMilliseconds = 4000;

/**
 * The `overlay` window: fullscreen, transparent and click-through, covering exactly the monitor that was captured. Rust
 * moves it there before sending `ambient:overlay-point` / `ambient:overlay-draw`; this only draws.
 */
export function OverlayWindow(props: { host: AmbientHost }) {
  const { host } = props;
  const [drawing, setDrawing] = useState<OverlayDrawing | null>(null);
  /** Counts drawings so each new one replays its stroke animation from the start. */
  const [drawingNumber, setDrawingNumber] = useState(0);
  /** A new key per point restarts the arrival animation even when pointing at the same place twice. */
  const [shownPoint, setShownPoint] = useState<(OverlayPoint & { key: number }) | null>(null);
  const [viewSize, setViewSize] = useState({ width: window.innerWidth, height: window.innerHeight });

  useEffect(() => {
    const handleResize = () => setViewSize({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  useEffect(() => {
    let isMounted = true;
    void host.invoke('get_overlay_drawing', {}).then((currentDrawing) => {
      if (isMounted && currentDrawing) setDrawing(currentDrawing);
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:overlay-draw': (newDrawing) => {
        setDrawing(newDrawing);
        setDrawingNumber((previousNumber) => previousNumber + 1);
      },
      'ambient:overlay-clear': () => setDrawing(null),
      'ambient:overlay-point': (point) => setShownPoint({ ...point, key: Date.now() }),
    });
    return () => {
      isMounted = false;
      stopListening();
    };
  }, [host]);

  useEffect(() => {
    if (!shownPoint) return;
    const removalTimer = setTimeout(() => setShownPoint(null), pointerLifetimeMilliseconds);
    return () => clearTimeout(removalTimer);
  }, [shownPoint]);

  const hasContent = drawing !== null || shownPoint !== null;
  useEffect(() => {
    void host.invoke('overlay_content_changed', { hasContent });
  }, [host, hasContent]);

  const pointInView = shownPoint
    ? { x: (shownPoint.x * viewSize.width) / shownPoint.captureWidth, y: (shownPoint.y * viewSize.height) / shownPoint.captureHeight }
    : null;

  return (
    <div className="overlay-window">
      {drawing ? <AnnotationOverlay key={drawingNumber} drawing={drawing} viewSize={viewSize} /> : null}
      {shownPoint && pointInView ? (
        <PointerView
          key={shownPoint.key}
          x={pointInView.x}
          y={pointInView.y}
          label={shownPoint.label}
          labelPlacement={pointerLabelPlacement(pointInView.x, pointInView.y, viewSize.width, viewSize.height)}
        />
      ) : null}
    </div>
  );
}
