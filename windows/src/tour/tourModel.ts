import type {
  AgentEvent,
  ApprovalKind,
  DockEdge,
  PermissionStatus,
  PermissionStatuses,
  PushToTalkShortcut,
} from '../host/contract';
import { keycapLabels } from '../design/shortcuts';

// The guided tour teaches Ambient on the person's real desktop with the real bar. A small coach card watches what
// actually happens (keys, turns, tools, approvals, the bar's edge) and reacts to it. Nothing is simulated: the app
// feeds real events into `TourModel`, which decides what the coach says. Ported from the Mac `AmbientTourModel`.

// ---------------------------------------------------------------------------------------------------------------------
// Lessons
// ---------------------------------------------------------------------------------------------------------------------

/** One thing the tour teaches. Each one is completed by doing it for real. */
export type TourLesson = 'talk' | 'showScreen' | 'handOff' | 'connectApps' | 'placeBar';

/** Every lesson, in the order the tour teaches them. */
export const allTourLessons: readonly TourLesson[] = ['talk', 'showScreen', 'handOff', 'connectApps', 'placeBar'];

/** Windows has exactly one permission Ambient needs, so a permission is named by its key in `PermissionStatuses`. */
export type TourPermission = keyof PermissionStatuses;

/** 1-based, for "2 of 5". */
export function tourLessonNumber(lesson: TourLesson): number {
  return allTourLessons.indexOf(lesson) + 1;
}

export function tourLessonTitle(lesson: TourLesson): string {
  switch (lesson) {
    case 'talk':
      return 'Talk to it';
    case 'showScreen':
      return 'Show it your screen';
    case 'handOff':
      return 'Hand off a job';
    case 'connectApps':
      return 'Connect your apps';
    case 'placeBar':
      return 'Put it where you like';
  }
}

export function tourLessonBodyText(lesson: TourLesson, shortcut: PushToTalkShortcut): string {
  switch (lesson) {
    case 'talk': {
      // "Ctrl and Alt" reads as a sentence; the "Ctrl + Alt" form is for keycaps and tooltips.
      const shortcutKeysAsSentence = keycapLabels(shortcut).join(' and ');
      return `Hold ${shortcutKeysAsSentence}, say anything, then let go. The answer shows up in the bar.`;
    }
    case 'showScreen':
      return 'Ask about something on your screen. Ambient looks, then points or draws to show you.';
    case 'handOff':
      return 'Ask for something that takes a while. An agent works on it in the background while you keep going.';
    case 'connectApps':
      return 'Link Gmail, Calendar and other apps so Ambient can read and act in them for you.';
    case 'placeBar':
      return 'Drag the bar to any edge of your screen. It stays where you leave it.';
  }
}

/** What to say out loud, shown as something to say rather than a button that does it for them. */
export function tourLessonSuggestedPhrase(lesson: TourLesson): string | null {
  switch (lesson) {
    case 'talk':
      return 'What can you help me with?';
    case 'showScreen':
      return 'Show me where the Start button is.';
    case 'handOff':
      return 'Start an agent to find three good pizza places near me.';
    case 'connectApps':
    case 'placeBar':
      return null;
  }
}

/** The quiet way past the lesson. The optional lessons say so in their own words. */
export function tourLessonSkipTitle(lesson: TourLesson): string {
  switch (lesson) {
    case 'talk':
    case 'showScreen':
    case 'handOff':
      return 'Skip';
    case 'connectApps':
      return 'Later';
    case 'placeBar':
      return "It's fine here";
  }
}

/** Lessons completed by speaking to Ambient. The coach follows the voice turn on these. */
export function isVoiceLesson(lesson: TourLesson): boolean {
  switch (lesson) {
    case 'talk':
    case 'showScreen':
    case 'handOff':
      return true;
    case 'connectApps':
    case 'placeBar':
      return false;
  }
}

/**
 * Permissions without which the lesson cannot work. On Windows the push-to-talk keys and screen capture need no
 * permission, so every voice lesson needs only the microphone.
 */
export function tourLessonRequiredPermissions(lesson: TourLesson): TourPermission[] {
  return isVoiceLesson(lesson) ? ['microphone'] : [];
}

