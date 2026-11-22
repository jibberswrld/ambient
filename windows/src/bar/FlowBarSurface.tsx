import {
  ArrowUp,
  ArrowUpRight,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  CircleAlert,
  CircleCheck,
  CircleMinus,
  Copy,
  Cpu,
  FileText,
  Hand,
  Keyboard,
  Reply,
  Settings,
  Square,
  Terminal,
  TextAlignStart,
  X,
  type LucideIcon,
} from 'lucide-react';
import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from 'react';
import type { ApprovalKind, BackgroundTask, DockEdge } from '../host/contract';
import {
  CapsuleButton,
  EmberIndicator,
  GlassIconButton,
  KeycapRow,
  PillDivider,
  RunningArc,
} from '../design/controls';
import { MarkdownView } from '../design/MarkdownView';
import { plainTextFromMarkdown } from '../design/lightMarkdown';
import { keycapLabels, spokenShortcutName } from '../design/shortcuts';
import { useModelVersion } from '../design/useModel';
import { formatElapsedTime } from './elapsedTime';
import {
  isCapsulePresentation,
  isVerticalEdge,
  presentationFollowsEdgeOrientation,
  type FlowBarModel,
  type FlowBarPresentation,
} from './flowBarModel';
import { WaveformView } from './WaveformView';

// The flow bar's glass. One piece of smoked glass that grows from capsule to card and back as the state changes; the
// content of each state fades in inside it. It sits against the docked edge, so growth always reads as moving away
// from that edge.

/** Where the glass sits inside its container (the bar window, or a gallery stage). */
export type FlowBarSurfacePlacement =
  /** Against `edge` of the container, `gapFromEdge` px in, centred along the edge plus `offsetAlongEdge`. */
  | { kind: 'docked'; gapFromEdge: number; offsetAlongEdge: number }
  /** At a point of the container. With `edge`, the point is the middle of the glass's edge-facing side (a landing);
   *  without it, the point is the glass's centre (being dragged). */
  | { kind: 'free'; x: number; y: number; edge: DockEdge | null; isLanding: boolean };

export const restingLength = 38;
export const restingThickness = 8;
export const restingWithTasksThickness = 16;
const cardCornerRadius = 22;
const pillThickness = 36;

function surfaceCornerRadius(presentation: FlowBarPresentation, hasTasks: boolean): number {
  switch (presentation) {
    case 'resting':
      return (hasTasks ? restingWithTasksThickness : restingThickness) / 2;
    case 'typing':
      return 20;
    case 'hovering':
    case 'listening':
    case 'transcribing':
    case 'thinking':
    case 'working':
    case 'taskFinishedNotice':
      return pillThickness / 2;
    default:
      return cardCornerRadius;
  }
}

function placementStyle(placement: FlowBarSurfacePlacement, edge: DockEdge, isBeingDragged: boolean): CSSProperties {
  if (placement.kind === 'free') {
    const translateForEdge: Record<DockEdge, string> = {
      bottom: 'translate(-50%, -100%)',
      top: 'translate(-50%, 0)',
      left: 'translate(0, -50%)',
      right: 'translate(-100%, -50%)',
    };
    const translate = placement.edge ? translateForEdge[placement.edge] : 'translate(-50%, -50%)';
    return {
      left: placement.x,
      top: placement.y,
      transform: `${translate}${isBeingDragged ? ' scale(1.12)' : ''}`,
    };
  }
  const offset = `${placement.offsetAlongEdge}px`;
  switch (edge) {
    case 'bottom':
      return { bottom: placement.gapFromEdge, left: `calc(50% + ${offset})`, transform: 'translateX(-50%)' };
    case 'top':
      return { top: placement.gapFromEdge, left: `calc(50% + ${offset})`, transform: 'translateX(-50%)' };
    case 'left':
      return { left: placement.gapFromEdge, top: `calc(50% + ${offset})`, transform: 'translateY(-50%)' };
    case 'right':
      return { right: placement.gapFromEdge, top: `calc(50% + ${offset})`, transform: 'translateY(-50%)' };
  }
}

