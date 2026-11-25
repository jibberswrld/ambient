import { Check, CircleAlert, CircleCheck, CircleMinus, Download, History } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import type { AmbientHost, BackgroundTask, Uuid } from '../host/contract';
import { subscribeToHostEvents } from '../host/subscribe';
import { CapsuleButton, RunningArc } from '../design/controls';
import { MarkdownView } from '../design/MarkdownView';
import { backgroundTaskHasReport, backgroundTaskKindName } from '../bar/FlowBarSurface';
import { formatElapsedTime } from '../bar/elapsedTime';
import { EmptyState, InlineError, SettingsPage, formatRelativeTime, messageFromRejection, useCurrentTime } from './settingsShared';

/** While a task runs its transcript is re-read this often, so the log follows it. */
const transcriptPollIntervalMilliseconds = 1000;

/**
 * Activity: background agents and commands on the left, the selected one on the right. A finished agent opens on its
 * report (formatted markdown, Save as file, Copy); everything it printed while working is one click away.
 *
 * The selected task lives in the window, not this page, because the tray's Read report can ask for a task while
 * Settings shows another page.
 */
export function ActivityPage(props: { host: AmbientHost; selectedTaskId: Uuid | null; onSelectTask: (taskId: Uuid | null) => void }) {
  const { host, selectedTaskId, onSelectTask } = props;
  const [backgroundTasks, setBackgroundTasks] = useState<BackgroundTask[] | null>(null);
  const currentTime = useCurrentTime(30_000);

  // The transcript poll reads the latest list without restarting every time the list changes.
  const latestBackgroundTasksReference = useRef(backgroundTasks);
  latestBackgroundTasksReference.current = backgroundTasks;

  useEffect(() => {
    let isCurrent = true;
    void host.invoke('get_background_tasks', {}).then((loadedTasks) => {
      if (isCurrent) setBackgroundTasks(loadedTasks);
    });
    const stopListening = subscribeToHostEvents(host, {
      'ambient:background-tasks': (updatedTasks) => setBackgroundTasks(updatedTasks),
    });
    return () => {
      isCurrent = false;
      stopListening();
    };
  }, [host]);

  // Nothing selected, or the selected task was dismissed: fall back to the newest task.
  useEffect(() => {
    if (!backgroundTasks) return;
    const selectedTaskStillExists = backgroundTasks.some((backgroundTask) => backgroundTask.id === selectedTaskId);
    if (!selectedTaskStillExists) onSelectTask(backgroundTasks[0]?.id ?? null);
  }, [backgroundTasks, selectedTaskId, onSelectTask]);

  const selectedTask = backgroundTasks?.find((backgroundTask) => backgroundTask.id === selectedTaskId) ?? null;

  return (
    <SettingsPage section="activity" scrolls={false} isWide>
      {backgroundTasks === null ? (
        <div className="activity-loading">
          <RunningArc diameter={16} label="Loading" />
        </div>
      ) : backgroundTasks.length === 0 ? (
        <EmptyState icon={History} title="No background work yet" message="When you ask Ambient to start an agent or run a command, it shows up here." />
      ) : (
        <div className="activity-panes">
          <div className="activity-task-list settings-card" role="listbox" aria-label="Background tasks">
            <div className="activity-task-list-rows">
              {backgroundTasks.map((backgroundTask) => (
                <ActivityTaskRow
                  key={backgroundTask.id}
                  backgroundTask={backgroundTask}
                  isSelected={backgroundTask.id === selectedTaskId}
                  currentTime={currentTime}
                  onSelect={() => onSelectTask(backgroundTask.id)}
                />
              ))}
            </div>
          </div>
          {selectedTask ? (
            // Keyed by task so the report/log toggle, "Copied" and the transcript start fresh for each task.
            <TranscriptPane key={selectedTask.id} host={host} selectedTask={selectedTask} latestBackgroundTasksReference={latestBackgroundTasksReference} />
          ) : (
            <div className="activity-transcript-pane settings-card" />
          )}
        </div>
      )}
    </SettingsPage>
  );
}

function ActivityTaskRow(props: { backgroundTask: BackgroundTask; isSelected: boolean; currentTime: Date; onSelect: () => void }) {
  const { backgroundTask } = props;
  return (
    <button
      type="button"
      role="option"
      aria-selected={props.isSelected}
      className={`activity-task-row${props.isSelected ? ' is-selected' : ''}`}
      onClick={props.onSelect}
    >
      <span className="activity-task-glyph">
        <WindowTaskStatusGlyph status={backgroundTask.status} />
      </span>
      <span className="activity-task-text">
        <span className="activity-task-title">{backgroundTask.title}</span>
        <span className="activity-task-time">{formatRelativeTime(new Date(backgroundTask.startedAt), props.currentTime)}</span>
      </span>
    </button>
  );
}

/** The bar's status glyphs are coloured for smoked glass; on a window they use the window's own text colours. */
function WindowTaskStatusGlyph(props: { status: BackgroundTask['status'] }) {
  switch (props.status) {
    case 'running':
      return <RunningArc diameter={12} />;
    case 'succeeded':
      return <CircleCheck className="activity-glyph-succeeded" size={14} strokeWidth={2} aria-label="Finished" />;
    case 'failed':
      return <CircleAlert className="activity-glyph-failed" size={14} strokeWidth={2} aria-label="Failed" />;
    case 'cancelled':
      return <CircleMinus className="activity-glyph-cancelled" size={14} strokeWidth={2} aria-label="Stopped" />;
  }
}

