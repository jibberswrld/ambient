import type { LucideIcon } from 'lucide-react';
import type { CSSProperties, MouseEvent, ReactNode } from 'react';

// Small controls shared by the bar, settings, onboarding and the tour. Every one shows the pointing-hand cursor on
// hover and scales slightly on press, because the interface should feel like it heard the click.
//
// Icons are Lucide throughout, drawn at a 2px stroke so they read at 10–14 px on smoked glass.

export type CapsuleProminence = 'primary' | 'secondary' | 'quiet';
/** Smoked glass surfaces are always dark; window surfaces follow the system appearance. */
export type ControlSurface = 'smokedGlass' | 'window';

export function CapsuleButton(props: {
  title: string;
  icon?: LucideIcon;
  prominence?: CapsuleProminence;
  surface?: ControlSurface;
  isCompact?: boolean;
  isDisabled?: boolean;
  /** Pressing Enter in the window presses this button (one per surface). */
  isDefaultAction?: boolean;
  /** A fuller name for screen readers and the tooltip, when the visible title is shortened to fit. */
  accessibleLabel?: string;
  onClick: (event: MouseEvent<HTMLButtonElement>) => void;
}) {
  const prominence = props.prominence ?? 'secondary';
  const surface = props.surface ?? 'smokedGlass';
  const Icon = props.icon;
  return (
    <button
      type="button"
      className={`capsule-button prominence-${prominence} surface-${surface}${props.isCompact ? ' is-compact' : ''}`}
      disabled={props.isDisabled}
      data-default-action={props.isDefaultAction ? 'true' : undefined}
      aria-label={props.accessibleLabel}
      title={props.accessibleLabel}
      onClick={props.onClick}
    >
      {Icon ? <Icon className="capsule-button-icon" strokeWidth={2.25} aria-hidden /> : null}
      <span>{props.title}</span>
    </button>
  );
}

/** A round icon button for smoked glass. The label is its tooltip and its name for screen readers. */
export function GlassIconButton(props: {
  icon: LucideIcon;
  label: string;
  diameter?: number;
  iconSize?: number;
  onClick: (event: MouseEvent<HTMLButtonElement>) => void;
}) {
  const Icon = props.icon;
  const diameter = props.diameter ?? 26;
  return (
    <button
      type="button"
      className="glass-icon-button"
      style={{ width: diameter, height: diameter }}
      title={props.label}
      aria-label={props.label}
      onClick={props.onClick}
    >
      <Icon size={props.iconSize ?? 13} strokeWidth={2.25} aria-hidden />
    </button>
  );
}

/** A keycap for a modifier key, used wherever Ambient teaches its shortcut. */
export function Keycap(props: { label: string; size?: number; isPressed?: boolean; isOnSmokedGlass?: boolean }) {
  const size = props.size ?? 20;
  const style: CSSProperties = {
    minWidth: size,
    height: size,
    fontSize: Math.round(size * 0.5 * 10) / 10,
    borderRadius: size * 0.26,
    paddingInline: size * 0.28,
  };
  return (
    <kbd
      className={`keycap${props.isPressed ? ' is-pressed' : ''}${props.isOnSmokedGlass === false ? ' on-window' : ''}`}
      style={style}
    >
      {props.label}
    </kbd>
  );
}

export function KeycapRow(props: { labels: string[]; size?: number; isPressed?: boolean; isOnSmokedGlass?: boolean; gap?: number }) {
  return (
    <span className="keycap-row" style={{ gap: props.gap ?? 3 }}>
      {props.labels.map((label) => (
        <Keycap key={label} label={label} size={props.size} isPressed={props.isPressed} isOnSmokedGlass={props.isOnSmokedGlass} />
      ))}
    </span>
  );
}

/** A switch in Ambient's own style. The track turns ember when on. */
export function SwitchControl(props: { isOn: boolean; label: string; onChange: (isOn: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={props.isOn}
      aria-label={props.label}
      className={`switch-control${props.isOn ? ' is-on' : ''}`}
      onClick={() => props.onChange(!props.isOn)}
    >
      <span className="switch-thumb" />
    </button>
  );
}

/** The Ambient mark: an ember inside a smoked capsule. Used at the top of onboarding and the settings sidebar. */
export function AmbientMark(props: { height?: number }) {
  const height = props.height ?? 28;
  return (
    <span className="ambient-mark" style={{ height, width: height * 1.75 }} aria-hidden>
      <span className="ambient-mark-ember" style={{ width: height * 0.32, height: height * 0.32, boxShadow: `0 0 ${height * 0.36}px rgb(255 149 74 / 0.9)` }} />
    </span>
  );
}

export type EmberActivity = 'thinking' | 'working' | 'idle';

/** Ambient's presence: a small ember. It breathes while thinking and gains a slow orbit while working with tools. */
export function EmberIndicator(props: { activity: EmberActivity; diameter?: number }) {
  const diameter = props.diameter ?? 16;
  return (
    <span className={`ember-indicator activity-${props.activity}`} style={{ width: diameter + 4, height: diameter + 4 }} aria-hidden>
      <span className="ember-glow" style={{ width: diameter, height: diameter }} />
      {props.activity === 'working' ? (
        <svg className="ember-orbit" width={diameter} height={diameter} viewBox="0 0 20 20">
          <circle cx="10" cy="10" r="9" fill="none" stroke="rgb(255 149 74 / 0.18)" strokeWidth="2" />
          <circle cx="10" cy="10" r="9" fill="none" stroke="var(--ember)" strokeWidth="2" strokeLinecap="round" strokeDasharray={`${2 * Math.PI * 9 * 0.3} 100`} />
        </svg>
      ) : null}
      <span className="ember-core" style={{ width: diameter * 0.44, height: diameter * 0.44 }} />
    </span>
  );
}

/** A small spinning arc for a running background task, drawn in the ember. */
export function RunningArc(props: { diameter?: number; label?: string }) {
  const diameter = props.diameter ?? 12;
  return (
    <svg className="running-arc" width={diameter} height={diameter} viewBox="0 0 16 16" role="img" aria-label={props.label ?? 'Running'}>
      <circle cx="8" cy="8" r="6.75" fill="none" stroke="rgb(255 149 74 / 0.24)" strokeWidth="2" />
      <circle cx="8" cy="8" r="6.75" fill="none" stroke="var(--ember)" strokeWidth="2" strokeLinecap="round" strokeDasharray={`${2 * Math.PI * 6.75 * 0.28} 100`} />
    </svg>
  );
}

/** A thin rule between groups inside a pill. */
export function PillDivider(props: { isUpright?: boolean }) {
  return <span className={`pill-divider${props.isUpright ? ' is-upright' : ''}`} aria-hidden />;
}

export function VisuallyHidden(props: { children: ReactNode }) {
  return <span className="visually-hidden">{props.children}</span>;
}