export function FlowBarSurface(props: {
  model: FlowBarModel;
  placement: FlowBarSurfacePlacement;
  /** Called with the glass's size whenever the content settles on a new size (the window resizes to fit). */
  onSurfaceSizeChange?: (size: { width: number; height: number }) => void;
  /** Pointer down on the resting or hovering bar: the window may begin a drag to another edge. */
  onDragPointerDown?: (event: ReactPointerEvent<HTMLDivElement>) => void;
}) {
  const { model } = props;
  useModelVersion(model);
  const presentation = model.presentation;
  const edge = model.dockEdge;
  const contentReference = useRef<HTMLDivElement>(null);
  const [surfaceSize, setSurfaceSize] = useState<{ width: number; height: number } | null>(null);
  const hasMeasuredOnce = useRef(false);
  const onSurfaceSizeChange = props.onSurfaceSizeChange;

  // The glass takes the size of the current state's content. Measuring with a ResizeObserver also follows text
  // streaming into a reply card.
  useLayoutEffect(() => {
    const contentElement = contentReference.current;
    if (!contentElement) return;
    const measure = () => {
      const measuredSize = { width: Math.ceil(contentElement.offsetWidth), height: Math.ceil(contentElement.offsetHeight) };
      setSurfaceSize((previousSize) =>
        previousSize && previousSize.width === measuredSize.width && previousSize.height === measuredSize.height ? previousSize : measuredSize,
      );
    };
    measure();
    const resizeObserver = new ResizeObserver(measure);
    resizeObserver.observe(contentElement);
    return () => resizeObserver.disconnect();
  }, [presentation, edge]);

  useEffect(() => {
    if (surfaceSize) onSurfaceSizeChange?.(surfaceSize);
  }, [surfaceSize, onSurfaceSizeChange]);

  useEffect(() => {
    if (surfaceSize) hasMeasuredOnce.current = true;
  }, [surfaceSize]);

  const isUpright = isVerticalEdge(edge) && presentationFollowsEdgeOrientation(presentation);
  const cornerRadius = surfaceCornerRadius(presentation, model.backgroundTasks.length > 0);
  const canBeDragged = presentation === 'resting' || presentation === 'hovering';
  const isLanding = props.placement.kind === 'free' && props.placement.isLanding;

  return (
    <div
      className={[
        'flow-bar-surface',
        'smoked-glass',
        isCapsulePresentation(presentation) ? '' : 'is-raised-card',
        `edge-${edge}`,
        hasMeasuredOnce.current ? 'has-measured' : '',
        model.isBeingDragged ? 'is-being-dragged' : '',
        isLanding ? 'is-landing' : '',
      ].join(' ')}
      style={{
        ...placementStyle(props.placement, edge, model.isBeingDragged),
        width: surfaceSize?.width ?? 0,
        height: surfaceSize?.height ?? 0,
        borderRadius: cornerRadius,
      }}
      data-presentation={presentation}
      onContextMenu={(event) => {
        event.preventDefault();
        model.openContextMenu();
      }}
      onPointerDown={canBeDragged ? props.onDragPointerDown : undefined}
    >
      <div className="flow-bar-clip" style={{ borderRadius: cornerRadius }}>
        <div ref={contentReference} key={presentation} className={`flow-bar-content anchored-${edge}`}>
          <FlowBarStateContent model={model} presentation={presentation} isUpright={isUpright} />
        </div>
      </div>
    </div>
  );
}

