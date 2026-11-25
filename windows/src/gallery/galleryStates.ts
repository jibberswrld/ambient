import type { BackgroundTask, DockEdge } from '../host/contract';
import { sampleBackgroundTasks, sampleLongReply, sampleMediumReply } from '../host/mockData';
import { FlowBarModel } from '../bar/flowBarModel';
import { TourModel } from '../tour/tourModel';

// Every state the gallery shows, built by driving the real models through the same methods the windows call.

export const barStateNames = [
  'resting',
  'resting-tasks',
  'hovering',
  'hovering-tasks',
  'listening',
  'listening-quiet',
  'transcribing',
  'thinking',
  'working',
  'typing',
  'responding',
  'reply-short',
  'reply',
  'reply-long',
  'error',
  'error-top-up',
  'approval-command',
  'approval-agent',
  'task-tray',
  'task-finished',
  'context-menu',
] as const;
export type BarStateName = (typeof barStateNames)[number];

/** States drawn as cards (they need a taller tile). */
export const barCardStateNames = new Set<BarStateName>([
  'responding',
  'reply-short',
  'reply',
  'reply-long',
  'error',
  'error-top-up',
  'approval-command',
  'approval-agent',
  'task-tray',
  'context-menu',
]);

function runningTasks(): BackgroundTask[] {
  return sampleBackgroundTasks().filter((backgroundTask) => backgroundTask.status === 'running');
}

export function makeBarModel(stateName: BarStateName, edge: DockEdge): FlowBarModel {
  const model = new FlowBarModel();
  model.revealsReplyInstantly = true;
  model.finishedReplyLingerSeconds = 0;
  model.errorLingerSeconds = 0;
  model.taskFinishedNoticeSeconds = 10_000;
  model.setDockEdge(edge);
  switch (stateName) {
    case 'resting':
      break;
    case 'resting-tasks':
      model.setBackgroundTasks([...runningTasks(), sampleBackgroundTasks()[3]]);
      break;
    case 'hovering':
      model.pinHoverForPreview(true);
      break;
    case 'hovering-tasks':
      model.setBackgroundTasks(runningTasks());
      model.pinHoverForPreview(true);
      break;
    case 'listening':
      model.beginListening();
      model.updateAudioLevel(0.72);
      break;
    case 'listening-quiet':
      model.beginListening();
      model.updateAudioLevel(0);
      break;
    case 'transcribing':
      model.beginListening();
      model.beginTranscribing();
      break;
    case 'thinking':
      model.beginThinking();
      break;
    case 'working':
      model.beginThinking();
      model.apply({ kind: 'toolStarted', callId: 'one', toolName: 'gmail_search_threads', activityLabel: 'Searching Gmail' });
      model.apply({ kind: 'toolFinished', callId: 'one', toolName: 'gmail_search_threads', isError: false });
      model.apply({ kind: 'toolStarted', callId: 'two', toolName: 'calendar_list_events', activityLabel: 'Checking your calendar' });
      break;
    case 'typing':
      model.beginTyping();
      model.setTypedText('Move my 4:30 with Alex to Monday');
      break;
    case 'responding':
      model.beginThinking();
      model.apply({ kind: 'textDelta', text: sampleMediumReply.slice(0, 214) });
      model.apply({ kind: 'toolStarted', callId: 'gmail', toolName: 'gmail_search_threads', activityLabel: 'Searching Gmail' });
      break;
    case 'reply-short':
      model.apply({ kind: 'textDelta', text: "Done. It's on your calendar." });
      model.apply({ kind: 'finished', finalText: "Done. It's on your calendar." });
      break;
    case 'reply':
      model.apply({ kind: 'toolStarted', callId: 'one', toolName: 'gmail_search_threads', activityLabel: 'Searching Gmail' });
      model.apply({ kind: 'toolFinished', callId: 'one', toolName: 'gmail_search_threads', isError: false });
      model.apply({ kind: 'toolStarted', callId: 'two', toolName: 'gmail_draft', activityLabel: 'Drafting a reply' });
      model.apply({ kind: 'toolFinished', callId: 'two', toolName: 'gmail_draft', isError: false });
      model.apply({ kind: 'textDelta', text: sampleMediumReply });
      model.apply({ kind: 'finished', finalText: sampleMediumReply });
      break;
    case 'reply-long':
      model.apply({ kind: 'textDelta', text: sampleLongReply });
      model.apply({ kind: 'finished', finalText: sampleLongReply });
      break;
    case 'error':
      model.apply({ kind: 'failed', failure: { kind: 'other', message: 'Ambient could not reach the internet. Check your connection and try again.' } });
      break;
    case 'error-top-up':
      model.apply({
        kind: 'failed',
        failure: { kind: 'paymentRequired', message: "You have used this month's allowance.", topUpUrl: 'https://publikhq.com/wallet' },
      });
      break;
    case 'approval-command':
      model.beginThinking();
      model.requestApproval({ requestId: 'a', title: 'Run this command?', detail: 'git push origin feature/settings-refactor', kind: 'shellCommand' });
      break;
    case 'approval-agent':
      model.beginThinking();
      model.requestApproval({
        requestId: 'b',
        title: 'Start a Codex agent?',
        detail: 'Fix the three failing tests in AmbientUITests and open a pull request when they pass.',
        kind: 'backgroundAgent',
      });
      break;
    case 'task-tray':
      model.setBackgroundTasks(sampleBackgroundTasks());
      model.toggleTaskTray();
      break;
    case 'task-finished': {
      const runningTask: BackgroundTask = { ...sampleBackgroundTasks()[0] };
      model.setBackgroundTasks([runningTask]);
      model.setBackgroundTasks([{ ...runningTask, status: 'succeeded', finishedAt: new Date().toISOString(), result: 'Done.' }]);
      break;
    }
    case 'context-menu':
      model.openContextMenu();
      break;
  }
  return model;
}

