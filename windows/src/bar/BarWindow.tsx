import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react';
import type { AmbientHost, BarPlacement, DisplayInfo, DockEdge, LogicalRect } from '../host/contract';
import { useModelVersion } from '../design/useModel';
import { subscribeToHostEvents } from '../host/subscribe';
import {
  anchorPoint,
  indexOfDisplayContaining,
  indexOfDisplayForPlacement,
  nearestEdge,
  positionAlongEdge,
  projectedRestingPoint,
  windowFrameForSurface,
  type ScreenPoint,
  type SurfaceSize,
} from './dockGeometry';
import { FlowBarModel, isVerticalEdge } from './flowBarModel';
import { FlowBarSurface, type FlowBarSurfacePlacement } from './FlowBarSurface';

// The `bar` window: transparent, frameless, always on top, never activating (except while the text box is open).
//
// The window is exactly as large as the glass plus a small transparent margin, and it is resized as the content
// changes, so the transparent area never blocks clicks on the desktop. It grows at once when the glass is about to grow
// and shrinks only after the glass's spring has settled, so the morph is never clipped. While the bar is dragged the
// window covers the whole display the pointer is on, as the Mac panel does, so the bar can travel anywhere.

/** Gap between the glass and the edge of the usable screen area (the taskbar's edge, or the screen's). */
const insetFromScreenEdge = 8;
/** Keeps the bar's centre this far from the ends of an edge so it never hangs off the screen. */
const edgeEndMargin = 40;
/** Transparent room around the glass for its shadow, which also works as the hover slop. */
const windowMargins = { edgeSide: insetFromScreenEdge, otherSides: 20 };
/** Long enough for the surface-morph spring (580 ms) to settle before the window is cut down to the new size. */
const shrinkDelayMilliseconds = 620;
const landingSettleMilliseconds = 750;
const dragStartDistance = 3;
/** Hover starts after a short pause so a passing pointer does not make the bar jump, and ends after a longer one. */
const hoverStartDelayMilliseconds = 70;
const hoverEndDelayMilliseconds = 280;

const defaultPlacement: BarPlacement = { displayIdentifier: null, edge: 'bottom', positionAlongEdge: 0.5 };

interface DragSession {
  pointerId: number;
  startClientPoint: ScreenPoint;
  hasStarted: boolean;
  display: DisplayInfo | null;
  pointerSamples: { point: ScreenPoint; timeMilliseconds: number }[];
}

