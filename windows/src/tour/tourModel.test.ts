import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { DockEdge, PermissionStatuses } from '../host/contract';
import {
  TourModel,
  allTourLessons,
  isVoiceLesson,
  listedAppNames,
  readableToolName,
  tourLessonBodyText,
  tourLessonNumber,
  tourLessonRequiredPermissions,
  tourLessonSkipTitle,
  tourLessonSuggestedPhrase,
  type TourLesson,
  type TourPermission,
  type TourStatus,
} from './tourModel';

const allPermissionsGranted: PermissionStatuses = { microphone: 'granted' };

function makeTour(lesson: TourLesson = 'talk', dockEdge: DockEdge = 'bottom'): TourModel {
  const tourModel = new TourModel('controlAlt', dockEdge);
  // Long enough that the idle hint never fires during a test that is not about it.
  tourModel.idleHintDelaySeconds = 60;
  tourModel.permissionStatusesChanged(allPermissionsGranted);
  while (tourModel.currentLesson !== lesson) tourModel.skipCurrentLesson();
  return tourModel;
}

/** A complete spoken turn that ends with a reply. */
function speakAndGetReply(tourModel: TourModel, tools: { name: string; isError: boolean }[] = []): void {
  tourModel.shortcutPressed();
  tourModel.shortcutReleased(1.5);
  tourModel.thinkingStarted();
  tools.forEach((tool, index) => {
    tourModel.apply({ kind: 'toolStarted', callId: `${index}`, toolName: tool.name, activityLabel: '' });
    tourModel.apply({ kind: 'toolFinished', callId: `${index}`, toolName: tool.name, isError: tool.isError });
  });
  tourModel.apply({ kind: 'textDelta', text: 'Here you go.' });
  tourModel.apply({ kind: 'finished', finalText: 'Here you go.' });
}

function expectedStatus(tone: TourStatus['tone'], text: string, action: TourStatus['action'] = null): TourStatus {
  return { tone, text, action };
}

describe('order and navigation', () => {
  it('starts on talking and walks through every lesson to the finish', () => {
    const tourModel = new TourModel();
    expect(tourModel.step).toEqual({ kind: 'lesson', lesson: 'talk' });
    const visitedLessons: TourLesson[] = [];
    while (tourModel.currentLesson !== null) {
      visitedLessons.push(tourModel.currentLesson);
      tourModel.skipCurrentLesson();
    }
    expect(visitedLessons).toEqual(['talk', 'showScreen', 'handOff', 'connectApps', 'placeBar']);
    expect(visitedLessons).toEqual(allTourLessons);
    expect(tourModel.step).toEqual({ kind: 'finished' });
  });

  it('shows Next only once the lesson is done and then moves on', () => {
    const tourModel = makeTour();
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    speakAndGetReply(tourModel);
    expect(tourModel.isCurrentLessonComplete).toBe(true);
    // A finished lesson waits for Next instead of advancing under the reply.
    expect(tourModel.step).toEqual({ kind: 'lesson', lesson: 'talk' });
    tourModel.advanceToNextStep();
    expect(tourModel.step).toEqual({ kind: 'lesson', lesson: 'showScreen' });
    expect(tourModel.isCurrentLessonComplete).toBe(false);
  });

  it('reports finish when ended from any lesson and from the last card', () => {
    let finishCount = 0;
    const midwayTour = makeTour('handOff');
    midwayTour.onFinish = () => {
      finishCount += 1;
    };
    midwayTour.endTour();
    const finishedTour = makeTour('placeBar');
    finishedTour.onFinish = () => {
      finishCount += 1;
    };
    finishedTour.skipCurrentLesson();
    expect(finishedTour.step).toEqual({ kind: 'finished' });
    finishedTour.endTour();
    expect(finishCount).toBe(2);
  });

  it('gives the optional lessons skip titles that sound optional', () => {
    expect(tourLessonSkipTitle('talk')).toBe('Skip');
    expect(tourLessonSkipTitle('connectApps')).toBe('Later');
    expect(tourLessonSkipTitle('placeBar')).toBe("It's fine here");
  });
});