const startedAtFormatter = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });

/** "Codex, started Nov 20, 2026, 7:38 PM, ran 8:20". */
function transcriptCaption(backgroundTask: BackgroundTask, currentTime: Date): string {
  const startedAt = new Date(backgroundTask.startedAt);
  const endedAt = backgroundTask.finishedAt ? new Date(backgroundTask.finishedAt) : currentTime;
  return `${backgroundTaskKindName(backgroundTask.kind)}, started ${startedAtFormatter.format(startedAt)}, ran ${formatElapsedTime(startedAt, endedAt)}`;
}

/** The Save dialog suggests the task's title; slashes, colons and backslashes are not allowed in Windows file names. */
function suggestedReportFileName(taskTitle: string): string {
  return `${taskTitle.replace(/[/:\\]/g, ' ')}.md`;
}

function TranscriptPane(props: {
  host: AmbientHost;
  selectedTask: BackgroundTask;
  latestBackgroundTasksReference: { current: BackgroundTask[] | null };
}) {
  const { host, selectedTask, latestBackgroundTasksReference } = props;
  const [transcriptText, setTranscriptText] = useState<string | null>(null);
  /** A finished agent's report is shown by default; this switches to everything it printed while working. */
  const [isShowingActivityLog, setIsShowingActivityLog] = useState(false);
  const [didCopyReport, setDidCopyReport] = useState(false);
  const [reportErrorMessage, setReportErrorMessage] = useState<string | null>(null);
  const isRunning = selectedTask.status === 'running';
  // The caption's "ran 0:42" ticks every second while the task runs.
  const currentTime = useCurrentTime(1000, isRunning);

  const selectedTaskId = selectedTask.id;
  useEffect(() => {
    let isCurrent = true;
    let pollTimer: ReturnType<typeof setTimeout> | null = null;
    // Read first, then decide whether to read again: a task that just finished still gets its final transcript.
    async function readTranscriptWhileRunning() {
      try {
        const latestTranscript = await host.invoke('get_background_task_transcript', { taskId: selectedTaskId });
        if (!isCurrent) return;
        setTranscriptText(latestTranscript);
      } catch {
        if (!isCurrent) return;
      }
      const latestTask = latestBackgroundTasksReference.current?.find((backgroundTask) => backgroundTask.id === selectedTaskId);
      if (latestTask?.status === 'running') pollTimer = setTimeout(() => void readTranscriptWhileRunning(), transcriptPollIntervalMilliseconds);
    }
    void readTranscriptWhileRunning();
    return () => {
      isCurrent = false;
      if (pollTimer) clearTimeout(pollTimer);
    };
    // Restarts when the task starts or stops running too, so the final transcript is read once it finishes.
  }, [host, selectedTaskId, isRunning, latestBackgroundTasksReference]);

  const hasReport = backgroundTaskHasReport(selectedTask);
  const reportText = selectedTask.result ?? '';
  const isShowingReport = hasReport && !isShowingActivityLog;

  async function saveReport() {
    setReportErrorMessage(null);
    try {
      await host.invoke('save_text_file', { suggestedName: suggestedReportFileName(selectedTask.title), text: reportText });
    } catch (rejection) {
      setReportErrorMessage(messageFromRejection(rejection, 'The report could not be saved. Try another folder.'));
    }
  }

  async function copyReport() {
    setReportErrorMessage(null);
    try {
      await navigator.clipboard.writeText(reportText);
      setDidCopyReport(true);
    } catch {
      setReportErrorMessage('The report could not be copied.');
    }
  }

  return (
    <div className="activity-transcript-pane settings-card">
      <div className="activity-transcript-header">
        <h2 className="activity-transcript-title">{selectedTask.title}</h2>
        <p className="activity-transcript-caption">{transcriptCaption(selectedTask, currentTime)}</p>
        {hasReport ? (
          <div className="activity-report-actions">
            <CapsuleButton title="Save as file" icon={Download} prominence="secondary" surface="window" isCompact onClick={() => void saveReport()} />
            <CapsuleButton
              title={didCopyReport ? 'Copied' : 'Copy'}
              icon={didCopyReport ? Check : undefined}
              prominence="quiet"
              surface="window"
              isCompact
              onClick={() => void copyReport()}
            />
            <span className="activity-report-actions-spacer" />
            <CapsuleButton
              title={isShowingActivityLog ? 'Show report' : 'Show activity log'}
              prominence="quiet"
              surface="window"
              isCompact
              onClick={() => setIsShowingActivityLog((wasShowingActivityLog) => !wasShowingActivityLog)}
            />
          </div>
        ) : null}
        {reportErrorMessage ? <InlineError message={reportErrorMessage} /> : null}
      </div>
      <div className="activity-transcript-body" tabIndex={0} aria-label={isShowingReport ? 'Report' : 'Activity log'}>
        {isShowingReport ? (
          <div className="activity-report">
            <MarkdownView markdownText={reportText} surface="window" onOpenLink={(url) => void host.invoke('open_url', { url })} />
          </div>
        ) : (
          <pre className={`activity-log${transcriptText === null ? ' is-loading' : ''}`}>{transcriptText ?? 'Loading transcript'}</pre>
        )}
      </div>
    </div>
  );
}
