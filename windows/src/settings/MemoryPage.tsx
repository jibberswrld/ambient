import { Brain, Plus, Sparkles, Trash2, UserRound } from 'lucide-react';
import { useEffect, useState } from 'react';
import type { AmbientHost, MemoryItem } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { CapsuleButton } from '../design/controls';
import {
  EmptyState,
  FieldContainer,
  ListCard,
  LoadingRows,
  SettingsGroup,
  SettingsPage,
  SettingsSectionLabel,
  SwitchRow,
  formatRelativeTime,
  useCurrentTime,
} from './settingsShared';

function sortedNewestFirst(memoryItems: MemoryItem[]): MemoryItem[] {
  return [...memoryItems].sort((firstItem, secondItem) => Date.parse(secondItem.createdAt) - Date.parse(firstItem.createdAt));
}

/** Memory: whether Ambient learns on its own, a field to tell it something, and everything it knows, newest first. */
export function MemoryPage(props: { host: AmbientHost }) {
  const { host } = props;
  const [memoryItems, setMemoryItems] = useState<MemoryItem[] | null>(null);
  const [isAutomaticLearningEnabled, setIsAutomaticLearningEnabled] = useState(true);
  const [draftMemoryText, setDraftMemoryText] = useState('');
  // Relative times ("1 hour ago") are re-read every half minute so an open window does not go stale.
  const currentTime = useCurrentTime(30_000);

  useEffect(() => {
    let isCurrent = true;
    void host.invoke('get_automatic_learning_enabled', {}).then((isEnabled) => {
      if (isCurrent) setIsAutomaticLearningEnabled(isEnabled);
    });
    void host.invoke('get_memory_items', {}).then((loadedItems) => {
      if (isCurrent) setMemoryItems(sortedNewestFirst(loadedItems));
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:memory-items': (updatedItems) => setMemoryItems(sortedNewestFirst(updatedItems)),
    });
    return () => {
      isCurrent = false;
      stopListening();
    };
  }, [host]);

  function changeAutomaticLearning(isEnabled: boolean) {
    setIsAutomaticLearningEnabled(isEnabled);
    void host.invoke('set_automatic_learning_enabled', { isEnabled });
  }

  function addDraftMemory() {
    const trimmedText = draftMemoryText.trim();
    if (trimmedText.length === 0) return;
    setDraftMemoryText('');
    void host.invoke('add_memory', { text: trimmedText });
  }

  const hasDraftText = draftMemoryText.trim().length > 0;
  const learnedCount = memoryItems?.filter((memoryItem) => memoryItem.wasLearnedAutomatically).length ?? 0;

  return (
    <SettingsPage section="memory">
      <SettingsGroup>
        <SwitchRow
          title="Learn as I use it"
          detail="Ambient keeps short notes about your preferences and the people and projects you mention."
          isOn={isAutomaticLearningEnabled}
          onChange={changeAutomaticLearning}
        />
      </SettingsGroup>
      <div className="memory-entry">
        <FieldContainer icon={Plus}>
          <input
            className="settings-field-input"
            type="text"
            placeholder="Add something Ambient should know"
            aria-label="Add something Ambient should know"
            value={draftMemoryText}
            onChange={(event) => setDraftMemoryText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault();
                addDraftMemory();
              } else if (event.key === 'Escape') {
                setDraftMemoryText('');
              }
            }}
          />
        </FieldContainer>
        {/* The ember is earned: Add only becomes the primary action once there is something to add. */}
        <CapsuleButton title="Add" prominence={hasDraftText ? 'primary' : 'secondary'} surface="window" onClick={addDraftMemory} />
      </div>
      {memoryItems === null ? (
        <LoadingRows rowCount={4} />
      ) : memoryItems.length === 0 ? (
        <EmptyState icon={Brain} title="Nothing yet" message="Ambient learns as you use it. You can also add things yourself." />
      ) : (
        <div className="settings-stack is-label-and-list">
          <SettingsSectionLabel>
            <span className="tabular-figures">{memoryItems.length}</span> {memoryItems.length === 1 ? 'thing' : 'things'},{' '}
            <span className="tabular-figures">{learnedCount}</span> learned automatically
          </SettingsSectionLabel>
          <ListCard label="Memories">
            {memoryItems.map((memoryItem) => (
              <MemoryRow
                key={memoryItem.id}
                memoryItem={memoryItem}
                currentTime={currentTime}
                onDelete={() => void host.invoke('delete_memory', { itemId: memoryItem.id })}
              />
            ))}
          </ListCard>
        </div>
      )}
    </SettingsPage>
  );
}

function MemoryRow(props: { memoryItem: MemoryItem; currentTime: Date; onDelete: () => void }) {
  const { memoryItem } = props;
  return (
    <div className="settings-list-row memory-row" role="listitem">
      <div className="settings-list-row-text">
        <p className="memory-text">{memoryItem.text}</p>
        <p className="memory-meta">
          {memoryItem.wasLearnedAutomatically ? (
            <>
              <Sparkles className="memory-meta-icon is-learned" size={11} strokeWidth={2} aria-hidden />
              <span>Learned</span>
            </>
          ) : (
            <>
              <UserRound className="memory-meta-icon" size={11} strokeWidth={2} aria-hidden />
              <span>Added by you</span>
            </>
          )}
          <span aria-hidden>{'·'}</span>
          <time dateTime={memoryItem.createdAt}>{formatRelativeTime(new Date(memoryItem.createdAt), props.currentTime)}</time>
        </p>
      </div>
      <span className="reveal-on-row-hover memory-delete-slot">
        <button type="button" className="round-icon-button" title="Forget this" aria-label="Forget this" onClick={props.onDelete}>
          <Trash2 size={13} strokeWidth={2} aria-hidden />
        </button>
      </span>
    </div>
  );
}