describe('lesson facts', () => {
  it('numbers lessons from one', () => {
    expect(allTourLessons.map(tourLessonNumber)).toEqual([1, 2, 3, 4, 5]);
  });

  it('names the shortcut keys in the talk lesson as a sentence', () => {
    expect(tourLessonBodyText('talk', 'controlAlt')).toBe(
      'Hold Ctrl and Alt, say anything, then let go. The answer shows up in the bar.',
    );
    expect(tourLessonBodyText('talk', 'controlShift')).toContain('Hold Ctrl and Shift,');
  });

  it('suggests a Windows phrase for the screen lesson and none for the optional lessons', () => {
    expect(tourLessonSuggestedPhrase('showScreen')).toBe('Show me where the Start button is.');
    expect(tourLessonSuggestedPhrase('connectApps')).toBeNull();
    expect(tourLessonSuggestedPhrase('placeBar')).toBeNull();
  });

  it('requires only the microphone, and only for the voice lessons', () => {
    for (const lesson of allTourLessons) {
      expect(tourLessonRequiredPermissions(lesson)).toEqual(isVoiceLesson(lesson) ? ['microphone'] : []);
    }
    expect(allTourLessons.filter(isVoiceLesson)).toEqual(['talk', 'showScreen', 'handOff']);
  });

  it('turns snake and kebab tool names into readable words', () => {
    expect(readableToolName('gmail_search_threads')).toBe('Gmail search threads');
    expect(readableToolName('calendar-list-EVENTS')).toBe('Calendar list events');
    expect(readableToolName('')).toBe('');
  });
});