export function missingPermissionText(permission: TourPermission): string {
  switch (permission) {
    case 'microphone':
      return 'Ambient needs the microphone to hear you.';
  }
}

/** "Gmail is", "Gmail and Calendar are", "Gmail, Calendar and 2 more are". */
export function listedAppNames(appNames: readonly string[]): string {
  switch (appNames.length) {
    case 0:
      return 'An app is';
    case 1:
      return `${appNames[0]} is`;
    case 2:
      return `${appNames[0]} and ${appNames[1]} are`;
    default:
      return `${appNames[0]}, ${appNames[1]} and ${appNames.length - 2} more are`;
  }
}

/** "gmail_search_threads" becomes "Gmail search threads", for tools that give no activity label. */
export function readableToolName(toolName: string): string {
  const words = toolName.replaceAll('_', ' ').replaceAll('-', ' ');
  if (words.length === 0) return toolName;
  return words.charAt(0).toUpperCase() + words.slice(1).toLowerCase();
}

// ---------------------------------------------------------------------------------------------------------------------
// Step and status
// ---------------------------------------------------------------------------------------------------------------------

/** Where the tour is: on a lesson, or on the closing cheat sheet. */
export type TourStep = { kind: 'lesson'; lesson: TourLesson } | { kind: 'finished' };

/**
 * waiting: nothing has happened yet; the coach is waiting for the person.
 * listening: the keys are held and Ambient is listening.
 * working: Ambient is thinking, using a tool or answering.
 * nudge: a gentle pointer toward the lesson. Never a scolding.
 * problem: something is in the way; usually comes with an action that fixes it.
 * done: the lesson is done.
 */
export type TourStatusTone = 'waiting' | 'listening' | 'working' | 'nudge' | 'problem' | 'done';

/** `fixPermission` carries the current status so the button can say Allow (never asked) or Open settings (denied). */
export type TourStatusAction =
  | { kind: 'fixPermission'; permission: TourPermission; permissionStatus: PermissionStatus }
  | { kind: 'tryAgain' };

/** The coach's live line: what is happening right now, in a few words. */
export interface TourStatus {
  tone: TourStatusTone;
  text: string;
  action: TourStatusAction | null;
}

function makeTourStatus(tone: TourStatusTone, text: string, action: TourStatusAction | null = null): TourStatus {
  return { tone, text, action };
}

// ---------------------------------------------------------------------------------------------------------------------
// The state machine
// ---------------------------------------------------------------------------------------------------------------------

/**
 * The tour's state machine. The app feeds it real events; the coach card draws `step`, `status` and
 * `isCurrentLessonComplete`, and hears intent back through the `on…` callbacks. It never touches windows, so every
 * rule can be tested on its own. React reads it through `subscribe` and `version` (useSyncExternalStore).
 */
export class TourModel {
  /** A hold shorter than this is a brush of the keys, not someone talking. */
  static readonly shortestRealHoldDurationSeconds = 0.35;
  /** Tools that mean Ambient looked at or marked up the screen. */
  static readonly screenToolNames: ReadonlySet<string> = new Set(['look_at_screen', 'draw_on_screen', 'point_at']);
  static readonly spawnAgentToolName = 'spawn_agent';

  // State the coach draws -------------------------------------------------------------------------------------------

  private currentStep: TourStep = { kind: 'lesson', lesson: 'talk' };
  private currentLessonIsComplete = false;
  private shortcutIsHeld = false;
  private currentShortcut: PushToTalkShortcut;
  private currentDockEdge: DockEdge;
  private currentPermissionStatuses: PermissionStatuses | null = null;
  private currentConnectedAppNames: string[] = [];
  private connectorsWereOpened = false;

  /** Bumped on every state change, so React's useSyncExternalStore has a cheap snapshot to compare. */
  version = 0;

  // Behaviour -------------------------------------------------------------------------------------------------------

  /** How long the coach waits without any sign of the person before offering one hint. */
  idleHintDelaySeconds = 20;

  // Intents the app handles -----------------------------------------------------------------------------------------

  /** Fix a missing permission: ask Windows, or open the privacy settings when it has already been asked. */
  onFixPermission: ((permission: TourPermission) => void) | null = null;
  /** Open Settings on the Connectors page. */
  onOpenConnectors: (() => void) | null = null;
  /** The tour ended, finished or not. The app records completion and closes the coach. */
  onFinish: (() => void) | null = null;
  /** The person moved past a lesson, done or skipped. The app records it as an anonymous usage event. */
  onLessonEnded: ((lesson: TourLesson, result: 'completed' | 'skipped') => void) | null = null;

