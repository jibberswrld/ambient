import { ArrowUpRight, Check, Mic, ScanEye } from 'lucide-react';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { FlowBarModel } from '../bar/flowBarModel';
import { FlowBarSurface } from '../bar/FlowBarSurface';
import { AmbientMark, CapsuleButton, EmberIndicator, RunningArc } from '../design/controls';
import type { AmbientHost, GateScreen, PermissionStatus, PermissionStatuses } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import {
  allPermissionKinds,
  areRequiredPermissionsGranted,
  firstMissingPermission,
  permissionDeniedReasons,
  permissionReasons,
  permissionStatus,
  permissionTitles,
  type PermissionKind,
} from './permissions';
import './onboarding.css';

// Onboarding is always drawn dark, in the same smoked material and ember light as the bar, because it is the person's
// first look at Ambient and should already feel like it. It is the publik sign-in gate while the host shows one, then
// the permissions step. Rust closes the window when it is done.

/** The `onboarding` window, connected to the host. */
export function OnboardingWindow(props: { host: AmbientHost }) {
  const { host } = props;
  const [gateScreen, setGateScreen] = useState<GateScreen | null>(null);
  const [permissionStatuses, setPermissionStatuses] = useState<PermissionStatuses | null>(null);
  const [hasLoaded, setHasLoaded] = useState(false);

  useEffect(() => {
    let isMounted = true;
    void Promise.all([host.invoke('get_gate_screen', {}), host.invoke('get_permission_statuses', {})]).then(([currentGateScreen, statuses]) => {
      if (!isMounted) return;
      setGateScreen(currentGateScreen);
      setPermissionStatuses(statuses);
      setHasLoaded(true);
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:gate-screen': (newGateScreen) => setGateScreen(newGateScreen),
      'ambient:permission-statuses': (statuses) => setPermissionStatuses(statuses),
    });
    return () => {
      isMounted = false;
      stopListening();
    };
  }, [host]);

  // Enter presses the screen's one primary button.
  useEffect(() => {
    const pressDefaultAction = (event: KeyboardEvent) => {
      if (event.key !== 'Enter' || (event.target as HTMLElement).closest('button')) return;
      document.querySelector<HTMLButtonElement>('[data-default-action="true"]')?.click();
    };
    window.addEventListener('keydown', pressDefaultAction);
    return () => window.removeEventListener('keydown', pressDefaultAction);
  }, []);

  if (!hasLoaded) return <OnboardingBackdrop>{null}</OnboardingBackdrop>;
  return (
    <OnboardingView
      gateScreen={gateScreen}
      permissionStatuses={permissionStatuses}
      onGateAction={(action) => void host.invoke('answer_gate', { action })}
      onGrantMicrophone={() => void host.invoke('request_microphone_permission', {})}
      onContinue={() => void host.invoke('finish_permissions_step', {})}
    />
  );
}

/** The onboarding window's content, without the host, so the gallery can show each screen. */
export function OnboardingView(props: {
  gateScreen: GateScreen | null;
  permissionStatuses: PermissionStatuses | null;
  onGateAction: (action: string) => void;
  onGrantMicrophone: () => void;
  onContinue: () => void;
}) {
  const screenKind = props.gateScreen ? 'gate' : 'permissions';
  return (
    <OnboardingBackdrop>
      {/* The kind of screen is the key: two gate screens update in place, gate → permissions turns a page. */}
      <div key={screenKind} className="onboarding-screen-turn">
        {props.gateScreen ? (
          <GateScreenView gateScreen={props.gateScreen} onGateAction={props.onGateAction} />
        ) : (
          <PermissionsScreenView permissionStatuses={props.permissionStatuses} onGrantMicrophone={props.onGrantMicrophone} onContinue={props.onContinue} />
        )}
      </div>
    </OnboardingBackdrop>
  );
}

/** Warm graphite with the faint glow of the ember behind the mark. */
function OnboardingBackdrop(props: { children: ReactNode }) {
  return <div className="onboarding-window appearance-dark">{props.children}</div>;
}