describe('lesson 1: talk', () => {
  it('completes on a spoken turn with a reply', () => {
    const tourModel = makeTour();
    speakAndGetReply(tourModel);
    expect(tourModel.isCurrentLessonComplete).toBe(true);
    expect(tourModel.status.tone).toBe('done');
    expect(tourModel.completionNote).not.toBeNull();
    tourModel.advanceToNextStep();
    // A new lesson shows its instructions again.
    expect(tourModel.completionNote).toBeNull();
  });

  it('does not complete on a typed turn and asks for the voice', () => {
    const tourModel = makeTour();
    tourModel.typedRequestSubmitted();
    tourModel.apply({ kind: 'textDelta', text: 'Hi.' });
    tourModel.apply({ kind: 'finished', finalText: 'Hi.' });
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    expect(tourModel.status).toEqual(expectedStatus('nudge', 'Typing works too. Now try it with your voice.'));
  });

  it('lights the keys and says listening while they are held', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    expect(tourModel.isShortcutHeld).toBe(true);
    expect(tourModel.status).toEqual(expectedStatus('listening', 'Listening…'));
    tourModel.shortcutReleased(1.2);
    expect(tourModel.isShortcutHeld).toBe(false);
    expect(tourModel.status).toEqual(expectedStatus('working', 'Thinking…'));
  });

  it('acknowledges the first words of a reply', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(1.2);
    tourModel.apply({ kind: 'textDelta', text: 'I' });
    expect(tourModel.status).toEqual(expectedStatus('working', 'Here it comes. The answer is in the bar.'));
  });

  it('names a tool in use in the status line', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(1.2);
    tourModel.apply({ kind: 'toolStarted', callId: '1', toolName: 'web_search', activityLabel: 'Searching the web' });
    expect(tourModel.status.text).toBe('Searching the web…');
    tourModel.apply({ kind: 'toolStarted', callId: '2', toolName: 'gmail_search_threads', activityLabel: '' });
    // A tool without a label gets a readable name.
    expect(tourModel.status.text).toBe('Gmail search threads…');
  });

  it('nudges to keep the keys held after a brief tap', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(0.2);
    expect(tourModel.status).toEqual(expectedStatus('nudge', 'Keep both keys held while you talk.'));
    tourModel.heardNothing();
    // The tap is the real reason nothing was heard.
    expect(tourModel.status.text).toBe('Keep both keys held while you talk.');
    expect(tourModel.isCurrentLessonComplete).toBe(false);
  });

  it('does not treat a hold just long enough as a tap', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(TourModel.shortestRealHoldDurationSeconds);
    expect(tourModel.status.tone).toBe('working');
  });

  it('says so when a recording has nothing in it', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(1.5);
    tourModel.heardNothing();
    expect(tourModel.status).toEqual(
      expectedStatus('nudge', "I didn't catch anything. Hold the keys and speak, then let go."),
    );
  });

  it('ignores heard-nothing once a new hold has started', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.heardNothing();
    expect(tourModel.status.tone).toBe('listening');
  });

  it('shows the plain reason for a failed turn and try again clears it', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(1.5);
    tourModel.apply({ kind: 'failed', failure: { kind: 'other', message: 'Ambient could not reach the internet.' } });
    expect(tourModel.status).toEqual(
      expectedStatus('problem', 'Ambient could not reach the internet.', { kind: 'tryAgain' }),
    );
    tourModel.performStatusAction({ kind: 'tryAgain' });
    expect(tourModel.status).toEqual(expectedStatus('waiting', 'Waiting for you to hold the keys.'));
  });

  it('says where to sign in after a signed-out failure', () => {
    const tourModel = makeTour();
    tourModel.apply({ kind: 'failed', failure: { kind: 'notSignedIn' } });
    expect(tourModel.status.tone).toBe('problem');
    expect(tourModel.status.action).toEqual({ kind: 'tryAgain' });
  });

  it('goes quiet on a cancelled turn without losing an unread nudge', () => {
    const tourModel = makeTour();
    tourModel.shortcutPressed();
    tourModel.apply({ kind: 'failed', failure: { kind: 'cancelled' } });
    expect(tourModel.status.tone).toBe('waiting');
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(0.1);
    tourModel.apply({ kind: 'failed', failure: { kind: 'cancelled' } });
    expect(tourModel.status.tone).toBe('nudge');
  });

  it('names a missing microphone with a button that fixes it', () => {
    const tourModel = makeTour();
    const fixedPermissions: TourPermission[] = [];
    tourModel.onFixPermission = (permission) => {
      fixedPermissions.push(permission);
    };
    tourModel.permissionStatusesChanged({ microphone: 'deniedInSystemSettings' });
    expect(tourModel.status).toEqual(
      expectedStatus('problem', 'Ambient needs the microphone to hear you.', {
        kind: 'fixPermission',
        permission: 'microphone',
        permissionStatus: 'deniedInSystemSettings',
      }),
    );
    tourModel.shortcutPressed();
    // Nothing else can work until the microphone is back.
    expect(tourModel.status.tone).toBe('problem');
    const action = tourModel.status.action;
    if (action !== null) tourModel.performStatusAction(action);
    expect(fixedPermissions).toEqual(['microphone']);
    tourModel.permissionStatusesChanged({ microphone: 'granted' });
    expect(tourModel.status.tone).toBe('listening');
  });

  // Swift: testMissingAccessibilityBlocksTheVoiceLessonsBecauseTheKeysCannotBeHeard. Windows has no Accessibility
  // permission, so this keeps the intent that the fix action carries the current status (Allow vs Open settings).
  it('carries a never-asked microphone status so the fix button can say Allow', () => {
    const tourModel = makeTour();
    tourModel.permissionStatusesChanged({ microphone: 'notYetAsked' });
    expect(tourModel.status.action).toEqual({
      kind: 'fixPermission',
      permission: 'microphone',
      permissionStatus: 'notYetAsked',
    });
  });

  it('never assumes unreported permissions are missing', () => {
    const tourModel = new TourModel();
    expect(tourModel.status.tone).toBe('waiting');
    tourModel.permissionStatusesChanged({ microphone: 'waiting' });
    expect(tourModel.status.tone).toBe('problem');
    tourModel.permissionStatusesChanged(null);
    expect(tourModel.status.tone).toBe('waiting');
  });
});

