import { useEffect, useState } from 'react';
import type { AmbientHost, DockEdge, GeneralSettings, PushToTalkShortcut } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { KeycapRow } from '../design/controls';
import { allPushToTalkShortcuts, keycapLabels, spokenShortcutName } from '../design/shortcuts';
import { GroupDivider, InlineError, SettingsGroup, SettingsPage, SettingsRow, SwitchRow, messageFromRejection } from './settingsShared';

/**
 * General: the shortcut held to talk, spoken replies, sound effects, the bar's screen edge, command approval and Open at
 * login. The Rust core owns the truth: every change sends the whole settings object, and the page adopts what actually
 * applied (Open at login can fail, so the switch must fall back rather than lie).
 */
export function GeneralPage(props: { host: AmbientHost }) {
  const { host } = props;
  const [generalSettings, setGeneralSettings] = useState<GeneralSettings | null>(null);
  const [saveErrorMessage, setSaveErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    let isCurrent = true;
    void host.invoke('get_general_settings', {}).then((loadedSettings) => {
      if (isCurrent) setGeneralSettings(loadedSettings);
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:general-settings': (updatedSettings) => setGeneralSettings(updatedSettings),
    });
    return () => {
      isCurrent = false;
      stopListening();
    };
  }, [host]);

  function applyChange(changedSettings: Partial<GeneralSettings>) {
    if (!generalSettings) return;
    const requestedSettings: GeneralSettings = { ...generalSettings, ...changedSettings };
    // Show the change at once; the resolved value replaces it a moment later if the core could not apply it.
    setGeneralSettings(requestedSettings);
    setSaveErrorMessage(null);
    host
      .invoke('set_general_settings', { settings: requestedSettings })
      .then((appliedSettings) => setGeneralSettings(appliedSettings))
      .catch((rejection: unknown) => {
        setGeneralSettings(generalSettings);
        setSaveErrorMessage(messageFromRejection(rejection, 'That change could not be saved. Try again.'));
      });
  }

  return (
    <SettingsPage section="general">
      {generalSettings ? (
        <>
          {saveErrorMessage ? <InlineError message={saveErrorMessage} /> : null}
          <SettingsGroup label="Talking">
            <SettingsRow title="Hold to talk" detail="Hold both keys, speak, then let go." titleId="hold-to-talk-title">
              <ShortcutPicker
                selectedShortcut={generalSettings.pushToTalkShortcut}
                onSelectShortcut={(pushToTalkShortcut) => applyChange({ pushToTalkShortcut })}
              />
            </SettingsRow>
            <GroupDivider />
            <SwitchRow title="Read replies out loud" isOn={generalSettings.speaksReplies} onChange={(speaksReplies) => applyChange({ speaksReplies })} />
            <GroupDivider />
            <SwitchRow
              title="Sound effects"
              detail="Short, quiet cues when Ambient listens, needs you, or hits a problem."
              isOn={generalSettings.playsSoundEffects}
              onChange={(playsSoundEffects) => applyChange({ playsSoundEffects })}
            />
          </SettingsGroup>
          <SettingsGroup label="The bar">
            <SettingsRow title="Screen edge" detail="You can also drag the bar to any edge.">
              <EdgePicker selectedEdge={generalSettings.dockEdge} onSelectEdge={(dockEdge) => applyChange({ dockEdge })} />
            </SettingsRow>
          </SettingsGroup>
          <SettingsGroup label="Permissions">
            <SwitchRow
              title="Run commands without asking"
              detail={
                generalSettings.runsCommandsWithoutAsking
                  ? 'Ambient runs commands on this PC straight away.'
                  : 'Ambient shows you each command and waits for you to allow it.'
              }
              isOn={generalSettings.runsCommandsWithoutAsking}
              onChange={(runsCommandsWithoutAsking) => applyChange({ runsCommandsWithoutAsking })}
            />
            <GroupDivider />
            <SwitchRow title="Open at login" isOn={generalSettings.launchesAtLogin} onChange={(launchesAtLogin) => applyChange({ launchesAtLogin })} />
          </SettingsGroup>
          <SettingsGroup label="Privacy">
            <SwitchRow
              title="Share anonymous usage stats"
              detail="Helps improve setup. Sends steps and command outcomes to PostHog, never your requests or account."
              isOn={generalSettings.sharesAnonymousUsageStats}
              onChange={(sharesAnonymousUsageStats) => applyChange({ sharesAnonymousUsageStats })}
            />
          </SettingsGroup>
        </>
      ) : null}
    </SettingsPage>
  );
}

/** Three shortcut choices, each shown as its keycaps. The chosen one sits in an ember outline. */
function ShortcutPicker(props: { selectedShortcut: PushToTalkShortcut; onSelectShortcut: (shortcut: PushToTalkShortcut) => void }) {
  return (
    <div className="shortcut-picker" role="radiogroup" aria-labelledby="hold-to-talk-title">
      {allPushToTalkShortcuts.map((shortcut) => {
        const isSelected = shortcut === props.selectedShortcut;
        return (
          <button
            key={shortcut}
            type="button"
            role="radio"
            aria-checked={isSelected}
            aria-label={spokenShortcutName(shortcut)}
            title={spokenShortcutName(shortcut)}
            className={`shortcut-choice${isSelected ? ' is-selected' : ''}`}
            onClick={() => props.onSelectShortcut(shortcut)}
          >
            <KeycapRow labels={keycapLabels(shortcut)} size={20} isOnSmokedGlass={false} />
          </button>
        );
      })}
    </div>
  );
}

const edgeDisplayNames: Record<DockEdge, string> = { top: 'Top', bottom: 'Bottom', left: 'Left', right: 'Right' };
/** Drawn in this order so Tab moves around the miniature screen clockwise from the top. */
const edgesInTabOrder: DockEdge[] = ['top', 'right', 'bottom', 'left'];

/**
 * A small picture of this PC's screen; click an edge to put the bar there. A taskbar runs along the bottom of the
 * miniature so bottom reads as bottom (the Mac drew its menu bar along the top instead), and the bottom target sits
 * just above it, exactly where the real bar docks above the real taskbar.
 */
function EdgePicker(props: { selectedEdge: DockEdge; onSelectEdge: (edge: DockEdge) => void }) {
  return (
    <div className="edge-picker" role="radiogroup" aria-label="Screen edge">
      <div className="edge-picker-screen" aria-hidden>
        <div className="edge-picker-taskbar">
          <span className="edge-picker-taskbar-icon" />
          <span className="edge-picker-taskbar-icon" />
          <span className="edge-picker-taskbar-icon" />
          <span className="edge-picker-taskbar-icon" />
        </div>
      </div>
      {edgesInTabOrder.map((edge) => {
        const isSelected = edge === props.selectedEdge;
        return (
          <button
            key={edge}
            type="button"
            role="radio"
            aria-checked={isSelected}
            aria-label={`${edgeDisplayNames[edge]} edge`}
            title={`${edgeDisplayNames[edge]} edge`}
            className={`edge-picker-target edge-${edge}${isSelected ? ' is-selected' : ''}`}
            onClick={() => props.onSelectEdge(edge)}
          >
            <span className="edge-picker-bar" />
          </button>
        );
      })}
    </div>
  );
}
