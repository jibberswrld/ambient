import { Power } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import type { AmbientHost, SettingsSection, Uuid } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { AmbientMark } from '../design/controls';
import { useSystemAppearanceClassName } from '../design/useModel';
import { AccountPage } from './AccountPage';
import { ActivityPage } from './ActivityPage';
import { ConnectorsPage } from './ConnectorsPage';
import { GeneralPage } from './GeneralPage';
import { MemoryPage } from './MemoryPage';
import { SkillsPage } from './SkillsPage';
import { isSettingsSection, settingsSectionDescriptions } from './settingsShared';
import './settings.css';

/**
 * The Settings window, following the system's light/dark appearance and contrast setting.
 *
 * In a browser preview `?section=<name>` opens a given page (the app always asks the host which page to show).
 */
export function SettingsWindow(props: { host: AmbientHost }) {
  const appearanceClassName = useSystemAppearanceClassName();
  const sectionFromQuery = new URLSearchParams(window.location.search).get('section');
  return (
    <SettingsWindowView
      host={props.host}
      appearanceClassName={appearanceClassName}
      initialSection={isSettingsSection(sectionFromQuery) ? sectionFromQuery : undefined}
    />
  );
}

/**
 * The Settings window with an explicit appearance, so a gallery can show every page in light and dark side by side.
 * `appearanceClassName` is `appearance-light` or `appearance-dark`, optionally with ` contrast-more`.
 * `initialSection`, when given, wins over the page the host remembers; later navigation from the host still applies.
 */
export function SettingsWindowView(props: { host: AmbientHost; appearanceClassName: string; initialSection?: SettingsSection }) {
  const { host, initialSection } = props;
  const [selectedSection, setSelectedSection] = useState<SettingsSection>(initialSection ?? 'general');
  const [selectedBackgroundTaskId, setSelectedBackgroundTaskId] = useState<Uuid | null>(null);

  useEffect(() => {
    let isCurrent = true;
    void host.invoke('get_settings_navigation', {}).then((navigation) => {
      if (!isCurrent) return;
      if (!initialSection) setSelectedSection(navigation.section);
      if (navigation.taskId) setSelectedBackgroundTaskId(navigation.taskId);
    });
    const stopListening = subscribeToHostEvents(host, {
      // The tray's Read report / Transcript, or the menu's Open Settings: switch page, and on Activity pick the task.
      'ambient:settings-navigate': (navigation) => {
        setSelectedSection(navigation.section);
        if (navigation.taskId) setSelectedBackgroundTaskId(navigation.taskId);
      },
    });
    return () => {
      isCurrent = false;
      stopListening();
    };
  }, [host, initialSection]);

  const selectBackgroundTask = useCallback((taskId: Uuid | null) => setSelectedBackgroundTaskId(taskId), []);

  return (
    <div className={`settings-window ${props.appearanceClassName}`}>
      <SettingsSidebar selectedSection={selectedSection} onSelectSection={setSelectedSection} onQuit={() => void host.invoke('quit', {})} />
      <main className="settings-content" aria-label="Settings page">
        {/* Keyed so each page mounts fresh (and loads its data) when it is shown, as the Mac pages do on appear. */}
        <SettingsPageForSection
          key={selectedSection}
          host={host}
          section={selectedSection}
          selectedBackgroundTaskId={selectedBackgroundTaskId}
          onSelectBackgroundTask={selectBackgroundTask}
        />
      </main>
    </div>
  );
}

function SettingsPageForSection(props: {
  host: AmbientHost;
  section: SettingsSection;
  selectedBackgroundTaskId: Uuid | null;
  onSelectBackgroundTask: (taskId: Uuid | null) => void;
}) {
  switch (props.section) {
    case 'general':
      return <GeneralPage host={props.host} />;
    case 'connectors':
      return <ConnectorsPage host={props.host} />;
    case 'memory':
      return <MemoryPage host={props.host} />;
    case 'skills':
      return <SkillsPage host={props.host} />;
    case 'activity':
      return <ActivityPage host={props.host} selectedTaskId={props.selectedBackgroundTaskId} onSelectTask={props.onSelectBackgroundTask} />;
    case 'account':
      return <AccountPage host={props.host} />;
  }
}

function SettingsSidebar(props: { selectedSection: SettingsSection; onSelectSection: (section: SettingsSection) => void; onQuit: () => void }) {
  return (
    <nav className="settings-sidebar" aria-label="Settings sections">
      <div className="settings-sidebar-brand">
        <AmbientMark height={18} />
        <span className="settings-sidebar-brand-name">Ambient</span>
      </div>
      <ul className="settings-sidebar-list">
        {settingsSectionDescriptions.map((description) => {
          const isSelected = description.section === props.selectedSection;
          const SectionIcon = description.icon;
          return (
            <li key={description.section}>
              <button
                type="button"
                className={`settings-sidebar-row${isSelected ? ' is-selected' : ''}`}
                aria-current={isSelected ? 'page' : undefined}
                onClick={() => props.onSelectSection(description.section)}
              >
                <SectionIcon className="settings-sidebar-icon" size={15} strokeWidth={2} aria-hidden />
                <span>{description.title}</span>
              </button>
            </li>
          );
        })}
      </ul>
      {/* Quit sits at the foot of the sidebar on every page: the tray icon is easy to lose in the overflow menu. */}
      <button type="button" className="settings-sidebar-row settings-quit-row" onClick={props.onQuit}>
        <Power className="settings-sidebar-icon" size={14} strokeWidth={2} aria-hidden />
        <span>Quit Ambient</span>
      </button>
    </nav>
  );
}