describe('lesson 2: show it your screen', () => {
  it.each(['look_at_screen', 'draw_on_screen', 'point_at'])('completes when Ambient uses %s', (screenToolName) => {
    const tourModel = makeTour('showScreen');
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(1.5);
    tourModel.apply({ kind: 'toolStarted', callId: '1', toolName: screenToolName, activityLabel: '' });
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: screenToolName, isError: false });
    expect(tourModel.isCurrentLessonComplete).toBe(true);
    expect(tourModel.status).toEqual(expectedStatus('done', 'Done. Ambient saw your screen.'));
    expect(tourModel.completionNote).toBe('The drawing clears when you make your next request.');
  });

  it('does not complete when a screen tool fails', () => {
    const tourModel = makeTour('showScreen');
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: 'look_at_screen', isError: true });
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    expect(tourModel.status.tone).toBe('problem');
    expect(tourModel.status.action).toEqual({ kind: 'tryAgain' });
  });

  it('nudges without blocking after a regular answer', () => {
    const tourModel = makeTour('showScreen');
    speakAndGetReply(tourModel, [{ name: 'web_search', isError: false }]);
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    // The coach stays on the lesson.
    expect(tourModel.step).toEqual({ kind: 'lesson', lesson: 'showScreen' });
    expect(tourModel.status).toEqual(
      expectedStatus('nudge', 'That was a regular answer. To use your screen, try the phrase above.'),
    );
  });

  // Swift: testMissingScreenRecordingIsTheProblemNamedForTheScreenLesson. Windows needs no Screen Recording
  // permission; the microphone is the blocker for every voice lesson and for none of the optional ones.
  it('names a missing microphone on the screen lesson but not on the lessons that need no voice', () => {
    const missingMicrophone: PermissionStatuses = { microphone: 'notYetAsked' };
    const tourModel = makeTour('showScreen');
    tourModel.permissionStatusesChanged(missingMicrophone);
    expect(tourModel.status).toEqual(
      expectedStatus('problem', 'Ambient needs the microphone to hear you.', {
        kind: 'fixPermission',
        permission: 'microphone',
        permissionStatus: 'notYetAsked',
      }),
    );
    for (const lessonWithoutVoice of ['connectApps', 'placeBar'] as const) {
      const optionalLessonTour = makeTour(lessonWithoutVoice);
      optionalLessonTour.permissionStatusesChanged(missingMicrophone);
      expect(optionalLessonTour.status.tone).toBe('waiting');
    }
  });

  it('completes only on the lesson’s own tool', () => {
    const tourModel = makeTour('showScreen');
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: 'spawn_agent', isError: false });
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    const talkTour = makeTour('talk');
    talkTour.apply({ kind: 'toolFinished', callId: '1', toolName: 'look_at_screen', isError: false });
    // Talking completes on a reply, not a tool.
    expect(talkTour.isCurrentLessonComplete).toBe(false);
  });
});

