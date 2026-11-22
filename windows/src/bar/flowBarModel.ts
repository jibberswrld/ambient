import type {
  AgentEvent,
  ApprovalRequest,
  BackgroundTask,
  DockEdge,
  PushToTalkShortcut,
  Uuid,
} from '../host/contract';

// The flow bar's state, ported from FlowBarModel.swift. The bar window pushes host events in through the methods
// below and hears the person's intent back through the `on…` callbacks, which call host commands. It never touches the
// window or the DOM, so every rule can be tested on its own.

/** One tool call in the current turn, as the bar shows it. */
export interface FlowBarToolCall {
  callId: string;
  toolName: string;
  /** A few words, such as "Searching Gmail". */
  activityLabel: string;
  status: 'running' | 'succeeded' | 'failed';
}

/** An error in plain words, with at most one link. */
export interface FlowBarErrorNotice {
  message: string;
  link: { title: string; destination: { kind: 'webPage'; url: string } | { kind: 'settings' } } | null;
}

export type FlowBarTurnPhase =
  | { kind: 'idle' }
  | { kind: 'listening' }
  | { kind: 'transcribing' }
  | { kind: 'thinking' }
  | { kind: 'working' }
  | { kind: 'responding' }
  | { kind: 'replyFinished' }
  | { kind: 'error'; notice: FlowBarErrorNotice };

/** What the bar is drawing right now. Derived from the turn, the pointer and the tasks; never set directly. */
export type FlowBarPresentation =
  | 'resting'
  | 'hovering'
  | 'listening'
  | 'transcribing'
  | 'thinking'
  | 'working'
  | 'responding'
  | 'reply'
  | 'error'
  | 'approval'
  | 'typing'
  | 'taskTray'
  | 'taskFinishedNotice'
  | 'contextMenu';

/** Pill-shaped presentations; the rest are cards with a fixed corner radius. */
export function isCapsulePresentation(presentation: FlowBarPresentation): boolean {
  switch (presentation) {
    case 'resting':
    case 'hovering':
    case 'listening':
    case 'transcribing':
    case 'thinking':
    case 'working':
    case 'typing':
    case 'taskFinishedNotice':
      return true;
    default:
      return false;
  }
}

/**
 * On the left and right edges these keep the edge's upright orientation; every other presentation becomes a horizontal
 * surface that grows sideways away from the edge, because text cannot be read upright.
 */
export function presentationFollowsEdgeOrientation(presentation: FlowBarPresentation): boolean {
  return presentation === 'resting' || presentation === 'hovering' || presentation === 'listening' || presentation === 'transcribing';
}

export function isVerticalEdge(edge: DockEdge): boolean {
  return edge === 'left' || edge === 'right';
}

/** "gmail_search_threads" becomes "Gmail search threads", for tools that give no activity label. */
export function readableToolName(toolName: string): string {
  const words = toolName.replaceAll('_', ' ').replaceAll('-', ' ');
  if (words.length === 0) return toolName;
  return words.charAt(0).toUpperCase() + words.slice(1).toLowerCase();
}

export class FlowBarModel {
  // State pushed in by the window ------------------------------------------------------------------------------------
  turnPhase: FlowBarTurnPhase = { kind: 'idle' };
  /** Microphone level from 0 to 1. */
  audioLevel = 0;
  /** The newest activity line, such as "Searching Gmail". */
  currentActivityLine: string | null = null;
  toolCallsThisTurn: FlowBarToolCall[] = [];
  /** The whole reply received so far. */
  replyText = '';
  /** The part of the reply shown on screen. It trails `replyText` slightly so bursts still read as an even stream. */
  displayedReplyText = '';
  pendingApproval: ApprovalRequest | null = null;
  /** Background tasks, newest first, exactly as the host sends them. */
  backgroundTasks: BackgroundTask[] = [];
  /** A task that finished while the bar was resting, shown briefly to draw the eye. */
  recentlyFinishedTask: BackgroundTask | null = null;