export function BarWindow(props: { host: AmbientHost }) {
  const { host } = props;
  const model = useMemo(() => new FlowBarModel(), []);
  useModelVersion(model);

  const [displays, setDisplays] = useState<DisplayInfo[]>([]);
  const [placement, setPlacement] = useState<BarPlacement>(defaultPlacement);
  const [surfaceSize, setSurfaceSize] = useState<SurfaceSize | null>(null);
  /** The glass size the window is currently built for: at least as large as the glass while it animates. */
  const [windowSurfaceSize, setWindowSurfaceSize] = useState<SurfaceSize | null>(null);
  const [windowFrame, setWindowFrame] = useState<LogicalRect | null>(null);
  /** Non-null while dragging or landing: the glass is positioned freely inside a display-sized window. */
  const [freePlacement, setFreePlacement] = useState<Extract<FlowBarSurfacePlacement, { kind: 'free' }> | null>(null);
  const dragSessionReference = useRef<DragSession | null>(null);
  const shrinkTimerReference = useRef<ReturnType<typeof setTimeout> | null>(null);
  const landingTimerReference = useRef<ReturnType<typeof setTimeout> | null>(null);
  const hoverTimerReference = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Intents --------------------------------------------------------------------------------------------------------
  useEffect(() => {
    model.onCancelTurn = () => void host.invoke('cancel_turn', {});
    model.onSubmitTypedText = (text) => void host.invoke('submit_text', { text });
    model.onOpenSettings = () => void host.invoke('open_settings', { section: null, taskId: null });
    model.onCheckForUpdates = () => void host.invoke('check_for_updates', {});
    model.onQuit = () => void host.invoke('quit', {});
    model.onAnswerApproval = (requestId, isAllowed) => void host.invoke('answer_approval', { requestId, isAllowed });
    model.onCancelBackgroundTask = (taskId) => void host.invoke('cancel_background_task', { taskId });
    model.onDismissBackgroundTask = (taskId) => void host.invoke('dismiss_background_task', { taskId });
    model.onOpenBackgroundTaskTranscript = (taskId) => void host.invoke('open_settings', { section: 'activity', taskId });
    model.onOpenUrl = (url) => void host.invoke('open_url', { url });
    model.onCopyText = (text) => void navigator.clipboard.writeText(text);
    model.onTypingStateChanged = (isTyping) => void host.invoke('set_bar_accepts_keyboard', { acceptsKeyboard: isTyping });
  }, [host, model]);

  // Initial state, then updates ---------------------------------------------------------------------------------------
  useEffect(() => {
    let isMounted = true;
    void (async () => {
      const [loadedDisplays, savedPlacement, generalSettings, backgroundTasks, pendingApproval, runtimePhase] = await Promise.all([
        host.ownWindow.listDisplays(),
        host.invoke('get_bar_placement', {}),
        host.invoke('get_general_settings', {}),
        host.invoke('get_background_tasks', {}),
        host.invoke('get_pending_approval', {}),
        host.invoke('get_runtime_phase', {}),
      ]);
      if (!isMounted) return;
      setDisplays(loadedDisplays);
      setPlacement(savedPlacement ?? defaultPlacement);
      model.setDockEdge((savedPlacement ?? defaultPlacement).edge);
      model.setPushToTalkShortcut(generalSettings.pushToTalkShortcut);
      model.setBackgroundTasks(backgroundTasks);
      if (pendingApproval) model.requestApproval(pendingApproval);
      if (runtimePhase.kind === 'listening') model.beginListening();
      if (runtimePhase.kind === 'transcribing') model.beginTranscribing();
      if (runtimePhase.kind === 'thinking') model.beginThinking();
    })();

    const stopListening = subscribeToHostEvents(host, {
      'ambient:runtime-phase': (runtimePhase) => {
        switch (runtimePhase.kind) {
          case 'idle':
            model.returnToIdle();
            break;
          case 'listening':
            if (model.turnPhase.kind !== 'listening') model.beginListening();
            model.updateAudioLevel(runtimePhase.audioLevel);
            break;
          case 'transcribing':
            model.beginTranscribing();
            break;
          case 'thinking':
            model.beginThinking();
            break;
        }
      },
      'ambient:agent-event': (agentEvent) => model.apply(agentEvent),
      'ambient:approval-requested': (request) => model.requestApproval(request),
      'ambient:approval-cancelled': ({ requestId }) => model.approvalCancelled(requestId),
      'ambient:background-tasks': (backgroundTasks) => model.setBackgroundTasks(backgroundTasks),
      'ambient:general-settings': (generalSettings) => model.setPushToTalkShortcut(generalSettings.pushToTalkShortcut),
      // A placement from elsewhere (Settings, or Rust after a display change): re-read the displays and re-dock.
      'ambient:bar-placement': (newPlacement) => {
        if (dragSessionReference.current?.hasStarted) return;
        void host.ownWindow.listDisplays().then((loadedDisplays) => {
          setDisplays(loadedDisplays);
          setPlacement(newPlacement);
          model.setDockEdge(newPlacement.edge);
        });
      },
    });

    return () => {
      isMounted = false;
      stopListening();
    };
  }, [host, model]);

  // Docking geometry ------------------------------------------------------------------------------------------------
  const dockedDisplay = useMemo(() => {
    const displayIndex = indexOfDisplayForPlacement(
      placement,
      displays.map((display) => display.identifier),
      Math.max(0, displays.findIndex((display) => display.isPrimary)),
    );
    return displayIndex === null ? null : displays[displayIndex];
  }, [displays, placement]);

  const dockedAnchor = useMemo(() => {
    if (!dockedDisplay) return null;
    return anchorPoint(placement.edge, placement.positionAlongEdge, dockedDisplay.workArea, edgeEndMargin, insetFromScreenEdge);
  }, [dockedDisplay, placement]);

  const applyWindowFrame = useCallback(
    (frame: LogicalRect) => {
      setWindowFrame(frame);
      void host.invoke('set_window_frame', { frame });
    },
    [host],
  );

  // The glass reports a new size: grow the window now, shrink it once the morph has settled.
  useEffect(() => {
    if (!surfaceSize || freePlacement) return;
    if (shrinkTimerReference.current) clearTimeout(shrinkTimerReference.current);
    setWindowSurfaceSize((currentWindowSurfaceSize) => {
      if (!currentWindowSurfaceSize) return surfaceSize;
      return {
        width: Math.max(currentWindowSurfaceSize.width, surfaceSize.width),
        height: Math.max(currentWindowSurfaceSize.height, surfaceSize.height),
      };
    });
    shrinkTimerReference.current = setTimeout(() => setWindowSurfaceSize(surfaceSize), shrinkDelayMilliseconds);
  }, [surfaceSize, freePlacement]);

  useEffect(() => {
    if (!dockedAnchor || !dockedDisplay || !windowSurfaceSize || freePlacement) return;
    applyWindowFrame(windowFrameForSurface(dockedAnchor, placement.edge, windowSurfaceSize, windowMargins, dockedDisplay.workArea));
  }, [dockedAnchor, dockedDisplay, windowSurfaceSize, placement.edge, freePlacement, applyWindowFrame]);

  // Near a corner the window is clamped inside the work area, so the glass sits off the window's centre by this much.
  const dockedOffsetAlongEdge = useMemo(() => {
    if (!windowFrame || !dockedAnchor) return 0;
    return isVerticalEdge(placement.edge)
      ? dockedAnchor.y - (windowFrame.y + windowFrame.height / 2)
      : dockedAnchor.x - (windowFrame.x + windowFrame.width / 2);
  }, [windowFrame, dockedAnchor, placement.edge]);

  // Hover -------------------------------------------------------------------------------------------------------------
  useEffect(() => {
    const scheduleHoverChange = (isHovering: boolean) => {
      if (hoverTimerReference.current) clearTimeout(hoverTimerReference.current);
      if (dragSessionReference.current?.hasStarted) return;
      hoverTimerReference.current = setTimeout(
        () => model.setPointerHovering(isHovering),
        isHovering ? hoverStartDelayMilliseconds : hoverEndDelayMilliseconds,
      );
    };
    const handlePointerEnter = () => scheduleHoverChange(true);
    const handlePointerLeave = () => scheduleHoverChange(false);
    document.documentElement.addEventListener('pointerenter', handlePointerEnter);
    document.documentElement.addEventListener('pointerleave', handlePointerLeave);
    // Clicking anywhere else ends typing, like any text field losing focus.
    const handleWindowBlur = () => model.endTyping();
    window.addEventListener('blur', handleWindowBlur);
    return () => {
      document.documentElement.removeEventListener('pointerenter', handlePointerEnter);
      document.documentElement.removeEventListener('pointerleave', handlePointerLeave);
      window.removeEventListener('blur', handleWindowBlur);
    };
  }, [model]);

  // Dragging to another edge or display ---------------------------------------------------------------------------
  /** The pointer in desktop coordinates: the window's origin plus the pointer inside it. */
  const desktopPointFromEvent = useCallback(
    (event: { clientX: number; clientY: number }): ScreenPoint => {
      const rootRect = document.getElementById('root')?.getBoundingClientRect() ?? { left: 0, top: 0 };
      const frame = windowFrame ?? { x: 0, y: 0 };
      return { x: frame.x + event.clientX - rootRect.left, y: frame.y + event.clientY - rootRect.top };
    },
    [windowFrame],
  );

  const beginDrag = useCallback(
    (dragSession: DragSession, desktopPoint: ScreenPoint) => {
      if (landingTimerReference.current) clearTimeout(landingTimerReference.current);
      if (hoverTimerReference.current) clearTimeout(hoverTimerReference.current);
      const displayIndex = indexOfDisplayContaining(desktopPoint, displays.map((display) => display.bounds));
      const dragDisplay = displayIndex === null ? dockedDisplay : displays[displayIndex];
      if (!dragDisplay) return;
      dragSession.hasStarted = true;
      dragSession.display = dragDisplay;
      model.setPointerHovering(false);
      model.setBeingDragged(true);
      applyWindowFrame(dragDisplay.bounds);
      setFreePlacement({ kind: 'free', x: desktopPoint.x - dragDisplay.bounds.x, y: desktopPoint.y - dragDisplay.bounds.y, edge: null, isLanding: false });
    },
    [displays, dockedDisplay, model, applyWindowFrame],
  );

  const handleSurfacePointerDown = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (event.button !== 0 || (event.target as HTMLElement).closest('button')) return;
      event.currentTarget.setPointerCapture(event.pointerId);
      dragSessionReference.current = {
        pointerId: event.pointerId,
        startClientPoint: { x: event.clientX, y: event.clientY },
        hasStarted: false,
        display: null,
        pointerSamples: [],
      };
    },
    [],
  );

  useEffect(() => {
    const handlePointerMove = (event: PointerEvent) => {
      const dragSession = dragSessionReference.current;
      if (!dragSession || event.pointerId !== dragSession.pointerId) return;
      const desktopPoint = desktopPointFromEvent(event);
      if (!dragSession.hasStarted) {
        const travelledDistance = Math.hypot(event.clientX - dragSession.startClientPoint.x, event.clientY - dragSession.startClientPoint.y);
        if (travelledDistance < dragStartDistance) return;
        beginDrag(dragSession, desktopPoint);
        return;
      }
      dragSession.pointerSamples.push({ point: desktopPoint, timeMilliseconds: performance.now() });
      if (dragSession.pointerSamples.length > 6) dragSession.pointerSamples.shift();
      // Crossing to another display: the window jumps to cover that display and the bar keeps following.
      const displayIndex = indexOfDisplayContaining(desktopPoint, displays.map((display) => display.bounds));
      const displayUnderPointer = displayIndex === null ? null : displays[displayIndex];
      if (displayUnderPointer && dragSession.display && displayUnderPointer.identifier !== dragSession.display.identifier) {
        dragSession.display = displayUnderPointer;
        applyWindowFrame(displayUnderPointer.bounds);
      }
      const dragDisplay = dragSession.display;
      if (!dragDisplay) return;
      setFreePlacement({ kind: 'free', x: desktopPoint.x - dragDisplay.bounds.x, y: desktopPoint.y - dragDisplay.bounds.y, edge: null, isLanding: false });
    };

    const handlePointerUp = (event: PointerEvent) => {
      const dragSession = dragSessionReference.current;
      if (!dragSession || event.pointerId !== dragSession.pointerId) return;
      dragSessionReference.current = null;
      const landingDisplay = dragSession.display;
      if (!dragSession.hasStarted || !landingDisplay) return;

      const releasePoint = desktopPointFromEvent(event);
      const releaseVelocity = pointerReleaseVelocity(dragSession.pointerSamples);
      const projectedPoint = projectedRestingPoint(releasePoint, releaseVelocity);
      const landingEdge: DockEdge = nearestEdge(projectedPoint, landingDisplay.workArea);
      const landingPosition = positionAlongEdge(projectedPoint, landingEdge, landingDisplay.workArea, edgeEndMargin);
      const newPlacement: BarPlacement = { displayIdentifier: landingDisplay.identifier, edge: landingEdge, positionAlongEdge: landingPosition };
      const landingAnchor = anchorPoint(landingEdge, landingPosition, landingDisplay.workArea, edgeEndMargin, insetFromScreenEdge);

      model.setDockEdge(landingEdge);
      model.setBeingDragged(false);
      setFreePlacement({
        kind: 'free',
        x: landingAnchor.x - landingDisplay.bounds.x,
        y: landingAnchor.y - landingDisplay.bounds.y,
        edge: landingEdge,
        isLanding: true,
      });
      setPlacement(newPlacement);
      void host.invoke('set_bar_placement', { placement: newPlacement });

      // Once the landing spring has settled, shrink the window back to its docked size. The glass is already exactly
      // where the docked layout puts it, so this is invisible.
      landingTimerReference.current = setTimeout(() => {
        setFreePlacement(null);
        setWindowSurfaceSize(null);
      }, landingSettleMilliseconds);
    };

    window.addEventListener('pointermove', handlePointerMove);
    window.addEventListener('pointerup', handlePointerUp);
    window.addEventListener('pointercancel', handlePointerUp);
    return () => {
      window.removeEventListener('pointermove', handlePointerMove);
      window.removeEventListener('pointerup', handlePointerUp);
      window.removeEventListener('pointercancel', handlePointerUp);
    };
  }, [displays, desktopPointFromEvent, beginDrag, applyWindowFrame, host, model]);

  // After landing the window is rebuilt from the measured glass size.
  useEffect(() => {
    if (!freePlacement && !windowSurfaceSize && surfaceSize) setWindowSurfaceSize(surfaceSize);
  }, [freePlacement, windowSurfaceSize, surfaceSize]);

  const surfacePlacement: FlowBarSurfacePlacement = freePlacement ?? {
    kind: 'docked',
    gapFromEdge: windowMargins.edgeSide,
    offsetAlongEdge: dockedOffsetAlongEdge,
  };

  return (
    <div className="bar-window">
      <FlowBarSurface model={model} placement={surfacePlacement} onSurfaceSizeChange={setSurfaceSize} onDragPointerDown={handleSurfacePointerDown} />
    </div>
  );
}

/** Points per second over the last few samples. A pointer that stopped before release carries no momentum. */
function pointerReleaseVelocity(pointerSamples: { point: ScreenPoint; timeMilliseconds: number }[]): ScreenPoint {
  const firstSample = pointerSamples[0];
  const lastSample = pointerSamples[pointerSamples.length - 1];
  if (!firstSample || !lastSample) return { x: 0, y: 0 };
  const elapsedSeconds = (lastSample.timeMilliseconds - firstSample.timeMilliseconds) / 1000;
  if (elapsedSeconds < 0.005) return { x: 0, y: 0 };
  if (performance.now() - lastSample.timeMilliseconds > 80) return { x: 0, y: 0 };
  return {
    x: (lastSample.point.x - firstSample.point.x) / elapsedSeconds,
    y: (lastSample.point.y - firstSample.point.y) / elapsedSeconds,
  };
}