describe('lesson 3: hand off a job', () => {
  it('completes when an agent starts', () => {
    const tourModel = makeTour('handOff');
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(2);
    tourModel.approvalRequested('backgroundAgent');
    expect(tourModel.status).toEqual(
      expectedStatus('nudge', 'Ambient asks before it starts work. Press Allow in the bar.'),
    );
    tourModel.approvalAnswered(true);
    expect(tourModel.status).toEqual(expectedStatus('working', 'Starting the agent…'));
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: 'spawn_agent', isError: false });
    expect(tourModel.isCurrentLessonComplete).toBe(true);
    expect(tourModel.status.text).toBe('Done. Your agent is working.');
    expect(tourModel.completionNote).toBe(
      'The dot in the bar is your agent working. Click the bar to see it. You can keep going.',
    );
  });

  it('also completes when an agent starts without being asked', () => {
    const tourModel = makeTour('handOff');
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: 'spawn_agent', isError: false });
    // Allow without asking skips the approval card.
    expect(tourModel.isCurrentLessonComplete).toBe(true);
  });

  it('offers to try again after a denial and keeps that through the rest of the turn', () => {
    const tourModel = makeTour('handOff');
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(2);
    tourModel.approvalRequested('backgroundAgent');
    tourModel.approvalAnswered(false);
    const deniedStatus = expectedStatus('nudge', "No agent started. Ask again when you're ready, then press Allow.");
    expect(tourModel.status).toEqual(deniedStatus);
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: 'spawn_agent', isError: true });
    tourModel.apply({ kind: 'textDelta', text: "Okay, I won't start it." });
    tourModel.apply({ kind: 'finished', finalText: "Okay, I won't start it." });
    // The denial explanation is not replaced by a generic one.
    expect(tourModel.status.text).toBe(deniedStatus.text);
    expect(tourModel.isCurrentLessonComplete).toBe(false);
  });

  it('treats an agent that fails to start as a problem', () => {
    const tourModel = makeTour('handOff');
    tourModel.apply({ kind: 'toolFinished', callId: '1', toolName: 'spawn_agent', isError: true });
    expect(tourModel.status.tone).toBe('problem');
    expect(tourModel.isCurrentLessonComplete).toBe(false);
  });

  it('does not explain a shell command approval as an agent', () => {
    const tourModel = makeTour('handOff');
    tourModel.approvalRequested('shellCommand');
    expect(tourModel.status.tone).toBe('waiting');
  });

  it('leaves an approval outside the hand-off lesson to the bar', () => {
    const tourModel = makeTour('talk');
    tourModel.approvalRequested('backgroundAgent');
    expect(tourModel.status.tone).toBe('waiting');
  });

  it('nudges toward the agent phrase after a quick answer', () => {
    const tourModel = makeTour('handOff');
    speakAndGetReply(tourModel);
    expect(tourModel.status.tone).toBe('nudge');
    expect(tourModel.status.text).toContain('Start an agent to');
  });
});

describe('lesson 4: connect your apps', () => {
  it('completes when an app is connected', () => {
    const tourModel = makeTour('connectApps');
    let openedConnectors = false;
    tourModel.onOpenConnectors = () => {
      openedConnectors = true;
    };
    expect(tourModel.status.text).toBe('No apps connected yet.');
    tourModel.openConnectors();
    expect(openedConnectors).toBe(true);
    expect(tourModel.hasOpenedConnectors).toBe(true);
    expect(tourModel.status.text).toBe('Waiting for you to finish in the browser.');
    tourModel.connectedAppsChanged([]);
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    tourModel.connectedAppsChanged(['Gmail']);
    expect(tourModel.isCurrentLessonComplete).toBe(true);
    expect(tourModel.status.text).toBe('Gmail is connected.');
  });

  it('lists connected apps briefly', () => {
    expect(listedAppNames(['Gmail', 'Calendar'])).toBe('Gmail and Calendar are');
    expect(listedAppNames(['Gmail', 'Calendar', 'Slack', 'Notion'])).toBe('Gmail, Calendar and 2 more are');
  });

  it('moves on with Later', () => {
    const tourModel = makeTour('connectApps');
    tourModel.skipCurrentLesson();
    expect(tourModel.step).toEqual({ kind: 'lesson', lesson: 'placeBar' });
  });

  it('does not complete the wrong lesson when an app is connected earlier in the tour', () => {
    const tourModel = makeTour('talk');
    tourModel.connectedAppsChanged(['Gmail']);
    expect(tourModel.isCurrentLessonComplete).toBe(false);
  });
});

