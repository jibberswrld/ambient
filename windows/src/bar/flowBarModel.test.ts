import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ApprovalRequest, BackgroundTask } from '../host/contract';
import { FlowBarModel, presentationFollowsEdgeOrientation } from './flowBarModel';
import { formatElapsedTime } from './elapsedTime';

function makeModel(): FlowBarModel {
  const model = new FlowBarModel();
  model.revealsReplyInstantly = true;
  return model;
}

function makeApprovalRequest(overrides: Partial<ApprovalRequest> = {}): ApprovalRequest {
  return { requestId: crypto.randomUUID(), title: 'Run this command?', detail: 'git status', kind: 'shellCommand', ...overrides };
}

function makeBackgroundTask(overrides: Partial<BackgroundTask> = {}): BackgroundTask {
  return {
    id: crypto.randomUUID(),
    kind: 'codexAgent',
    title: 'Fix login test',
    status: 'running',
    workingDirectory: 'C:\\code',
    startedAt: new Date().toISOString(),
    finishedAt: null,
    latestActivity: 'Running tests',
    result: null,
    ...overrides,
  };
}

describe('FlowBarModel', () => {
  it('rests by default and hovers with the pointer', () => {
    const model = makeModel();
    expect(model.presentation).toBe('resting');
    model.setPointerHovering(true);
    expect(model.presentation).toBe('hovering');
    model.setPointerHovering(false);
    expect(model.presentation).toBe('resting');
  });

  it('runs a full voice turn', () => {
    const model = makeModel();
    model.beginListening();
    expect(model.presentation).toBe('listening');
    model.updateAudioLevel(1.7);
    expect(model.audioLevel).toBe(1);
    model.beginTranscribing();
    expect(model.presentation).toBe('transcribing');
    expect(model.audioLevel).toBe(0);
    model.beginThinking();
    expect(model.presentation).toBe('thinking');

    model.apply({ kind: 'toolStarted', callId: '1', toolName: 'gmail_search', activityLabel: 'Searching Gmail' });
    expect(model.presentation).toBe('working');
    expect(model.currentActivityLine).toBe('Searching Gmail');
    model.apply({ kind: 'toolFinished', callId: '1', toolName: 'gmail_search', isError: false });
    expect(model.toolCallsThisTurn[0]?.status).toBe('succeeded');

    model.apply({ kind: 'textDelta', text: 'You have ' });
    expect(model.presentation).toBe('responding');
    model.apply({ kind: 'textDelta', text: 'two new emails.' });
    expect(model.replyText).toBe('You have two new emails.');
    expect(model.displayedReplyText).toBe('You have two new emails.');

    model.apply({ kind: 'finished', finalText: 'You have two new emails.' });
    expect(model.presentation).toBe('reply');
    model.dismissReplyOrError();
    expect(model.presentation).toBe('resting');
    expect(model.replyText).toBe('');
  });

  it('keeps the reply on screen when a tool starts mid-reply', () => {
    const model = makeModel();
    model.apply({ kind: 'textDelta', text: 'Let me check.' });
    model.apply({ kind: 'toolStarted', callId: 'a', toolName: 'calendar_list', activityLabel: '' });
    expect(model.presentation).toBe('responding');
    expect(model.currentActivityLine).toBe('Calendar list');
  });

  it('turns failures into plain errors', () => {
    const model = makeModel();
    const topUpUrl = 'https://publik.example/top-up';
    model.apply({ kind: 'failed', failure: { kind: 'paymentRequired', message: "You have used this month's allowance.", topUpUrl } });
    expect(model.presentation).toBe('error');
    expect(model.currentErrorNotice?.link).toEqual({ title: 'Top up', destination: { kind: 'webPage', url: topUpUrl } });

    model.apply({ kind: 'failed', failure: { kind: 'notSignedIn' } });
    expect(model.currentErrorNotice?.link?.destination).toEqual({ kind: 'settings' });

    model.apply({ kind: 'failed', failure: { kind: 'cancelled' } });
    expect(model.presentation).toBe('resting');
  });

  it('opens the error link and clears', () => {
    const model = makeModel();
    let openedUrl: string | null = null;
    model.onOpenUrl = (url) => (openedUrl = url);
    model.showError({ message: 'Out of credit.', link: { title: 'Top up', destination: { kind: 'webPage', url: 'https://publik.example/top-up' } } });
    model.followErrorLink(model.currentErrorNotice!.link!);
    expect(openedUrl).toBe('https://publik.example/top-up');
    expect(model.presentation).toBe('resting');
  });

  it('shows an approval and reports the answer, then resumes the turn', () => {
    const model = makeModel();
    const answers: [string, boolean][] = [];
    model.onAnswerApproval = (requestId, isAllowed) => answers.push([requestId, isAllowed]);
    model.beginThinking();
    const request = makeApprovalRequest();
    model.requestApproval(request);
    expect(model.presentation).toBe('approval');
    model.answerPendingApproval(true);
    expect(answers).toEqual([[request.requestId, true]]);
    expect(model.presentation).toBe('thinking');
  });

  it('denies a pending approval when the turn is cancelled', () => {
    const model = makeModel();
    let didCancel = false;
    const answers: boolean[] = [];
    model.onCancelTurn = () => (didCancel = true);
    model.onAnswerApproval = (_requestId, isAllowed) => answers.push(isAllowed);
    model.requestApproval(makeApprovalRequest({ title: 'Start an agent?', detail: 'Fix the flaky test', kind: 'backgroundAgent' }));
    model.cancelCurrentTurn();
    expect(answers).toEqual([false]);
    expect(didCancel).toBe(true);
  });

  it('drops the card when the host withdraws the approval', () => {
    const model = makeModel();
    const request = makeApprovalRequest({ title: 'Run?', detail: 'dir' });
    model.requestApproval(request);
    expect(model.pendingApproval).not.toBeNull();
    model.approvalCancelled('some-other-request');
    expect(model.pendingApproval).not.toBeNull();
    model.approvalCancelled(request.requestId);
    expect(model.pendingApproval).toBeNull();
  });

  it('keeps thinking and tool activity visible through empty stream deltas', () => {
    const model = makeModel();
    model.beginThinking();
    model.apply({ kind: 'textDelta', text: '' });
    expect(model.presentation).toBe('thinking');
    model.apply({ kind: 'toolStarted', callId: 'search', toolName: 'web_search', activityLabel: 'Searching the web' });
    model.apply({ kind: 'textDelta', text: '' });
    expect(model.presentation).toBe('working');
    expect(model.currentActivityLine).toBe('Searching the web');
  });

  it('lets listening outrank typing', () => {
    const model = makeModel();
    model.beginTyping();
    expect(model.presentation).toBe('typing');
    model.beginListening();
    expect(model.presentation).toBe('listening');
    expect(model.isTyping).toBe(false);
  });

  it('submits typed text trimmed and never blank', () => {
    const model = makeModel();
    let submittedText: string | null = null;
    model.onSubmitTypedText = (text) => (submittedText = text);
    model.beginTyping();
    model.setTypedText('   ');
    model.submitTypedText();
    expect(submittedText).toBeNull();
    model.setTypedText("  what's on my calendar  ");
    model.submitTypedText();
    expect(submittedText).toBe("what's on my calendar");
    expect(model.presentation).toBe('thinking');
  });

  it('opens typing when continuing a reply', () => {
    const model = makeModel();
    model.apply({ kind: 'finished', finalText: 'Done.' });
    model.continueConversation();
    expect(model.presentation).toBe('typing');
  });

  it('reports typing changes so the window can take and give back keyboard focus', () => {
    const model = makeModel();
    const typingStates: boolean[] = [];
    model.onTypingStateChanged = (isTyping) => typingStates.push(isTyping);
    model.beginTyping();
    model.beginTyping();
    model.endTyping();
    expect(typingStates).toEqual([true, false]);
  });

  it('shows a notice when a task finishes while resting, and the tray closes with an empty list', () => {
    const model = makeModel();
    const runningTask = makeBackgroundTask();
    model.setBackgroundTasks([runningTask]);
    expect(model.presentation).toBe('resting');
    model.setBackgroundTasks([{ ...runningTask, status: 'succeeded', finishedAt: new Date().toISOString() }]);
    expect(model.presentation).toBe('taskFinishedNotice');
    model.toggleTaskTray();
    expect(model.presentation).toBe('taskTray');
    model.setBackgroundTasks([]);
    expect(model.presentation).toBe('resting');
  });

  it('passes task tray intents to the host', () => {
    const model = makeModel();
    const taskId = crypto.randomUUID();
    const received: string[] = [];
    model.onCancelBackgroundTask = (identifier) => received.push(`cancel ${identifier}`);
    model.onDismissBackgroundTask = (identifier) => received.push(`dismiss ${identifier}`);
    model.onOpenBackgroundTaskTranscript = (identifier) => received.push(`transcript ${identifier}`);
    model.cancelBackgroundTask(taskId);
    model.dismissBackgroundTask(taskId);
    model.openBackgroundTaskTranscript(taskId);
    expect(received).toEqual([`cancel ${taskId}`, `dismiss ${taskId}`, `transcript ${taskId}`]);
  });

  it('opens the right-click menu only from the quiet states', () => {
    const model = makeModel();
    model.openContextMenu();
    expect(model.presentation).toBe('contextMenu');
    let didOpenSettings = false;
    model.onOpenSettings = () => (didOpenSettings = true);
    model.openSettings();
    expect(didOpenSettings).toBe(true);
    expect(model.presentation).toBe('resting');
    model.beginThinking();
    model.openContextMenu();
    expect(model.presentation).toBe('thinking');
  });

  it('only rests and voice states stand upright on side edges', () => {
    expect(presentationFollowsEdgeOrientation('resting')).toBe(true);
    expect(presentationFollowsEdgeOrientation('listening')).toBe(true);
    expect(presentationFollowsEdgeOrientation('responding')).toBe(false);
    expect(presentationFollowsEdgeOrientation('taskTray')).toBe(false);
  });

  it('closes the tray when the last task is dismissed', () => {
    const model = makeModel();
    model.setBackgroundTasks([makeBackgroundTask({ kind: 'shellCommand', title: 'Tests', status: 'succeeded', result: 'All passed' })]);
    model.toggleTaskTray();
    expect(model.presentation).toBe('taskTray');
    model.setBackgroundTasks([]);
    expect(model.isTaskTrayExpanded).toBe(false);
    expect(model.presentation).toBe('resting');
  });

  it('approval outranks everything else and closes the text field', () => {
    const model = makeModel();
    model.beginTyping();
    model.requestApproval(makeApprovalRequest({ detail: 'dir' }));
    expect(model.presentation).toBe('approval');
    expect(model.isTyping).toBe(false);
  });

  it('a new approval replaces the one before it', () => {
    const model = makeModel();
    model.requestApproval(makeApprovalRequest({ title: 'First', kind: 'other' }));
    model.requestApproval(makeApprovalRequest({ title: 'Second', kind: 'other' }));
    expect(model.pendingApproval?.title).toBe('Second');
  });

  it('clears the last reply when a new turn begins', () => {
    const model = makeModel();
    model.apply({ kind: 'textDelta', text: 'Old answer' });
    model.apply({ kind: 'finished', finalText: 'Old answer' });
    model.beginListening();
    expect(model.replyText).toBe('');
    expect(model.toolCallsThisTurn).toEqual([]);
    expect(model.presentation).toBe('listening');
  });

  it('lets transcribing be its own presentation and silences the level', () => {
    const model = makeModel();
    model.beginListening();
    model.updateAudioLevel(0.8);
    model.beginTranscribing();
    expect(model.presentation).toBe('transcribing');
    expect(model.audioLevel).toBe(0);
    model.updateAudioLevel(-3);
    expect(model.audioLevel).toBe(0);
  });

  it('goes straight back to rest after an empty finished turn', () => {
    const model = makeModel();
    model.beginThinking();
    model.apply({ kind: 'finished', finalText: '   ' });
    expect(model.presentation).toBe('resting');
  });

  it('links the signed-out error to Settings', () => {
    const model = makeModel();
    let didOpenSettings = false;
    model.onOpenSettings = () => (didOpenSettings = true);
    model.apply({ kind: 'failed', failure: { kind: 'notSignedIn' } });
    expect(model.presentation).toBe('error');
    const link = model.currentErrorNotice?.link;
    expect(link?.destination).toEqual({ kind: 'settings' });
    model.followErrorLink(link!);
    expect(didOpenSettings).toBe(true);
    expect(model.presentation).toBe('resting');
  });
});

