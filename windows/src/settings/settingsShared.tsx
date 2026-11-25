import type { LucideIcon } from 'lucide-react';
import { Blocks, Brain, CircleAlert, CircleUser, History, Puzzle, Settings } from 'lucide-react';
import { useEffect, useState, type ReactNode } from 'react';
import type { SettingsSection } from '../host/contract';
import { SwitchControl } from '../design/controls';

// The building blocks every settings page shares, ported from the "Page scaffolding" and "Shared pieces" of
// AmbientSettingsView.swift / AmbientSettingsPages.swift: a page title with one line of purpose, rounded card groups
// with hairline separators, rows with a control on the right, loading placeholders, empty states and inline errors.

export interface SettingsSectionDescription {
  section: SettingsSection;
  title: string;
  subtitle: string;
  icon: LucideIcon;
}

/** The sidebar order, titles, icons and the one-line purpose shown under each page title. */
export const settingsSectionDescriptions: SettingsSectionDescription[] = [
  { section: 'general', title: 'General', subtitle: 'How you talk to Ambient and where it lives.', icon: Settings },
  { section: 'connectors', title: 'Connectors', subtitle: 'Apps Ambient can use for you.', icon: Blocks },
  { section: 'memory', title: 'Memory', subtitle: 'What Ambient knows about you. Delete anything.', icon: Brain },
  { section: 'skills', title: 'Skills', subtitle: 'Instructions Ambient can load when a task calls for them.', icon: Puzzle },
  { section: 'activity', title: 'Activity', subtitle: 'Agents and commands that ran in the background.', icon: History },
  { section: 'account', title: 'Account', subtitle: 'Your publik account and plan.', icon: CircleUser },
];

export function isSettingsSection(candidateSection: string | null | undefined): candidateSection is SettingsSection {
  return settingsSectionDescriptions.some((description) => description.section === candidateSection);
}

function descriptionForSection(section: SettingsSection): SettingsSectionDescription {
  return settingsSectionDescriptions.find((description) => description.section === section) ?? settingsSectionDescriptions[0];
}

/**
 * A settings page: a title, one line of what it is for, then its content. Most pages scroll inside the right-hand
 * pane; Activity does not, because its two panes scroll on their own and should fill the window's height.
 */
export function SettingsPage(props: { section: SettingsSection; scrolls?: boolean; isWide?: boolean; accessory?: ReactNode; children: ReactNode }) {
  const description = descriptionForSection(props.section);
  const scrolls = props.scrolls ?? true;
  return (
    <div className={`settings-page${scrolls ? ' is-scrolling' : ' is-fixed'}`}>
      <div className={`settings-page-column${props.isWide ? ' is-wide' : ''}`}>
        <header className="settings-page-header">
          <div className="settings-page-heading">
            <h1 className="settings-page-title">{description.title}</h1>
            <p className="settings-page-subtitle">{description.subtitle}</p>
          </div>
          {props.accessory ? <div className="settings-page-accessory">{props.accessory}</div> : null}
        </header>
        {props.children}
      </div>
    </div>
  );
}

/** A label above a card, such as "Talking" or "3 connected". Counts in it use tabular figures. */
export function SettingsSectionLabel(props: { children: ReactNode }) {
  return <p className="settings-section-label">{props.children}</p>;
}

/** A rounded group of rows with hairline separators, optionally under a label. */
export function SettingsGroup(props: { label?: string; children: ReactNode }) {
  return (
    <section className="settings-group">
      {props.label ? <SettingsSectionLabel>{props.label}</SettingsSectionLabel> : null}
      <div className="settings-card">{props.children}</div>
    </section>
  );
}

/** The hairline between two rows in a group. It starts at the row's text, not the card's edge. */
export function GroupDivider() {
  return <div className="settings-group-divider" aria-hidden />;
}

/** A row: title and optional one-line explanation on the left, a control on the right. */
export function SettingsRow(props: { title: string; detail?: string | null; titleId?: string; children?: ReactNode }) {
  return (
    <div className="settings-row">
      <div className="settings-row-text">
        <p className="settings-row-title" id={props.titleId}>
          {props.title}
        </p>
        {props.detail ? <p className="settings-row-detail">{props.detail}</p> : null}
      </div>
      {props.children ? <div className="settings-row-control">{props.children}</div> : null}
    </div>
  );
}

/** A switch row. The switch carries the row's title as its accessible name. */
export function SwitchRow(props: { title: string; detail?: string | null; isOn: boolean; onChange: (isOn: boolean) => void }) {
  return (
    <SettingsRow title={props.title} detail={props.detail}>
      <SwitchControl isOn={props.isOn} label={props.title} onChange={props.onChange} />
    </SettingsRow>
  );
}