/** The frame every onboarding screen shares: the mark, a title, a line of body text, the content, the buttons. */
function OnboardingScreenShell(props: { title: string; body: string; children: ReactNode; footer: ReactNode }) {
  return (
    <div className="onboarding-shell">
      <AmbientMark height={26} />
      <h1 className="onboarding-title">{props.title}</h1>
      <p className="onboarding-body">{props.body}</p>
      <div className="onboarding-content">{props.children}</div>
      <div className="onboarding-footer">{props.footer}</div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Gate
// ---------------------------------------------------------------------------------------------------------------------

function GateScreenView(props: { gateScreen: GateScreen; onGateAction: (action: string) => void }) {
  const { gateScreen } = props;
  return (
    <OnboardingScreenShell
      title={gateScreen.title}
      body={gateScreen.body}
      footer={gateScreen.buttons.map((button) => (
        <CapsuleButton
          key={button.action}
          title={button.label}
          prominence={button.prominence}
          isDefaultAction={button.prominence === 'primary'}
          onClick={() => props.onGateAction(button.action)}
        />
      ))}
    >
      <GateHeroStage />
      {gateScreen.note ? (
        <p key={gateScreen.note} className="gate-note">
          {gateScreen.isWaiting ? <EmberIndicator activity="thinking" diameter={12} /> : null}
          <span>{gateScreen.note}</span>
        </p>
      ) : null}
    </OnboardingScreenShell>
  );
}

/**
 * The permissions step's picture: the same miniature desktop, with the real bar showing what the microphone is for.
 * Once it is allowed the bar listens, so the picture answers "what did I just turn on?".
 */
function MicrophoneHeroStage(props: { isListening: boolean }) {
  const heroBarModel = useMemo(() => new FlowBarModel(), []);
  useEffect(() => {
    if (props.isListening) {
      heroBarModel.beginListening();
      heroBarModel.updateAudioLevel(0.6);
    } else {
      heroBarModel.returnToIdle();
      heroBarModel.pinHoverForPreview(true);
    }
  }, [heroBarModel, props.isListening]);
  return (
    <div className="gate-hero-stage is-compact" aria-hidden>
      <FlowBarSurface model={heroBarModel} placement={{ kind: 'docked', gapFromEdge: 14, offsetAlongEdge: 0 }} />
    </div>
  );
}

/** The gate's picture: a miniature desktop with the real bar on it, showing what the person is signing in to. */
function GateHeroStage() {
  const heroBarModel = useMemo(() => {
    const model = new FlowBarModel();
    model.pinHoverForPreview(true);
    return model;
  }, []);
  return (
    <div className="gate-hero-stage" aria-hidden>
      <FlowBarSurface model={heroBarModel} placement={{ kind: 'docked', gapFromEdge: 14, offsetAlongEdge: 0 }} />
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------------------------------------------------

const permissionIcons: Record<PermissionKind, typeof Mic> = { microphone: Mic };

function PermissionsScreenView(props: { permissionStatuses: PermissionStatuses | null; onGrantMicrophone: () => void; onContinue: () => void }) {
  const isReady = areRequiredPermissionsGranted(props.permissionStatuses);
  const nextPermission = firstMissingPermission(props.permissionStatuses);
  return (
    <OnboardingScreenShell
      title="What Ambient needs"
      body="It is used only when you ask for something. You can change it any time in Windows Settings."
      footer={
        isReady ? (
          <CapsuleButton title="Continue" prominence="primary" isDefaultAction onClick={props.onContinue} />
        ) : (
          <CapsuleButton title="Not now" prominence="quiet" onClick={props.onContinue} />
        )
      }
    >
      <MicrophoneHeroStage isListening={areRequiredPermissionsGranted(props.permissionStatuses)} />
      <div className="permission-list">
        {allPermissionKinds.map((permissionKind) => (
          <PermissionRow
            key={permissionKind}
            permissionKind={permissionKind}
            status={permissionStatus(props.permissionStatuses, permissionKind)}
            isTheNextStep={nextPermission === permissionKind}
            onGrant={props.onGrantMicrophone}
          />
        ))}
      </div>
      {/* Windows asks nothing for screen capture, so the screen is explained rather than requested. */}
      <p className="permission-aside">
        <ScanEye size={14} strokeWidth={2} aria-hidden />
        <span>Ambient looks at your screen only when you ask it to. Windows has no separate switch for that.</span>
      </p>
    </OnboardingScreenShell>
  );
}

function PermissionRow(props: { permissionKind: PermissionKind; status: PermissionStatus; isTheNextStep: boolean; onGrant: () => void }) {
  const Icon = permissionIcons[props.permissionKind];
  return (
    <div className="permission-row">
      <span className="permission-icon">
        <Icon size={15} strokeWidth={2} aria-hidden />
      </span>
      <span className="permission-text">
        <span className="permission-title">{permissionTitles[props.permissionKind]}</span>
        <span className="permission-reason">
          {props.status === 'deniedInSystemSettings' ? permissionDeniedReasons[props.permissionKind] : permissionReasons[props.permissionKind]}
        </span>
      </span>
      <PermissionStatusControl status={props.status} isTheNextStep={props.isTheNextStep} onGrant={props.onGrant} />
    </div>
  );
}

function PermissionStatusControl(props: { status: PermissionStatus; isTheNextStep: boolean; onGrant: () => void }) {
  switch (props.status) {
    case 'granted':
      return (
        <span className="permission-granted">
          <Check size={12} strokeWidth={3} aria-hidden />
          Allowed
        </span>
      );
    case 'waiting':
      return (
        <span className="permission-waiting">
          <RunningArc diameter={11} />
          Waiting
        </span>
      );
    case 'notYetAsked':
      return <CapsuleButton title="Allow" prominence={props.isTheNextStep ? 'primary' : 'secondary'} isCompact onClick={props.onGrant} />;
    case 'deniedInSystemSettings':
      return (
        <CapsuleButton
          title="Open settings"
          accessibleLabel="Open Windows microphone settings"
          icon={ArrowUpRight}
          prominence={props.isTheNextStep ? 'primary' : 'secondary'}
          isCompact
          onClick={props.onGrant}
        />
      );
  }
}