  // Interface state ---------------------------------------------------------------------------------------------------
  isTyping = false;
  pushToTalkShortcut: PushToTalkShortcut = 'controlAlt';
  typedText = '';
  isTaskTrayExpanded = false;
  isPointerHovering = false;
  /** Hovering the working pill reveals the steps taken so far. */
  isShowingToolCallTrail = false;
  /** The right-click menu (Open Settings, Check for Updates…, Quit Ambient). */
  isContextMenuOpen = false;
  /** Copy, Reply and Dismiss under a finished answer. Off for the onboarding picture, where they mean nothing. */
  showsReplyActions = true;
  dockEdge: DockEdge = 'bottom';
  /** True while the person drags the bar to another edge. */
  isBeingDragged = false;

  // Behaviour -----------------------------------------------------------------------------------------------------------
  /** How long a finished reply stays when the pointer is not over it. Zero keeps it until dismissed. */
  finishedReplyLingerSeconds = 24;
  /** How long an error stays when the pointer is not over it. Zero keeps it until dismissed. */
  errorLingerSeconds = 16;
  /** How long the "task finished" notice shows on the resting bar. */
  taskFinishedNoticeSeconds = 5;
  /** When true the displayed reply always equals the full reply (tests and still captures). */
  revealsReplyInstantly = false;

  // Intents the window handles ---------------------------------------------------------------------------------------
  onCancelTurn: (() => void) | null = null;
  onSubmitTypedText: ((text: string) => void) | null = null;
  onOpenSettings: (() => void) | null = null;
  onCheckForUpdates: (() => void) | null = null;
  onQuit: (() => void) | null = null;
  onAnswerApproval: ((requestId: Uuid, isAllowed: boolean) => void) | null = null;
  onCancelBackgroundTask: ((taskId: Uuid) => void) | null = null;
  onDismissBackgroundTask: ((taskId: Uuid) => void) | null = null;
  onOpenBackgroundTaskTranscript: ((taskId: Uuid) => void) | null = null;
  onOpenUrl: ((url: string) => void) | null = null;
  onCopyText: ((text: string) => void) | null = null;
  onTypingStateChanged: ((isTyping: boolean) => void) | null = null;

  // Change notification for React ------------------------------------------------------------------------------------
  /** Increases on every change; React's useSyncExternalStore reads it as the snapshot. */
  version = 0;
  private readonly listeners = new Set<() => void>();