function FlowBarStateContent(props: { model: FlowBarModel; presentation: FlowBarPresentation; isUpright: boolean }) {
  const { model, presentation, isUpright } = props;
  switch (presentation) {
    case 'resting':
      return <RestingContent model={model} isUpright={isUpright} />;
    case 'hovering':
      return <HoverContent model={model} isUpright={isUpright} />;
    case 'listening':
      return <WaveformView model={model} mode="listening" isUpright={isUpright} />;
    case 'transcribing':
      return <WaveformView model={model} mode="transcribing" isUpright={isUpright} />;
    case 'thinking':
    case 'working':
      return <ActivityContent model={model} />;
    case 'typing':
      return <TypingContent model={model} />;
    case 'responding':
    case 'reply':
      return <ReplyCard model={model} />;
    case 'error':
      return <ErrorCard model={model} />;
    case 'approval':
      return <ApprovalCard model={model} />;
    case 'taskTray':
      return <TaskTrayCard model={model} />;
    case 'taskFinishedNotice':
      return <TaskFinishedNotice model={model} />;
    case 'contextMenu':
      return <ContextMenuCard model={model} />;
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Resting
// ---------------------------------------------------------------------------------------------------------------------

function RestingContent(props: { model: FlowBarModel; isUpright: boolean }) {
  const { model, isUpright } = props;
  const visibleTasks = model.backgroundTasks.slice(0, 3);
  const hiddenTaskCount = model.backgroundTasks.length - visibleTasks.length;
  const thickness = visibleTasks.length === 0 ? restingThickness : restingWithTasksThickness;
  const length =
    visibleTasks.length === 0
      ? restingLength
      : Math.max(restingLength + 6, visibleTasks.length * 10 + (hiddenTaskCount > 0 ? 18 : 0) + 18);
  const label = visibleTasks.length === 0 ? 'Ambient' : `Ambient, ${model.runningBackgroundTaskCount} tasks running`;
  return (
    <div
      className={`resting-content${isUpright ? ' is-upright' : ''}`}
      style={{ width: isUpright ? thickness : length, height: isUpright ? length : thickness }}
      role="img"
      aria-label={label}
    >
      {visibleTasks.map((backgroundTask) => (
        <TaskStatusDot key={backgroundTask.id} status={backgroundTask.status} />
      ))}
      {hiddenTaskCount > 0 ? <span className="resting-overflow-count">+{hiddenTaskCount}</span> : null}
    </div>
  );
}

/** One small dot per background task: ember while running, white when done, red when it failed. */
function TaskStatusDot(props: { status: BackgroundTask['status'] }) {
  return <span className={`task-status-dot status-${props.status}`} aria-hidden />;
}

// ---------------------------------------------------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------------------------------------------------

function HoverContent(props: { model: FlowBarModel; isUpright: boolean }) {
  const { model, isUpright } = props;
  const labels = keycapLabels(model.pushToTalkShortcut);
  const hasTasks = model.backgroundTasks.length > 0;
  // Clicking the bar itself (not one of its buttons) opens the text box, as on the Mac.
  const beginTypingFromBackground = (event: React.MouseEvent) => {
    if ((event.target as HTMLElement).closest('button')) return;
    model.beginTyping();
  };
  if (isUpright) {
    return (
      <div className="hover-content is-upright" onClick={beginTypingFromBackground} title={`Hold ${spokenShortcutName(model.pushToTalkShortcut)}, then talk`}>
        <span className="hover-keycaps-column">
          {labels.map((label) => (
            <KeycapRow key={label} labels={[label]} size={20} />
          ))}
        </span>
        {hasTasks ? <TasksChip model={model} isUpright /> : null}
        <PillDivider isUpright />
        <GlassIconButton icon={Keyboard} label="Type instead" onClick={() => model.beginTyping()} />
        <GlassIconButton icon={Settings} label="Settings" onClick={() => model.openSettings()} />
      </div>
    );
  }
  return (
    <div className="hover-content" onClick={beginTypingFromBackground}>
      <KeycapRow labels={labels} size={20} />
      <span className="pill-label">Hold to talk</span>
      {hasTasks ? (
        <>
          <PillDivider />
          <TasksChip model={model} isUpright={false} />
        </>
      ) : null}
      <PillDivider />
      <span className="hover-icon-buttons">
        <GlassIconButton icon={Keyboard} label="Type instead" onClick={() => model.beginTyping()} />
        <GlassIconButton icon={Settings} label="Settings" onClick={() => model.openSettings()} />
      </span>
    </div>
  );
}

/** "2 running" with the task dots: opens the background task tray. */
function TasksChip(props: { model: FlowBarModel; isUpright: boolean }) {
  const { model } = props;
  const runningCount = model.runningBackgroundTaskCount;
  const summary = runningCount > 0 ? `${runningCount} running` : `${model.backgroundTasks.length} done`;
  return (
    <button
      type="button"
      className={`tasks-chip${props.isUpright ? ' is-upright' : ''}`}
      title="Background tasks"
      aria-label={`Background tasks, ${summary}`}
      onClick={() => model.toggleTaskTray()}
    >
      <span className="tasks-chip-dots">
        {model.backgroundTasks.slice(0, 3).map((backgroundTask) => (
          <TaskStatusDot key={backgroundTask.id} status={backgroundTask.status} />
        ))}
      </span>
      {props.isUpright ? null : <span className="tasks-chip-summary">{summary}</span>}
    </button>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Thinking and working
// ---------------------------------------------------------------------------------------------------------------------

function ActivityContent(props: { model: FlowBarModel }) {
  const { model } = props;
  const isWorking = model.presentation === 'working';
  const earlierToolCalls = model.toolCallsThisTurn.slice(0, -1);
  const showsTrail = model.isShowingToolCallTrail && earlierToolCalls.length > 0;
  return (
    <div
      className="activity-content"
      onPointerEnter={() => model.setToolCallTrailShown(true)}
      onPointerLeave={() => model.setToolCallTrailShown(false)}
    >
      {showsTrail ? (
        <div className="tool-call-trail">
          {earlierToolCalls.map((toolCall) => (
            <div key={toolCall.callId} className="tool-call-row">
              <span className="tool-call-glyph">
                {toolCall.status === 'running' ? (
                  <RunningArc diameter={10} />
                ) : toolCall.status === 'succeeded' ? (
                  <Check size={10} strokeWidth={3} />
                ) : (
                  <X size={10} strokeWidth={3} className="is-alert" />
                )}
              </span>
              <span className="tool-call-label">{toolCall.activityLabel}</span>
            </div>
          ))}
        </div>
      ) : null}
      <div className="activity-pill-row">
        <EmberIndicator activity={isWorking ? 'working' : 'thinking'} />
        <span className="pill-label activity-label">{isWorking ? (model.currentActivityLine ?? 'Working') : 'Thinking'}</span>
        {isWorking && earlierToolCalls.length > 0 ? (
          <span className="activity-step-count">{model.toolCallsThisTurn.length} steps</span>
        ) : null}
        <GlassIconButton icon={X} label="Stop" diameter={22} iconSize={11} onClick={() => model.cancelCurrentTurn()} />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Typing
// ---------------------------------------------------------------------------------------------------------------------

function TypingContent(props: { model: FlowBarModel }) {
  const { model } = props;
  const inputReference = useRef<HTMLInputElement>(null);
  const canSend = model.typedText.trim().length > 0;
  useEffect(() => {
    // The window becomes focusable a moment after typing starts (the host makes it so); focusing before is ignored.
    const focusTimer = setTimeout(() => inputReference.current?.focus(), 60);
    return () => clearTimeout(focusTimer);
  }, []);
  return (
    <form
      className="typing-content"
      onSubmit={(event) => {
        event.preventDefault();
        model.submitTypedText();
      }}
    >
      <EmberIndicator activity="idle" diameter={12} />
      <input
        ref={inputReference}
        className="typing-input"
        placeholder="Ask Ambient"
        aria-label="Ask Ambient"
        value={model.typedText}
        spellCheck
        onChange={(event) => model.setTypedText(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') model.endTyping();
        }}
      />
      <button type="submit" className={`send-button${canSend ? ' can-send' : ''}`} disabled={!canSend} aria-label="Send">
        <ArrowUp size={14} strokeWidth={2.75} />
      </button>
    </form>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Reply
// ---------------------------------------------------------------------------------------------------------------------

/** The answer. Grows away from the docked edge as text streams in, hugs short answers, scrolls long ones. */
function ReplyCard(props: { model: FlowBarModel }) {
  const { model } = props;
  const isStreaming = model.isReplyStillStreaming;
  const showsFooter = isStreaming || model.showsReplyActions;
  const scrollReference = useRef<HTMLDivElement>(null);
  const [isScrollable, setIsScrollable] = useState(false);

  useLayoutEffect(() => {
    const scrollElement = scrollReference.current;
    if (!scrollElement) return;
    setIsScrollable(scrollElement.scrollHeight > scrollElement.clientHeight + 1);
    // While streaming, follow the newest line.
    if (isStreaming) scrollElement.scrollTop = scrollElement.scrollHeight;
  }, [model.displayedReplyText, isStreaming]);

  const stepCount = model.toolCallsThisTurn.length;
  return (
    <div className={`reply-card${showsFooter ? ' has-footer' : ''}`}>
      <div
        ref={scrollReference}
        className={`reply-body${isScrollable ? (isStreaming ? ' fades-top' : ' fades-bottom') : ''}`}
      >
        <MarkdownView
          markdownText={model.displayedReplyText.length === 0 ? ' ' : model.displayedReplyText}
          surface="smokedGlass"
          onOpenLink={(url) => model.onOpenUrl?.(url)}
        />
      </div>
      {showsFooter ? (
        <div className="reply-footer">
          {isStreaming ? (
            <>
              <EmberIndicator activity={model.currentActivityLine === null ? 'thinking' : 'working'} diameter={12} />
              {model.currentActivityLine ? <span className="reply-activity-line">{model.currentActivityLine}</span> : null}
              <span className="footer-spacer" />
              <CapsuleButton title="Stop" icon={Square} prominence="quiet" isCompact onClick={() => model.cancelCurrentTurn()} />
            </>
          ) : (
            <>
              {stepCount > 0 ? <span className="reply-step-count">{stepCount === 1 ? '1 step' : `${stepCount} steps`}</span> : null}
              <span className="footer-spacer" />
              <GlassIconButton icon={Copy} label="Copy" iconSize={12} onClick={() => model.copyReply()} />
              <CapsuleButton title="Reply" icon={Reply} prominence="quiet" isCompact onClick={() => model.continueConversation()} />
              <GlassIconButton icon={X} label="Dismiss" iconSize={12} onClick={() => model.dismissReplyOrError()} />
            </>
          )}
        </div>
      ) : null}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------------------------------------------------

function ErrorCard(props: { model: FlowBarModel }) {
  const { model } = props;
  const notice = model.currentErrorNotice ?? { message: 'Something went wrong.', link: null };
  const link = notice.link;
  return (
    <div className="error-card" role="alert">
      <CircleAlert className="error-card-icon" size={15} strokeWidth={2.25} aria-hidden />
      <div className="error-card-text">
        <p>{notice.message}</p>
        {link ? (
          <CapsuleButton
            title={link.title}
            icon={link.destination.kind === 'webPage' ? ArrowUpRight : undefined}
            prominence="primary"
            isCompact
            onClick={() => model.followErrorLink(link)}
          />
        ) : null}
      </div>
      <GlassIconButton icon={X} label="Dismiss" diameter={22} iconSize={11} onClick={() => model.dismissReplyOrError()} />
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Approval
// ---------------------------------------------------------------------------------------------------------------------

const approvalIcons: Record<ApprovalKind, LucideIcon> = { shellCommand: Terminal, backgroundAgent: Cpu, other: Hand };

function ApprovalCard(props: { model: FlowBarModel }) {
  const { model } = props;
  const request = model.pendingApproval;
  if (!request) return <div className="approval-card" />;
  const Icon = approvalIcons[request.kind];
  return (
    <div className="approval-card" role="alertdialog" aria-label={request.title}>
      <div className="approval-header">
        <span className="approval-icon">
          <Icon size={12} strokeWidth={2.25} aria-hidden />
        </span>
        <span className="approval-title">{request.title}</span>
      </div>
      <div className={`approval-detail${request.kind === 'shellCommand' ? ' is-command' : ''}`}>{request.detail}</div>
      <div className="approval-footer">
        <span className="approval-where">{request.kind === 'shellCommand' ? 'Runs on this PC' : 'Runs in the background'}</span>
        <span className="footer-spacer" />
        <CapsuleButton title="Deny" prominence="secondary" isCompact onClick={() => model.answerPendingApproval(false)} />
        <CapsuleButton title="Allow" prominence="primary" isCompact onClick={() => model.answerPendingApproval(true)} />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Background tasks
// ---------------------------------------------------------------------------------------------------------------------

export function backgroundTaskKindName(kind: BackgroundTask['kind']): string {
  switch (kind) {
    case 'codexAgent':
      return 'Codex';
    case 'claudeAgent':
      return 'Claude Code';
    case 'shellCommand':
      return 'Command';
    case 'ambientAgent':
      return 'Agent';
  }
}

/** An agent that finished with an answer has a report worth reading in full; a command only has output. */
export function backgroundTaskHasReport(backgroundTask: BackgroundTask): boolean {
  return backgroundTask.status === 'succeeded' && backgroundTask.kind !== 'shellCommand' && (backgroundTask.result ?? '').trim().length > 0;
}

const collapseIcons: Record<DockEdge, LucideIcon> = { bottom: ChevronDown, top: ChevronUp, left: ChevronLeft, right: ChevronRight };

function TaskTrayCard(props: { model: FlowBarModel }) {
  const { model } = props;
  const runningCount = model.runningBackgroundTaskCount;
  const finishedCount = model.backgroundTasks.length - runningCount;
  const summary =
    runningCount === 0 ? `${finishedCount} finished` : finishedCount === 0 ? `${runningCount} running` : `${runningCount} running, ${finishedCount} finished`;
  const rowsReference = useRef<HTMLDivElement>(null);
  const [rowsOverflow, setRowsOverflow] = useState(false);
  useLayoutEffect(() => {
    const rowsElement = rowsReference.current;
    if (rowsElement) setRowsOverflow(rowsElement.scrollHeight > rowsElement.clientHeight + 1);
  }, [model.backgroundTasks]);
  return (
    <div className="task-tray-card">
      <div className="task-tray-header">
        <span className="task-tray-title">Background</span>
        <span className="task-tray-summary">{summary}</span>
        <span className="footer-spacer" />
        <GlassIconButton icon={collapseIcons[model.dockEdge]} label="Close" diameter={24} iconSize={12} onClick={() => model.collapseTaskTray()} />
      </div>
      {/* Rows dissolve at the bottom when more are hidden below, instead of being cut by a hard line. */}
      <div ref={rowsReference} className={`task-tray-rows${rowsOverflow ? ' fades-bottom' : ''}`}>
        {model.backgroundTasks.map((backgroundTask) => (
          <TaskRow key={backgroundTask.id} model={model} backgroundTask={backgroundTask} />
        ))}
      </div>
    </div>
  );
}

/** "Codex in ~\code\ambient" — the home folder is shortened the way people write it. */
function taskSourceLine(backgroundTask: BackgroundTask): string {
  const kindName = backgroundTaskKindName(backgroundTask.kind);
  if (!backgroundTask.workingDirectory) return kindName;
  const shortenedDirectory = backgroundTask.workingDirectory.replace(/^[A-Za-z]:\\Users\\[^\\]+/, '~').replace(/^\/(Users|home)\/[^/]+/, '~');
  return `${kindName} in ${shortenedDirectory}`;
}

function taskDetailText(backgroundTask: BackgroundTask): string {
  switch (backgroundTask.status) {
    case 'running':
      return backgroundTask.latestActivity;
    case 'succeeded':
      return backgroundTask.result ? plainTextFromMarkdown(backgroundTask.result) : backgroundTask.latestActivity;
    case 'failed':
      return backgroundTask.result ? plainTextFromMarkdown(backgroundTask.result) : 'It stopped with an error.';
    case 'cancelled':
      return 'Stopped.';
  }
}

function TaskRow(props: { model: FlowBarModel; backgroundTask: BackgroundTask }) {
  const { model, backgroundTask } = props;
  const hasReport = backgroundTaskHasReport(backgroundTask);
  return (
    <div className={`task-row status-${backgroundTask.status}`}>
      <span className="task-row-glyph">
        <TaskStatusGlyph status={backgroundTask.status} />
      </span>
      <div className="task-row-text">
        <div className="task-row-title-line">
          <span className="task-row-title">{backgroundTask.title}</span>
          <ElapsedLabel backgroundTask={backgroundTask} />
        </div>
        <p className="task-row-detail">{taskDetailText(backgroundTask)}</p>
        <p className="task-row-source">{taskSourceLine(backgroundTask)}</p>
        {backgroundTask.status !== 'running' ? (
          <div className="task-row-actions">
            <CapsuleButton
              title={hasReport ? 'Read report' : 'Transcript'}
              icon={hasReport ? FileText : TextAlignStart}
              prominence="secondary"
              isCompact
              onClick={() => model.openBackgroundTaskTranscript(backgroundTask.id)}
            />
            <CapsuleButton title="Dismiss" prominence="quiet" isCompact onClick={() => model.dismissBackgroundTask(backgroundTask.id)} />
          </div>
        ) : null}
      </div>
      {backgroundTask.status === 'running' ? (
        <span className="task-row-stop">
          <GlassIconButton icon={X} label="Stop task" diameter={22} iconSize={11} onClick={() => model.cancelBackgroundTask(backgroundTask.id)} />
        </span>
      ) : null}
    </div>
  );
}

export function TaskStatusGlyph(props: { status: BackgroundTask['status']; size?: number }) {
  const size = props.size ?? 15;
  switch (props.status) {
    case 'running':
      return <RunningArc diameter={size - 2} />;
    case 'succeeded':
      return <CircleCheck size={size} strokeWidth={2.25} className="glyph-succeeded" aria-label="Finished" />;
    case 'failed':
      return <CircleAlert size={size} strokeWidth={2.25} className="glyph-failed" aria-label="Failed" />;
    case 'cancelled':
      return <CircleMinus size={size} strokeWidth={2.25} className="glyph-cancelled" aria-label="Stopped" />;
  }
}

/** The task's running time, ticking once a second while it runs. */
function ElapsedLabel(props: { backgroundTask: BackgroundTask }) {
  const { backgroundTask } = props;
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    if (backgroundTask.finishedAt) return;
    const tickTimer = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(tickTimer);
  }, [backgroundTask.finishedAt]);
  const endDate = backgroundTask.finishedAt ? new Date(backgroundTask.finishedAt) : now;
  return <span className="task-row-elapsed">{formatElapsedTime(new Date(backgroundTask.startedAt), endDate)}</span>;
}

/** A task finished while the bar was resting: the bar briefly opens into a pill that says so. */
function TaskFinishedNotice(props: { model: FlowBarModel }) {
  const { model } = props;
  const finishedTask = model.recentlyFinishedTask;
  const didSucceed = finishedTask?.status === 'succeeded';
  const noticeText = !finishedTask
    ? 'Task finished'
    : finishedTask.status === 'succeeded'
      ? `Done: ${finishedTask.title}`
      : finishedTask.status === 'failed'
        ? `Failed: ${finishedTask.title}`
        : finishedTask.status === 'cancelled'
          ? `Stopped: ${finishedTask.title}`
          : finishedTask.title;
  return (
    <button type="button" className="task-finished-notice" onClick={() => model.toggleTaskTray()}>
      <span className={`task-finished-badge${didSucceed ? '' : ' is-failure'}`}>
        {didSucceed ? <Check size={11} strokeWidth={3.5} /> : <span className="task-finished-exclamation">!</span>}
      </span>
      <span className="pill-label task-finished-text">{noticeText}</span>
      <ChevronRight size={12} strokeWidth={2.75} className="task-finished-chevron" aria-hidden />
    </button>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Right-click menu
// ---------------------------------------------------------------------------------------------------------------------

/** The bar's own menu. Quit lives here too, because the tray icon can hide in the notification area overflow. */
function ContextMenuCard(props: { model: FlowBarModel }) {
  const { model } = props;
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') model.closeContextMenu();
    };
    window.addEventListener('keydown', closeOnEscape);
    return () => window.removeEventListener('keydown', closeOnEscape);
  }, [model]);
  return (
    <div className="context-menu-card" role="menu" aria-label="Ambient">
      <button type="button" role="menuitem" className="context-menu-item" onClick={() => model.openSettings()}>
        Open Settings
      </button>
      <button type="button" role="menuitem" className="context-menu-item" onClick={() => model.checkForUpdates()}>
        Check for Updates…
      </button>
      <span className="context-menu-separator" aria-hidden />
      <button type="button" role="menuitem" className="context-menu-item" onClick={() => model.quit()}>
        Quit Ambient
      </button>
    </div>
  );
}