/** A list card: rows with hairlines between them (each row draws its own hover fill). */
export function ListCard(props: { children: ReactNode; label?: string }) {
  return (
    <div className="settings-card settings-list-card" role="list" aria-label={props.label}>
      {props.children}
    </div>
  );
}

/** Placeholder rows while a list loads: the shape of the content, gently pulsing, each a beat after the last. */
export function LoadingRows(props: { rowCount: number }) {
  const rowIndices = Array.from({ length: props.rowCount }, (_unused, rowIndex) => rowIndex);
  return (
    <div className="settings-card settings-list-card" aria-busy="true" aria-label="Loading">
      {rowIndices.map((rowIndex) => (
        <div key={rowIndex} className="settings-loading-row" style={{ animationDelay: `${rowIndex * 80}ms` }} aria-hidden>
          <span className="settings-loading-tile" />
          {/* Varying widths so the placeholder reads as a list of names, not a barcode. */}
          <span className="settings-loading-line" style={{ width: 90 + ((rowIndex * 37) % 80) }} />
          <span className="settings-loading-spacer" />
          <span className="settings-loading-capsule" />
        </div>
      ))}
    </div>
  );
}

/** A centred message for empty lists, errors and signed-out states. */
export function EmptyState(props: { icon: LucideIcon; title: string; message: string; isError?: boolean; action?: ReactNode }) {
  const Icon = props.icon;
  return (
    <div className={`settings-empty-state${props.isError ? ' is-error' : ''}`} role={props.isError ? 'alert' : undefined}>
      <span className="settings-empty-state-icon">
        <Icon size={22} strokeWidth={2} aria-hidden />
      </span>
      <p className="settings-empty-state-title">{props.title}</p>
      <p className="settings-empty-state-message">{props.message}</p>
      {props.action ? <div className="settings-empty-state-action">{props.action}</div> : null}
    </div>
  );
}

/** A one-line error under a control, in plain words. */
export function InlineError(props: { message: string }) {
  return (
    <p className="settings-inline-error" role="alert">
      <CircleAlert size={13} strokeWidth={2} aria-hidden />
      <span>{props.message}</span>
    </p>
  );
}

/** A search or entry field drawn in Ambient's style instead of the default bezel. Focus rings the whole field. */
export function FieldContainer(props: { icon?: LucideIcon; children: ReactNode }) {
  const Icon = props.icon;
  return (
    <label className="settings-field">
      {Icon ? <Icon className="settings-field-icon" size={13} strokeWidth={2} aria-hidden /> : null}
      {props.children}
    </label>
  );
}

/** The host rejects with a plain-language message string; anything else gets the page's own wording. */
export function messageFromRejection(rejection: unknown, fallbackMessage: string): string {
  if (typeof rejection === 'string' && rejection.trim().length > 0) return rejection;
  return fallbackMessage;
}

/** The current time, refreshed every `refreshIntervalMilliseconds` so relative times ("5 minutes ago") stay true. */
export function useCurrentTime(refreshIntervalMilliseconds: number, isRefreshing = true): Date {
  const [currentTime, setCurrentTime] = useState(() => new Date());
  useEffect(() => {
    if (!isRefreshing) return;
    setCurrentTime(new Date());
    const refreshTimer = setInterval(() => setCurrentTime(new Date()), refreshIntervalMilliseconds);
    return () => clearInterval(refreshTimer);
  }, [refreshIntervalMilliseconds, isRefreshing]);
  return currentTime;
}

const relativeTimeFormatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

/**
 * "1 hour ago", "yesterday", "3 days ago", "last week": the named relative style the Mac uses
 * (`.relative(presentation: .named)`), picking the largest unit that still reads naturally.
 */
export function formatRelativeTime(pastDate: Date, currentTime: Date): string {
  const elapsedSeconds = Math.max(0, (currentTime.getTime() - pastDate.getTime()) / 1000);
  if (elapsedSeconds < 60) return relativeTimeFormatter.format(-Math.round(elapsedSeconds), 'second');
  const elapsedMinutes = elapsedSeconds / 60;
  if (elapsedMinutes < 60) return relativeTimeFormatter.format(-Math.round(elapsedMinutes), 'minute');
  const elapsedHours = elapsedMinutes / 60;
  if (elapsedHours < 24) return relativeTimeFormatter.format(-Math.round(elapsedHours), 'hour');
  const elapsedDays = elapsedHours / 24;
  if (elapsedDays < 7) return relativeTimeFormatter.format(-Math.round(elapsedDays), 'day');
  if (elapsedDays < 30) return relativeTimeFormatter.format(-Math.round(elapsedDays / 7), 'week');
  if (elapsedDays < 365) return relativeTimeFormatter.format(-Math.round(elapsedDays / 30), 'month');
  return relativeTimeFormatter.format(-Math.round(elapsedDays / 365), 'year');
}