  private lingerTimer: ReturnType<typeof setTimeout> | null = null;
  private taskFinishedNoticeTimer: ReturnType<typeof setTimeout> | null = null;
  private replyRevealTimer: ReturnType<typeof setTimeout> | null = null;
  private isHoverPinnedForPreview = false;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  private notifyListeners(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  // Derived -----------------------------------------------------------------------------------------------------------

  /**
   * What the bar draws. Approval outranks everything because the turn is blocked on it; listening outranks typing
   * because holding the shortcut is an explicit request to talk.
   */
  get presentation(): FlowBarPresentation {
    if (this.pendingApproval !== null) return 'approval';
    if (this.turnPhase.kind === 'listening') return 'listening';
    if (this.turnPhase.kind === 'transcribing') return 'transcribing';
    if (this.isTyping) return 'typing';
    switch (this.turnPhase.kind) {
      case 'error':
        return 'error';
      case 'responding':
        return 'responding';
      case 'replyFinished':
        return 'reply';
      case 'working':
        return 'working';
      case 'thinking':
        return 'thinking';
      default:
        break;
    }
    if (this.isContextMenuOpen) return 'contextMenu';
    if (this.isTaskTrayExpanded && this.backgroundTasks.length > 0) return 'taskTray';
    if (this.isBeingDragged) return 'resting';
    if (this.recentlyFinishedTask !== null && !this.isPointerHovering) return 'taskFinishedNotice';
    if (this.isPointerHovering) return 'hovering';
    return 'resting';
  }

  get runningBackgroundTaskCount(): number {
    return this.backgroundTasks.filter((backgroundTask) => backgroundTask.status === 'running').length;
  }

  get currentErrorNotice(): FlowBarErrorNotice | null {
    return this.turnPhase.kind === 'error' ? this.turnPhase.notice : null;
  }

  get isReplyStillStreaming(): boolean {
    return this.turnPhase.kind === 'responding' || this.displayedReplyText.length < this.replyText.length;
  }

  // Inputs: the voice turn -------------------------------------------------------------------------------------------

  /** The shortcut went down: start a new turn. */
  beginListening(): void {
    this.resetTurn();
    this.setTyping(false);
    this.isTaskTrayExpanded = false;
    this.isContextMenuOpen = false;
    this.turnPhase = { kind: 'listening' };
    this.notifyListeners();
  }

  updateAudioLevel(level: number): void {
    this.audioLevel = Math.min(Math.max(level, 0), 1);
    this.notifyListeners();
  }

  /** The shortcut came up and the words are being turned into text. */
  beginTranscribing(): void {
    this.audioLevel = 0;
    this.turnPhase = { kind: 'transcribing' };
    this.notifyListeners();
  }

  /** The request went to the agent. */
  beginThinking(): void {
    this.cancelLinger();
    this.audioLevel = 0;
    if (this.turnPhase.kind !== 'responding') this.turnPhase = { kind: 'thinking' };
    this.notifyListeners();
  }

  /** Feed every `ambient:agent-event` here, in order. */
  apply(event: AgentEvent): void {
    switch (event.kind) {
      case 'textDelta': {
        if (event.text.length === 0) return;
        if (this.turnPhase.kind !== 'responding') this.turnPhase = { kind: 'responding' };
        this.replyText += event.text;
        this.scheduleReplyReveal();
        break;
      }
      case 'toolStarted': {
        const label = event.activityLabel.length === 0 ? readableToolName(event.toolName) : event.activityLabel;
        const existingToolCall = this.toolCallsThisTurn.find((toolCall) => toolCall.callId === event.callId);
        if (existingToolCall) {
          this.toolCallsThisTurn = this.toolCallsThisTurn.map((toolCall) =>
            toolCall.callId === event.callId ? { ...toolCall, status: 'running' } : toolCall,
          );
        } else {
          this.toolCallsThisTurn = [
            ...this.toolCallsThisTurn,
            { callId: event.callId, toolName: event.toolName, activityLabel: label, status: 'running' },
          ];
        }
        this.currentActivityLine = label;
        // A tool starting mid-reply keeps the reply on screen and shows the activity under it, rather than collapsing
        // the card back into a pill.
        if (this.turnPhase.kind !== 'responding') this.turnPhase = { kind: 'working' };
        break;
      }
      case 'toolFinished': {
        this.toolCallsThisTurn = this.toolCallsThisTurn.map((toolCall) =>
          toolCall.callId === event.callId ? { ...toolCall, status: event.isError ? 'failed' : 'succeeded' } : toolCall,
        );
        const isAnyToolStillRunning = this.toolCallsThisTurn.some((toolCall) => toolCall.status === 'running');
        if (!isAnyToolStillRunning && this.turnPhase.kind === 'responding') this.currentActivityLine = null;
        break;
      }
      case 'finished': {
        if (event.finalText.length > 0) this.replyText = event.finalText;
        this.currentActivityLine = null;
        if (this.replyText.trim().length === 0) {
          this.returnToIdle();
          return;
        }
        this.turnPhase = { kind: 'replyFinished' };
        this.scheduleReplyReveal();
        this.scheduleLinger(this.finishedReplyLingerSeconds);
        break;
      }
      case 'failed': {
        const failure = event.failure;
        switch (failure.kind) {
          case 'cancelled':
            this.returnToIdle();
            return;
          case 'paymentRequired':
            this.showError({
              message: failure.message,
              link: failure.topUpUrl ? { title: 'Top up', destination: { kind: 'webPage', url: failure.topUpUrl } } : null,
            });
            return;
          case 'notSignedIn':
            this.showError({
              message: 'You are signed out. Sign in to keep going.',
              link: { title: 'Sign in', destination: { kind: 'settings' } },
            });
            return;
          case 'other':
            this.showError({ message: failure.message, link: null });
            return;
        }
      }
    }
    this.notifyListeners();
  }

  showError(notice: FlowBarErrorNotice): void {
    this.denyPendingApproval();
    this.audioLevel = 0;
    this.setTyping(false);
    this.turnPhase = { kind: 'error', notice };
    this.scheduleLinger(this.errorLingerSeconds);
    this.notifyListeners();
  }

  /**
   * An approval is waiting (`ambient:approval-requested`). A newer request replaces the one before it: the host has
   * already denied that one.
   */
  requestApproval(request: ApprovalRequest): void {
    this.cancelLinger();
    this.setTyping(false);
    this.isContextMenuOpen = false;
    this.pendingApproval = request;
    this.notifyListeners();
  }

  /** The host withdrew the request (`ambient:approval-cancelled`). */
  approvalCancelled(requestId: Uuid): void {
    if (this.pendingApproval?.requestId !== requestId) return;
    this.pendingApproval = null;
    this.notifyListeners();
  }

  /** The runtime went back to idle: the turn was cancelled or nothing was heard. */
  returnToIdle(): void {
    this.denyPendingApproval();
    this.cancelLinger();
    this.resetTurn();
    this.turnPhase = { kind: 'idle' };
    this.notifyListeners();
  }

  /** The whole list from `ambient:background-tasks`. Notices tasks that just finished. */
  setBackgroundTasks(tasks: BackgroundTask[]): void {
    const previouslyRunningTaskIds = new Set(
      this.backgroundTasks.filter((backgroundTask) => backgroundTask.status === 'running').map((backgroundTask) => backgroundTask.id),
    );
    const justFinishedTask = tasks.find(
      (backgroundTask) => previouslyRunningTaskIds.has(backgroundTask.id) && backgroundTask.status !== 'running',
    );
    this.backgroundTasks = tasks;
    if (tasks.length === 0) this.isTaskTrayExpanded = false;
    if (justFinishedTask && !this.isTaskTrayExpanded) this.showTaskFinishedNotice(justFinishedTask);
    const shownTask = this.recentlyFinishedTask;
    if (shownTask && !tasks.some((backgroundTask) => backgroundTask.id === shownTask.id)) this.recentlyFinishedTask = null;
    this.notifyListeners();
  }

  // Intents from the interface ---------------------------------------------------------------------------------------

  cancelCurrentTurn(): void {
    this.denyPendingApproval();
    this.onCancelTurn?.();
    this.returnToIdle();
  }

  /** Opens the text field. The bar does this itself on a click. */
  beginTyping(): void {
    if (this.turnPhase.kind === 'listening' || this.turnPhase.kind === 'transcribing') return;
    this.isTaskTrayExpanded = false;
    this.isContextMenuOpen = false;
    this.setTyping(true);
    this.notifyListeners();
  }

  endTyping(): void {
    this.setTyping(false);
    this.notifyListeners();
  }

  setTypedText(typedText: string): void {
    this.typedText = typedText;
    this.notifyListeners();
  }

  submitTypedText(): void {
    const trimmedText = this.typedText.trim();
    if (trimmedText.length === 0) return;
    this.typedText = '';
    this.setTyping(false);
    this.resetTurn();
    this.turnPhase = { kind: 'thinking' };
    this.onSubmitTypedText?.(trimmedText);
    this.notifyListeners();
  }

  openSettings(): void {
    this.isContextMenuOpen = false;
    this.onOpenSettings?.();
    this.notifyListeners();
  }

  answerPendingApproval(isAllowed: boolean): void {
    const request = this.pendingApproval;
    if (!request) return;
    this.pendingApproval = null;
    this.onAnswerApproval?.(request.requestId, isAllowed);
    this.notifyListeners();
  }

  copyReply(): void {
    this.onCopyText?.(this.replyText);
  }

  /** "Reply" on a finished answer: keep the conversation and open the text field. */
  continueConversation(): void {
    this.cancelLinger();
    this.resetTurn();
    this.turnPhase = { kind: 'idle' };
    this.setTyping(true);
    this.notifyListeners();
  }

  dismissReplyOrError(): void {
    this.returnToIdle();
  }

  followErrorLink(link: NonNullable<FlowBarErrorNotice['link']>): void {
    if (link.destination.kind === 'webPage') this.onOpenUrl?.(link.destination.url);
    else this.onOpenSettings?.();
    this.returnToIdle();
  }

  /** Opens or closes the background task tray. */
  toggleTaskTray(): void {
    this.isTaskTrayExpanded = !this.isTaskTrayExpanded;
    if (this.isTaskTrayExpanded) {
      this.recentlyFinishedTask = null;
      this.isContextMenuOpen = false;
    }
    this.notifyListeners();
  }

  collapseTaskTray(): void {
    this.isTaskTrayExpanded = false;
    this.notifyListeners();
  }

  cancelBackgroundTask(taskId: Uuid): void {
    this.onCancelBackgroundTask?.(taskId);
  }

  dismissBackgroundTask(taskId: Uuid): void {
    this.onDismissBackgroundTask?.(taskId);
  }

  openBackgroundTaskTranscript(taskId: Uuid): void {
    this.onOpenBackgroundTaskTranscript?.(taskId);
  }

  /** Right-click on the bar. Only from the quiet states, where the bar has nothing more important to show. */
  openContextMenu(): void {
    const presentation = this.presentation;
    if (presentation !== 'resting' && presentation !== 'hovering' && presentation !== 'taskFinishedNotice') return;
    this.isContextMenuOpen = true;
    this.recentlyFinishedTask = null;
    this.notifyListeners();
  }

  closeContextMenu(): void {
    if (!this.isContextMenuOpen) return;
    this.isContextMenuOpen = false;
    this.notifyListeners();
  }

  checkForUpdates(): void {
    this.closeContextMenu();
    this.onCheckForUpdates?.();
  }

  quit(): void {
    this.closeContextMenu();
    this.onQuit?.();
  }

  setToolCallTrailShown(isShown: boolean): void {
    const shouldShow = isShown && this.presentation === 'working';
    if (shouldShow === this.isShowingToolCallTrail) return;
    this.isShowingToolCallTrail = shouldShow;
    this.notifyListeners();
  }

  setDockEdge(edge: DockEdge): void {
    if (edge === this.dockEdge) return;
    this.dockEdge = edge;
    this.notifyListeners();
  }

  setBeingDragged(isBeingDragged: boolean): void {
    if (isBeingDragged === this.isBeingDragged) return;
    this.isBeingDragged = isBeingDragged;
    if (isBeingDragged) this.isContextMenuOpen = false;
    this.notifyListeners();
  }

  setPushToTalkShortcut(shortcut: PushToTalkShortcut): void {
    this.pushToTalkShortcut = shortcut;
    this.notifyListeners();
  }

  /** Holds the hover presentation regardless of the pointer. Only for the gallery and onboarding's picture. */
  pinHoverForPreview(isPinned: boolean): void {
    this.isHoverPinnedForPreview = isPinned;
    this.setPointerHovering(isPinned);
  }

  /** The pointer moved over or off the bar. Hovering a reply or error pauses its linger timer. */
  setPointerHovering(isHovering: boolean): void {
    if (this.isHoverPinnedForPreview && !isHovering) return;
    if (isHovering === this.isPointerHovering) return;
    this.isPointerHovering = isHovering;
    if (!isHovering) {
      this.isShowingToolCallTrail = false;
      this.isContextMenuOpen = false;
    }
    if (this.turnPhase.kind === 'replyFinished') {
      if (isHovering) this.cancelLinger();
      else this.scheduleLinger(this.finishedReplyLingerSeconds);
    } else if (this.turnPhase.kind === 'error') {
      if (isHovering) this.cancelLinger();
      else this.scheduleLinger(this.errorLingerSeconds);
    }
    if (isHovering && this.recentlyFinishedTask !== null && this.presentation === 'hovering') {
      // The person came to look: the notice has done its job.
      this.recentlyFinishedTask = null;
    }
    this.notifyListeners();
  }

  // Private helpers ---------------------------------------------------------------------------------------------------

  private setTyping(isTyping: boolean): void {
    if (isTyping === this.isTyping) return;
    this.isTyping = isTyping;
    this.onTypingStateChanged?.(isTyping);
  }

  private resetTurn(): void {
    if (this.replyRevealTimer !== null) clearTimeout(this.replyRevealTimer);
    this.replyRevealTimer = null;
    this.replyText = '';
    this.displayedReplyText = '';
    this.toolCallsThisTurn = [];
    this.currentActivityLine = null;
    this.audioLevel = 0;
    this.isShowingToolCallTrail = false;
  }

  /** The bar answers "deny" for a request it is dropping, so the turn waiting on it never hangs. */
  private denyPendingApproval(): void {
    const request = this.pendingApproval;
    if (!request) return;
    this.pendingApproval = null;
    this.onAnswerApproval?.(request.requestId, false);
  }

  private scheduleLinger(durationSeconds: number): void {
    this.cancelLinger();
    if (durationSeconds <= 0 || this.isPointerHovering) return;
    this.lingerTimer = setTimeout(() => {
      this.lingerTimer = null;
      if (this.turnPhase.kind === 'replyFinished' || this.turnPhase.kind === 'error') this.returnToIdle();
    }, durationSeconds * 1000);
  }

  private cancelLinger(): void {
    if (this.lingerTimer !== null) clearTimeout(this.lingerTimer);
    this.lingerTimer = null;
  }

  private showTaskFinishedNotice(finishedTask: BackgroundTask): void {
    this.recentlyFinishedTask = finishedTask;
    if (this.taskFinishedNoticeTimer !== null) clearTimeout(this.taskFinishedNoticeTimer);
    this.taskFinishedNoticeTimer = setTimeout(() => {
      this.taskFinishedNoticeTimer = null;
      this.recentlyFinishedTask = null;
      this.notifyListeners();
    }, this.taskFinishedNoticeSeconds * 1000);
  }

  /** Reveals the reply at an even pace, faster when more text is waiting, so bursts read as a smooth stream. */
  private scheduleReplyReveal(): void {
    if (this.revealsReplyInstantly) {
      this.displayedReplyText = this.replyText;
      return;
    }
    if (this.replyRevealTimer !== null) return;
    const revealNextFrame = () => {
      this.replyRevealTimer = null;
      const waitingCharacterCount = this.replyText.length - this.displayedReplyText.length;
      if (waitingCharacterCount <= 0 || !this.replyText.startsWith(this.displayedReplyText)) {
        // The full reply may have been replaced by the final text; keep them identical.
        if (this.displayedReplyText !== this.replyText) {
          this.displayedReplyText = this.replyText;
          this.notifyListeners();
        }
        return;
      }
      const charactersThisFrame = Math.max(1, Math.floor(waitingCharacterCount / 6));
      this.displayedReplyText = this.replyText.slice(0, this.displayedReplyText.length + charactersThisFrame);
      this.notifyListeners();
      this.replyRevealTimer = setTimeout(revealNextFrame, 16);
    };
    this.replyRevealTimer = setTimeout(revealNextFrame, 16);
  }
}