  // Private ---------------------------------------------------------------------------------------------------------

  /** What the current turn is doing, set by events. Null means nothing is happening and the lesson's resting line shows. */
  private activityStatus: TourStatus | null = null;
  private currentTurnWasTyped = false;
  private lastHoldWasTooShort = false;
  private approvalWasDeniedThisTurn = false;
  private hasAcknowledgedReplyThisTurn = false;
  private dockEdgeWhenLessonBegan: DockEdge;
  private hasShownIdleHintThisLesson = false;
  private idleHintTimeoutHandle: ReturnType<typeof setTimeout> | null = null;
  private readonly listeners = new Set<() => void>();

  constructor(shortcut: PushToTalkShortcut = 'controlAlt', dockEdge: DockEdge = 'bottom') {
    this.currentShortcut = shortcut;
    this.currentDockEdge = dockEdge;
    this.dockEdgeWhenLessonBegan = dockEdge;
  }

  /** Starts the idle-hint clock for the first lesson. Call once the coach is on screen. */
  begin(): void {
    this.scheduleIdleHint();
  }

  /** Calls `listener` after every state change. Returns the function that stops it. */
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  // Read-only state -------------------------------------------------------------------------------------------------

  get step(): TourStep {
    return this.currentStep;
  }

  get isCurrentLessonComplete(): boolean {
    return this.currentLessonIsComplete;
  }

  /** True while the push-to-talk keys are down, so the coach's keycaps light up. */
  get isShortcutHeld(): boolean {
    return this.shortcutIsHeld;
  }

  get shortcut(): PushToTalkShortcut {
    return this.currentShortcut;
  }

  set shortcut(newShortcut: PushToTalkShortcut) {
    this.currentShortcut = newShortcut;
    this.notifyListeners();
  }

  get dockEdge(): DockEdge {
    return this.currentDockEdge;
  }

  /** Null until Rust reports them. */
  get permissionStatuses(): PermissionStatuses | null {
    return this.currentPermissionStatuses;
  }

  /** Names of the apps the person has connected, as the connector service last reported them. */
  get connectedAppNames(): readonly string[] {
    return this.currentConnectedAppNames;
  }

  /** The person opened Connectors from this lesson and is presumably finishing in the browser. */
  get hasOpenedConnectors(): boolean {
    return this.connectorsWereOpened;
  }

  // Derived ---------------------------------------------------------------------------------------------------------

  get currentLesson(): TourLesson | null {
    return this.currentStep.kind === 'lesson' ? this.currentStep.lesson : null;
  }

  /**
   * The line under the lesson. A finished lesson says so; a missing permission comes next because nothing else can
   * work without it; then whatever the current turn is doing; then the lesson's own resting line.
   */
  get status(): TourStatus {
    const lesson = this.currentLesson;
    if (lesson === null) return makeTourStatus('done', '');
    if (this.currentLessonIsComplete) return this.completedStatus(lesson);
    const missingPermission = this.firstMissingPermission(lesson);
    if (missingPermission !== null && this.currentPermissionStatuses !== null) {
      return makeTourStatus('problem', missingPermissionText(missingPermission), {
        kind: 'fixPermission',
        permission: missingPermission,
        permissionStatus: this.currentPermissionStatuses[missingPermission],
      });
    }
    return this.activityStatus ?? this.restingStatus(lesson);
  }

  /** Replaces the lesson's instructions once it is done: what just happened and what to know about it. */
  get completionNote(): string | null {
    const lesson = this.currentLesson;
    if (lesson === null || !this.currentLessonIsComplete) return null;
    switch (lesson) {
      case 'talk':
        return "That's the whole gesture. It works from any app, any time.";
      case 'showScreen':
        return 'The drawing clears when you make your next request.';
      case 'handOff':
        return 'The dot in the bar is your agent working. Click the bar to see it. You can keep going.';
      case 'connectApps':
        return 'Ask about it any time. You can connect more in Settings.';
      case 'placeBar':
        return 'Move it again whenever you like.';
    }
  }