describe('FlowBarModel timing', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('returns a finished reply to rest after its linger', () => {
    const model = makeModel();
    model.finishedReplyLingerSeconds = 0.05;
    model.apply({ kind: 'textDelta', text: 'Done.' });
    model.apply({ kind: 'finished', finalText: 'Done.' });
    expect(model.presentation).toBe('reply');
    vi.advanceTimersByTime(200);
    expect(model.presentation).toBe('resting');
  });

  it('holds a reply on screen while it is hovered', () => {
    const model = makeModel();
    model.finishedReplyLingerSeconds = 0.05;
    model.apply({ kind: 'textDelta', text: 'Done.' });
    model.apply({ kind: 'finished', finalText: 'Done.' });
    model.setPointerHovering(true);
    vi.advanceTimersByTime(200);
    expect(model.presentation).toBe('reply');
    model.setPointerHovering(false);
    vi.advanceTimersByTime(200);
    expect(model.presentation).toBe('resting');
  });

  it('keeps a reply until dismissed when the linger is zero', () => {
    const model = makeModel();
    model.finishedReplyLingerSeconds = 0;
    model.apply({ kind: 'finished', finalText: 'Done.' });
    vi.advanceTimersByTime(100);
    expect(model.presentation).toBe('reply');
  });

  it('hides the task finished notice after its duration', () => {
    const model = makeModel();
    const runningTask = makeBackgroundTask();
    model.setBackgroundTasks([runningTask]);
    model.setBackgroundTasks([{ ...runningTask, status: 'failed' }]);
    expect(model.presentation).toBe('taskFinishedNotice');
    vi.advanceTimersByTime(5100);
    expect(model.presentation).toBe('resting');
  });

  it('paces the reveal and catches up with the whole reply', () => {
    const model = new FlowBarModel();
    model.apply({ kind: 'textDelta', text: 'word '.repeat(60) });
    expect(model.displayedReplyText.length).toBeLessThan(model.replyText.length);
    for (let frame = 0; frame < 200 && model.displayedReplyText !== model.replyText; frame += 1) vi.advanceTimersByTime(16);
    expect(model.displayedReplyText).toBe(model.replyText);
  });
});

describe('formatElapsedTime', () => {
  it('formats minutes and hours', () => {
    const start = new Date(0);
    expect(formatElapsedTime(start, new Date(42_000))).toBe('0:42');
    expect(formatElapsedTime(start, new Date(725_000))).toBe('12:05');
    expect(formatElapsedTime(start, new Date(3_729_000))).toBe('1:02:09');
  });
});