export const tourStateNames = [
  'talk-waiting',
  'talk-listening',
  'talk-too-short',
  'talk-no-microphone',
  'talk-done',
  'show-screen-working',
  'show-screen-done',
  'hand-off-approval',
  'hand-off-done',
  'connect-apps',
  'connect-apps-done',
  'place-bar',
  'place-bar-done',
  'finished',
] as const;
export type TourStateName = (typeof tourStateNames)[number];

export function makeTourModel(stateName: TourStateName): TourModel {
  const model = new TourModel('controlAlt', 'bottom');
  model.permissionStatusesChanged({ microphone: 'granted' });
  const advanceTo = (lessonCount: number) => {
    for (let lessonIndex = 0; lessonIndex < lessonCount; lessonIndex += 1) model.skipCurrentLesson();
  };
  switch (stateName) {
    case 'talk-waiting':
      break;
    case 'talk-listening':
      model.shortcutPressed();
      break;
    case 'talk-too-short':
      model.shortcutPressed();
      model.shortcutReleased(0.1);
      break;
    case 'talk-no-microphone':
      model.permissionStatusesChanged({ microphone: 'deniedInSystemSettings' });
      break;
    case 'talk-done':
      model.shortcutPressed();
      model.shortcutReleased(1.4);
      model.apply({ kind: 'finished', finalText: 'I can answer questions, look at your screen and start agents.' });
      break;
    case 'show-screen-working':
      advanceTo(1);
      model.shortcutPressed();
      model.shortcutReleased(1.6);
      model.apply({ kind: 'toolStarted', callId: 'look', toolName: 'look_at_screen', activityLabel: 'Looking at your screen' });
      break;
    case 'show-screen-done':
      advanceTo(1);
      model.apply({ kind: 'toolFinished', callId: 'draw', toolName: 'draw_on_screen', isError: false });
      break;
    case 'hand-off-approval':
      advanceTo(2);
      model.shortcutPressed();
      model.shortcutReleased(2.1);
      model.approvalRequested('backgroundAgent');
      break;
    case 'hand-off-done':
      advanceTo(2);
      model.apply({ kind: 'toolFinished', callId: 'spawn', toolName: 'spawn_agent', isError: false });
      break;
    case 'connect-apps':
      advanceTo(3);
      break;
    case 'connect-apps-done':
      advanceTo(3);
      model.connectedAppsChanged(['Gmail']);
      break;
    case 'place-bar':
      advanceTo(4);
      break;
    case 'place-bar-done':
      advanceTo(4);
      model.dockEdgeChanged('left');
      break;
    case 'finished':
      advanceTo(5);
      break;
  }
  return model;
}