describe('lesson 5: put it where you like', () => {
  it('completes when the bar moves to another edge', () => {
    const tourModel = makeTour('placeBar', 'bottom');
    expect(tourModel.status.text).toBe('The bar is on the bottom edge.');
    tourModel.dockEdgeChanged('bottom');
    // Landing back on the same edge is not a change.
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    tourModel.dockEdgeChanged('left');
    expect(tourModel.isCurrentLessonComplete).toBe(true);
    expect(tourModel.status.text).toBe('The bar is on the left edge now.');
  });

  it('starts the lesson from the edge the bar is on at that moment', () => {
    const tourModel = makeTour('connectApps', 'bottom');
    tourModel.dockEdgeChanged('right');
    // Moving the bar during another lesson completes nothing.
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    tourModel.skipCurrentLesson();
    expect(tourModel.status.text).toBe('The bar is on the right edge.');
    tourModel.dockEdgeChanged('right');
    expect(tourModel.isCurrentLessonComplete).toBe(false);
    tourModel.dockEdgeChanged('top');
    expect(tourModel.isCurrentLessonComplete).toBe(true);
  });

  it("moves on to the finish with It's fine here", () => {
    const tourModel = makeTour('placeBar');
    tourModel.skipCurrentLesson();
    expect(tourModel.step).toEqual({ kind: 'finished' });
  });
});

describe('idle hint', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('gives one gentle hint after a quiet spell and no more', () => {
    const tourModel = makeTour();
    tourModel.idleHintDelaySeconds = 0.05;
    tourModel.begin();
    vi.advanceTimersByTime(200);
    expect(tourModel.status).toEqual(
      expectedStatus('nudge', 'Press both keys first and keep them down, then start talking.'),
    );
    tourModel.performStatusAction({ kind: 'tryAgain' });
    vi.advanceTimersByTime(200);
    // The hint is shown once per lesson, not repeated.
    expect(tourModel.status.tone).toBe('waiting');
  });

  it('is postponed by activity', () => {
    const tourModel = makeTour();
    tourModel.idleHintDelaySeconds = 0.15;
    tourModel.begin();
    vi.advanceTimersByTime(100);
    tourModel.shortcutPressed();
    vi.advanceTimersByTime(300);
    // No hint while the keys are held.
    expect(tourModel.status.tone).toBe('listening');
  });

  it('gives each lesson its own hint', () => {
    const tourModel = makeTour('placeBar');
    tourModel.idleHintDelaySeconds = 0.05;
    tourModel.begin();
    vi.advanceTimersByTime(200);
    expect(tourModel.status.text).toBe('Grab the small bar and drag it toward another edge.');
  });

  it('gives no hint once the lesson is done', () => {
    const tourModel = makeTour();
    tourModel.idleHintDelaySeconds = 0.05;
    speakAndGetReply(tourModel);
    vi.advanceTimersByTime(200);
    expect(tourModel.status.tone).toBe('done');
  });

  it('stops the hint clock when the tour ends', () => {
    const tourModel = makeTour();
    tourModel.idleHintDelaySeconds = 0.05;
    tourModel.begin();
    tourModel.endTour();
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('subscribing', () => {
  it('tells listeners about every change and bumps the version until they unsubscribe', () => {
    const tourModel = makeTour();
    let notificationCount = 0;
    const unsubscribe = tourModel.subscribe(() => {
      notificationCount += 1;
    });
    const versionBeforeChanges = tourModel.version;
    tourModel.shortcutPressed();
    tourModel.shortcutReleased(1.5);
    tourModel.dockEdgeChanged('top');
    tourModel.shortcut = 'controlShift';
    expect(notificationCount).toBe(4);
    expect(tourModel.version).toBe(versionBeforeChanges + 4);
    unsubscribe();
    tourModel.advanceToNextStep();
    expect(notificationCount).toBe(4);
  });

  it('tells listeners when the idle hint appears on its own', () => {
    vi.useFakeTimers();
    try {
      const tourModel = makeTour();
      tourModel.idleHintDelaySeconds = 0.05;
      tourModel.begin();
      let notificationCount = 0;
      tourModel.subscribe(() => {
        notificationCount += 1;
      });
      vi.advanceTimersByTime(200);
      expect(notificationCount).toBe(1);
    } finally {
      vi.useRealTimers();
    }
  });
});