  // Inputs: the voice turn ------------------------------------------------------------------------------------------

  shortcutPressed(): void {
    this.shortcutIsHeld = true;
    this.beginTurn(false);
    this.activityStatus = makeTourStatus('listening', 'Listening…');
    this.noteActivity();
  }

  shortcutReleased(heldForSeconds: number): void {
    if (!this.shortcutIsHeld) return;
    this.shortcutIsHeld = false;
    if (heldForSeconds < TourModel.shortestRealHoldDurationSeconds) {
      this.lastHoldWasTooShort = true;
      this.activityStatus = makeTourStatus('nudge', 'Keep both keys held while you talk.');
    } else {
      this.activityStatus = makeTourStatus('working', 'Thinking…');
    }
    this.noteActivity();
  }

  /** The recording was transcribed and nothing was heard (the runtime went from transcribing straight to idle). */
  heardNothing(): void {
    // While the keys are down a new turn has already started; after a brief tap, the tap nudge is the better one.
    if (this.shortcutIsHeld || this.lastHoldWasTooShort) return;
    this.activityStatus = makeTourStatus('nudge', "I didn't catch anything. Hold the keys and speak, then let go.");
    this.noteActivity();
  }

  /** The request reached the agent. */
  thinkingStarted(): void {
    if (this.shortcutIsHeld) return;
    this.lastHoldWasTooShort = false;
    this.activityStatus = makeTourStatus('working', 'Thinking…');
    this.noteActivity();
  }

  /** The person typed into the bar instead of talking. */
  typedRequestSubmitted(): void {
    this.beginTurn(true);
    this.activityStatus = makeTourStatus('working', 'Thinking…');
    this.noteActivity();
  }

  /** Every event from the agent session, in order, exactly as the bar receives them. */
  apply(event: AgentEvent): void {
    switch (event.kind) {
      case 'textDelta': {
        if (event.text.length === 0 || this.hasAcknowledgedReplyThisTurn) return;
        this.hasAcknowledgedReplyThisTurn = true;
        // A denial or a failed tool explains more than "here it comes" does; it stays until the turn ends.
        const currentTone = this.activityStatus?.tone;
        if (currentTone === 'nudge' || currentTone === 'problem') return;
        this.activityStatus = makeTourStatus('working', 'Here it comes. The answer is in the bar.');
        break;
      }
      case 'toolStarted': {
        const label = event.activityLabel.length === 0 ? readableToolName(event.toolName) : event.activityLabel;
        this.activityStatus = makeTourStatus('working', `${label}…`);
        break;
      }
      case 'toolFinished':
        this.toolFinished(event.toolName, event.isError);
        break;
      case 'finished':
        this.turnFinished();
        break;
      case 'failed':
        switch (event.failure.kind) {
          case 'cancelled':
            // A cancelled turn leaves nothing to say, except a nudge the person has not read yet.
            if (this.activityStatus?.tone !== 'nudge') this.activityStatus = null;
            break;
          case 'notSignedIn':
            this.activityStatus = makeTourStatus('problem', 'You are signed out. Sign in from Settings, then try again.', {
              kind: 'tryAgain',
            });
            break;
          case 'paymentRequired':
          case 'other':
            this.activityStatus = makeTourStatus('problem', event.failure.message, { kind: 'tryAgain' });
            break;
        }
        break;
    }
    this.noteActivity();
  }

  // Inputs: approvals, the bar, apps, permissions -------------------------------------------------------------------

  approvalRequested(kind: ApprovalKind): void {
    if (this.currentLesson !== 'handOff' || this.currentLessonIsComplete || kind !== 'backgroundAgent') return;
    this.activityStatus = makeTourStatus('nudge', 'Ambient asks before it starts work. Press Allow in the bar.');
    this.noteActivity();
  }

  approvalAnswered(isAllowed: boolean): void {
    if (this.currentLesson !== 'handOff' || this.currentLessonIsComplete) return;
    if (isAllowed) {
      this.activityStatus = makeTourStatus('working', 'Starting the agent…');
    } else {
      this.approvalWasDeniedThisTurn = true;
      this.activityStatus = makeTourStatus('nudge', "No agent started. Ask again when you're ready, then press Allow.");
    }
    this.noteActivity();
  }

