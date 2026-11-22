import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { indexOfDisplayForPlacement } from '../bar/dockGeometry';
import type { AmbientHost, BarPlacement, DisplayInfo, RuntimePhase } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { coachCardMargin, coachCardWidth, coachCornerAwayFromBar, coachInsetFromScreenEdge, coachWindowFrame, isTopCorner } from './coachPlacement';
import { TourCoachCard } from './TourCoachCard';
import { TourModel } from './tourModel';
import './tour.css';

// The `tour` window: transparent, frameless, always on top (one level above the bar), never taking focus from the app
// the person is in, and always taking clicks. It is exactly as large as the coach card plus room for its shadow, sits
// in the screen corner away from the bar, and is dragged by the card's body like any window. Once the person has moved
// it, it stays where they put it instead of following the bar.

/** The connector service has no push, so the Connect lesson checks for newly connected apps this often. */
const connectorPollIntervalMilliseconds = 3000;
/** The card animates to a shorter height; cutting the window first would clip that animation. */
const shrinkDelayMilliseconds = 450;

export function TourWindow(props: { host: AmbientHost }) {
  const { host } = props;
  const model = useMemo(() => new TourModel(), []);
  const cardReference = useRef<HTMLDivElement>(null);
  const [displays, setDisplays] = useState<DisplayInfo[]>([]);
  const [barPlacement, setBarPlacement] = useState<BarPlacement | null>(null);
  const [cardHeight, setCardHeight] = useState<number | null>(null);
  const [windowHeight, setWindowHeight] = useState<number | null>(null);
  const hasBeenMovedByPersonReference = useRef(false);

  // Intents -----------------------------------------------------------------------------------------------------------
  useEffect(() => {
    model.onFixPermission = () => void host.invoke('request_microphone_permission', {});
    model.onOpenConnectors = () => void host.invoke('open_settings', { section: 'connectors', taskId: null });
    model.onFinish = () => {
      void host.invoke('set_onboarding_completed', { isCompleted: true }).then(() => host.invoke('end_tour', {}));
    };
  }, [host, model]);

  // Real events in --------------------------------------------------------------------------------------------------
  useEffect(() => {
    let isMounted = true;
    let previousRuntimePhase: RuntimePhase['kind'] = 'idle';
    void Promise.all([
      host.ownWindow.listDisplays(),
      host.invoke('get_bar_placement', {}),
      host.invoke('get_general_settings', {}),
      host.invoke('get_permission_statuses', {}),
    ]).then(([loadedDisplays, placement, generalSettings, permissionStatuses]) => {
      if (!isMounted) return;
      const resolvedPlacement = placement ?? { displayIdentifier: null, edge: generalSettings.dockEdge, positionAlongEdge: 0.5 };
      setDisplays(loadedDisplays);
      setBarPlacement(resolvedPlacement);
      model.shortcut = generalSettings.pushToTalkShortcut;
      model.dockEdgeChanged(resolvedPlacement.edge);
      model.permissionStatusesChanged(permissionStatuses);
      model.begin();
    });

    const stopListening = subscribeToHostEvents(host, {
      'ambient:push-to-talk': (transition) => {
        if (transition.kind === 'pressed') model.shortcutPressed();
        else model.shortcutReleased(transition.heldForSeconds);
      },
      'ambient:runtime-phase': (runtimePhase) => {
        // Transcribing straight to idle is a recording in which nothing was heard: an empty transcript.
        if (previousRuntimePhase === 'transcribing' && runtimePhase.kind === 'idle') model.heardNothing();
        if (runtimePhase.kind === 'thinking' && previousRuntimePhase !== 'thinking') model.thinkingStarted();
        previousRuntimePhase = runtimePhase.kind;
      },
      'ambient:agent-event': (agentEvent) => model.apply(agentEvent),
      'ambient:text-submitted': () => model.typedRequestSubmitted(),
      'ambient:approval-requested': (request) => model.approvalRequested(request.kind),
      'ambient:approval-answered': (answer) => {
        if (answer.kind === 'backgroundAgent') model.approvalAnswered(answer.isAllowed);
      },
      'ambient:bar-placement': (placement) => {
        model.dockEdgeChanged(placement.edge);
        setBarPlacement(placement);
        void host.ownWindow.listDisplays().then(setDisplays);
      },
      'ambient:general-settings': (generalSettings) => {
        model.shortcut = generalSettings.pushToTalkShortcut;
      },
      'ambient:permission-statuses': (permissionStatuses) => model.permissionStatusesChanged(permissionStatuses),
    });
    return () => {
      isMounted = false;
      stopListening();
    };
  }, [host, model]);

  // The Connect lesson: look for newly connected apps every few seconds. An unreachable connector service is not the
  // person's problem to solve in the tour; the lesson simply stays open and "Later" moves on.
  useEffect(() => {
    const pollTimer = setInterval(() => {
      if (model.currentLesson !== 'connectApps') return;
      host
        .invoke('get_connector_apps', { query: '' })
        .then((apps) => model.connectedAppsChanged(apps.filter((app) => app.isConnected).map((app) => app.name)))
        .catch(() => undefined);
    }, connectorPollIntervalMilliseconds);
    return () => clearInterval(pollTimer);
  }, [host, model]);

  // Sizing and placement ---------------------------------------------------------------------------------------------
  useLayoutEffect(() => {
    const cardElement = cardReference.current;
    if (!cardElement) return;
    const measure = () => setCardHeight(Math.ceil(cardElement.offsetHeight));
    measure();
    const resizeObserver = new ResizeObserver(measure);
    resizeObserver.observe(cardElement);
    return () => resizeObserver.disconnect();
  }, []);

  // Grow at once; shrink once the card has finished getting shorter.
  useEffect(() => {
    if (cardHeight === null) return;
    const targetWindowHeight = cardHeight + coachCardMargin * 2;
    if (windowHeight === null || targetWindowHeight > windowHeight) {
      setWindowHeight(targetWindowHeight);
      return;
    }
    if (targetWindowHeight === windowHeight) return;
    const shrinkTimer = setTimeout(() => setWindowHeight(targetWindowHeight), shrinkDelayMilliseconds);
    return () => clearTimeout(shrinkTimer);
  }, [cardHeight, windowHeight]);

  const corner = coachCornerAwayFromBar(barPlacement?.edge ?? 'bottom');
  const barDisplay = useMemo(() => {
    if (!barPlacement) return null;
    const displayIndex = indexOfDisplayForPlacement(
      barPlacement,
      displays.map((display) => display.identifier),
      Math.max(0, displays.findIndex((display) => display.isPrimary)),
    );
    return displayIndex === null ? null : displays[displayIndex];
  }, [barPlacement, displays]);

  // The first placement, and every time the bar moves while the person has not placed the coach themselves.
  useEffect(() => {
    if (!barDisplay || windowHeight === null) return;
    const windowSize = { width: coachCardWidth + coachCardMargin * 2, height: windowHeight };
    if (hasBeenMovedByPersonReference.current) {
      // Placed by the person: it stays where they left it and only its height changes, holding the card's anchored edge
      // (the top for a top corner, the bottom for the bottom corner) still.
      void host.ownWindow.currentFrame().then((currentFrame) => {
        const top = isTopCorner(corner) ? currentFrame.y : currentFrame.y + currentFrame.height - windowSize.height;
        void host.invoke('set_window_frame', { frame: { x: currentFrame.x, y: top, ...windowSize } });
      });
      return;
    }
    void host.invoke('set_window_frame', { frame: coachWindowFrame(corner, windowSize, coachCardMargin, coachInsetFromScreenEdge, barDisplay.workArea) });
  }, [host, corner, barDisplay, windowHeight]);

  return (
    <div className={`tour-window corner-${corner}${isTopCorner(corner) ? ' is-top' : ' is-bottom'}`}>
      <TourCoachCard
        ref={cardReference}
        model={model}
        onBackgroundPointerDown={(event) => {
          if (event.button !== 0 || (event.target as HTMLElement).closest('button')) return;
          hasBeenMovedByPersonReference.current = true;
          void host.ownWindow.startDragging();
        }}
      />
    </div>
  );
}