  dockEdgeChanged(newEdge: DockEdge): void {
    this.currentDockEdge = newEdge;
    const movedToAnotherEdgeDuringPlaceBar =
      this.currentLesson === 'placeBar' && !this.currentLessonIsComplete && newEdge !== this.dockEdgeWhenLessonBegan;
    if (movedToAnotherEdgeDuringPlaceBar) this.completeCurrentLesson();
    this.notifyListeners();
  }

  /** The names of every connected app, whenever the app checks. */
  connectedAppsChanged(names: string[]): void {
    this.currentConnectedAppNames = names;
    const connectedAnAppDuringConnectApps =
      this.currentLesson === 'connectApps' && !this.currentLessonIsComplete && names.length > 0;
    if (connectedAnAppDuringConnectApps) this.completeCurrentLesson();
    this.notifyListeners();
  }

  /** Null means Rust has not reported yet, which the coach treats as granted. */
  permissionStatusesChanged(statuses: PermissionStatuses | null): void {
    this.currentPermissionStatuses = statuses;
    this.notifyListeners();
  }

  // Intents from the coach ------------------------------------------------------------------------------------------

  advanceToNextStep(): void {
    const lesson = this.currentLesson;
    if (lesson === null) return;
    this.onLessonEnded?.(lesson, this.currentLessonIsComplete ? 'completed' : 'skipped');
    const nextLesson = allTourLessons[allTourLessons.indexOf(lesson) + 1];
    this.currentStep = nextLesson === undefined ? { kind: 'finished' } : { kind: 'lesson', lesson: nextLesson };
    this.resetForNewLesson();
    this.notifyListeners();
  }

  skipCurrentLesson(): void {
    this.advanceToNextStep();
  }

  endTour(): void {
    this.cancelIdleHint();
    this.onFinish?.();
  }

  performStatusAction(action: TourStatusAction): void {
    switch (action.kind) {
      case 'fixPermission':
        this.onFixPermission?.(action.permission);
        break;
      case 'tryAgain':
        this.activityStatus = null;
        this.noteActivity();
        break;
    }
  }

  openConnectors(): void {
    this.connectorsWereOpened = true;
    this.onOpenConnectors?.();
    this.noteActivity();
  }

  // Private helpers -------------------------------------------------------------------------------------------------

  private firstMissingPermission(lesson: TourLesson): TourPermission | null {
    // An unreported permission is treated as granted: the coach never guesses that something is broken.
    const reportedStatuses = this.currentPermissionStatuses;
    if (reportedStatuses === null) return null;
    const missingPermission = tourLessonRequiredPermissions(lesson).find(
      (permission) => reportedStatuses[permission] !== 'granted',
    );
    return missingPermission ?? null;
  }

  private restingStatus(lesson: TourLesson): TourStatus {
    switch (lesson) {
      case 'talk':
      case 'showScreen':
      case 'handOff':
        return makeTourStatus('waiting', 'Waiting for you to hold the keys.');
      case 'connectApps':
        return makeTourStatus(
          'waiting',
          this.connectorsWereOpened ? 'Waiting for you to finish in the browser.' : 'No apps connected yet.',
        );
      case 'placeBar':
        // DockEdge values are already the lowercase edge names ("bottom"), which is how the sentence reads them.
        return makeTourStatus('waiting', `The bar is on the ${this.currentDockEdge} edge.`);
    }
  }

  /** A short fact beside Next. The longer "what this means" goes in `completionNote`. */
  private completedStatus(lesson: TourLesson): TourStatus {
    switch (lesson) {
      case 'talk':
        return makeTourStatus('done', 'Done. Ambient heard you.');
      case 'showScreen':
        return makeTourStatus('done', 'Done. Ambient saw your screen.');
      case 'handOff':
        return makeTourStatus('done', 'Done. Your agent is working.');
      case 'connectApps':
        return makeTourStatus('done', `${listedAppNames(this.currentConnectedAppNames)} connected.`);
      case 'placeBar':
        return makeTourStatus('done', `The bar is on the ${this.currentDockEdge} edge now.`);
    }
  }

  private toolFinished(toolName: string, isError: boolean): void {
    const lesson = this.currentLesson;
    if (lesson === null || this.currentLessonIsComplete) return;
    if (lesson === 'showScreen' && TourModel.screenToolNames.has(toolName)) {
      if (isError) {
        this.activityStatus = makeTourStatus('problem', "Ambient couldn't use your screen that time.", {
          kind: 'tryAgain',
        });
      } else {
        this.completeCurrentLesson();
      }
    } else if (lesson === 'handOff' && toolName === TourModel.spawnAgentToolName) {
      if (!isError) {
        this.completeCurrentLesson();
      } else if (!this.approvalWasDeniedThisTurn) {
        this.activityStatus = makeTourStatus('problem', "The agent couldn't start.", { kind: 'tryAgain' });
      }
    }
  }

  private turnFinished(): void {
    const lesson = this.currentLesson;
    if (lesson === null || this.currentLessonIsComplete) {
      this.activityStatus = null;
      return;
    }
    switch (lesson) {
      case 'talk':
        if (this.currentTurnWasTyped) {
          this.activityStatus = makeTourStatus('nudge', 'Typing works too. Now try it with your voice.');
        } else {
          this.completeCurrentLesson();
        }
        break;
      case 'showScreen':
        // The reply stays in the bar as usual; the coach stays and points back at the lesson.
        this.activityStatus = makeTourStatus(
          'nudge',
          'That was a regular answer. To use your screen, try the phrase above.',
        );
        break;
      case 'handOff':
        if (this.approvalWasDeniedThisTurn) return;
        this.activityStatus = makeTourStatus(
          'nudge',
          'That was answered right away. Begin with “Start an agent to” to hand it off.',
        );
        break;
      case 'connectApps':
      case 'placeBar':
        this.activityStatus = null;
        break;
    }
  }

  private beginTurn(isTyped: boolean): void {
    this.currentTurnWasTyped = isTyped;
    this.lastHoldWasTooShort = false;
    this.approvalWasDeniedThisTurn = false;
    this.hasAcknowledgedReplyThisTurn = false;
  }

  private completeCurrentLesson(): void {
    this.currentLessonIsComplete = true;
    this.activityStatus = null;
    this.cancelIdleHint();
  }

  private resetForNewLesson(): void {
    this.currentLessonIsComplete = false;
    this.activityStatus = null;
    this.connectorsWereOpened = false;
    this.hasShownIdleHintThisLesson = false;
    this.dockEdgeWhenLessonBegan = this.currentDockEdge;
    this.scheduleIdleHint();
  }

  /** Anything the person does restarts the quiet clock. Every input ends here, so it also tells React to redraw. */
  private noteActivity(): void {
    this.scheduleIdleHint();
    this.notifyListeners();
  }

  private cancelIdleHint(): void {
    if (this.idleHintTimeoutHandle !== null) clearTimeout(this.idleHintTimeoutHandle);
    this.idleHintTimeoutHandle = null;
  }

  private scheduleIdleHint(): void {
    this.cancelIdleHint();
    if (this.currentLesson === null || this.currentLessonIsComplete || this.hasShownIdleHintThisLesson) return;
    this.idleHintTimeoutHandle = setTimeout(() => {
      this.idleHintTimeoutHandle = null;
      this.showIdleHintIfStillQuiet();
    }, this.idleHintDelaySeconds * 1000);
  }

  /** One gentle hint per lesson, and only while nothing else is being said. */
  private showIdleHintIfStillQuiet(): void {
    const lesson = this.currentLesson;
    if (lesson === null || this.currentLessonIsComplete || this.hasShownIdleHintThisLesson) return;
    if (this.shortcutIsHeld || this.activityStatus !== null) return;
    this.hasShownIdleHintThisLesson = true;
    this.activityStatus = makeTourStatus('nudge', this.idleHintText(lesson));
    this.notifyListeners();
  }

  private idleHintText(lesson: TourLesson): string {
    switch (lesson) {
      case 'talk':
        return 'Press both keys first and keep them down, then start talking.';
      case 'showScreen':
      case 'handOff':
        return 'Hold the keys, read the phrase above out loud, then let go.';
      case 'connectApps':
        return 'This one is optional. Choose Later to move on.';
      case 'placeBar':
        return 'Grab the small bar and drag it toward another edge.';
    }
  }

  private notifyListeners(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}
