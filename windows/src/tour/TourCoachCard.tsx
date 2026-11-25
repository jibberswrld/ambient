import { ArrowUpRight, AudioLines, Check, CircleAlert, CornerDownRight, RotateCcw } from 'lucide-react';
import { forwardRef } from 'react';
import { CapsuleButton, EmberIndicator, KeycapRow } from '../design/controls';
import { keycapLabels, spokenShortcutName } from '../design/shortcuts';
import { useModelVersion } from '../design/useModel';
import { EdgePictureForTour } from './EdgePictureForTour';
import {
  allTourLessons,
  tourLessonBodyText,
  tourLessonNumber,
  tourLessonSkipTitle,
  tourLessonSuggestedPhrase,
  tourLessonTitle,
  type TourLesson,
  type TourModel,
  type TourStatus,
  type TourStatusAction,
} from './tourModel';

// The coach card, ported from AmbientTourViews.swift: a small piece of the bar's smoked glass, floating away from it.
// It teaches one real action at a time and its status line says what is actually happening.

export const TourCoachCard = forwardRef<HTMLDivElement, { model: TourModel; onBackgroundPointerDown?: (event: React.PointerEvent) => void }>(
  function TourCoachCard(props, cardReference) {
    const { model } = props;
    useModelVersion(model);
    const step = model.step;
    return (
      <div
        ref={cardReference}
        className="tour-coach-card smoked-glass is-raised-card"
        role="dialog"
        aria-label="Ambient tour"
        onPointerDown={props.onBackgroundPointerDown}
      >
        {step.kind === 'lesson' ? (
          <LessonContent key={step.lesson} model={model} lesson={step.lesson} />
        ) : (
          <FinishContent key="finished" model={model} />
        )}
      </div>
    );
  },
);

function LessonContent(props: { model: TourModel; lesson: TourLesson }) {
  const { model, lesson } = props;
  const status = model.status;
  const suggestedPhrase = tourLessonSuggestedPhrase(lesson);
  return (
    <div className="tour-lesson">
      <TourHeader model={model} lesson={lesson} />
      <h2 className="tour-lesson-title">{tourLessonTitle(lesson)}</h2>
      <p key={String(model.isCurrentLessonComplete)} className="tour-lesson-body">
        {model.completionNote ?? tourLessonBodyText(lesson, model.shortcut)}
      </p>
      {!model.isCurrentLessonComplete && suggestedPhrase ? (
        <div className="tour-phrase-block" aria-label={`Hold ${spokenShortcutName(model.shortcut)} and say: ${suggestedPhrase}`}>
          <div className="tour-phrase-lead">
            <KeycapRow labels={keycapLabels(model.shortcut)} size={18} isPressed={model.isShortcutHeld} />
            <span>{lesson === 'talk' ? 'Hold and say anything, like' : 'Hold and say'}</span>
          </div>
          <p className="tour-phrase">“{suggestedPhrase}”</p>
        </div>
      ) : null}
      {!model.isCurrentLessonComplete && lesson === 'placeBar' ? (
        <div className="tour-edge-diagram">
          <EdgePictureForTour dockEdge={model.dockEdge} />
          <p>Drag the bar itself. Let go and it settles on the nearest edge.</p>
        </div>
      ) : null}
      <StatusRow status={status} trailingControl={<TrailingControl model={model} lesson={lesson} status={status} />} />
    </div>
  );
}

/** The step indicator, "2 of 5", and the quiet way out. */
function TourHeader(props: { model: TourModel; lesson: TourLesson }) {
  const { model, lesson } = props;
  const lessonIndex = allTourLessons.indexOf(lesson);
  return (
    <div className="tour-header" aria-label={`Step ${tourLessonNumber(lesson)} of ${allTourLessons.length}`}>
      <ProgressSegments completedCount={lessonIndex + (model.isCurrentLessonComplete ? 1 : 0)} currentIndex={lessonIndex} />
      <span className="tour-step-count">
        {tourLessonNumber(lesson)} of {allTourLessons.length}
      </span>
      <span className="tour-header-spacer" />
      <span className="tour-header-buttons">
        {/* The last lesson's way past is its own answer ("It's fine here") beside the status line. */}
        {lesson !== 'placeBar' && !model.isCurrentLessonComplete ? (
          <CapsuleButton title={tourLessonSkipTitle(lesson)} prominence="quiet" isCompact onClick={() => model.skipCurrentLesson()} />
        ) : null}
        <CapsuleButton title="End tour" prominence="quiet" isCompact onClick={() => model.endTour()} />
      </span>
    </div>
  );
}

/** One short segment per lesson: ember when done, bright for the current one, faint for the rest. */
function ProgressSegments(props: { completedCount: number; currentIndex: number | null }) {
  return (
    <span className="tour-progress" aria-hidden>
      {allTourLessons.map((lesson, lessonIndex) => (
        <span
          key={lesson}
          className={`tour-progress-segment${lessonIndex < props.completedCount ? ' is-done' : lessonIndex === props.currentIndex ? ' is-current' : ''}`}
        />
      ))}
    </span>
  );
}

function actionTitle(action: TourStatusAction): string {
  if (action.kind === 'tryAgain') return 'Try again';
  return action.permissionStatus === 'notYetAsked' ? 'Allow' : 'Open settings';
}

/** The one control beside the status line: Next when done, the fix for a problem, or the lesson's own action. */
function TrailingControl(props: { model: TourModel; lesson: TourLesson; status: TourStatus }) {
  const { model, lesson, status } = props;
  if (model.isCurrentLessonComplete) {
    return <CapsuleButton title="Next" prominence="primary" isCompact isDefaultAction onClick={() => model.advanceToNextStep()} />;
  }
  if (status.action) {
    const action = status.action;
    const icon = action.kind === 'tryAgain' ? RotateCcw : action.permissionStatus === 'notYetAsked' ? undefined : ArrowUpRight;
    return <CapsuleButton title={actionTitle(action)} icon={icon} prominence="secondary" isCompact onClick={() => model.performStatusAction(action)} />;
  }
  if (lesson === 'connectApps') {
    return (
      <CapsuleButton
        title="Open Connectors"
        icon={ArrowUpRight}
        prominence={model.hasOpenedConnectors ? 'secondary' : 'primary'}
        isCompact
        onClick={() => model.openConnectors()}
      />
    );
  }
  if (lesson === 'placeBar') {
    return <CapsuleButton title={tourLessonSkipTitle(lesson)} prominence="secondary" isCompact onClick={() => model.skipCurrentLesson()} />;
  }
  return null;
}

/** The live line: an indicator for the kind of moment, the words, and at most one control beside them. */
function StatusRow(props: { status: TourStatus; trailingControl: React.ReactNode }) {
  const { status } = props;
  return (
    <div className={`tour-status-row tone-${status.tone}`}>
      <span className="tour-status-indicator">
        <StatusIndicator tone={status.tone} />
      </span>
      <span key={status.text} className="tour-status-text" aria-live="polite">
        {status.text}
      </span>
      {props.trailingControl}
    </div>
  );
}

function StatusIndicator(props: { tone: TourStatus['tone'] }) {
  switch (props.tone) {
    case 'waiting':
      return <span className="tour-waiting-ring" />;
    case 'listening':
      return <EmberIndicator activity="thinking" diameter={12} />;
    case 'working':
      return <EmberIndicator activity="working" diameter={11} />;
    case 'nudge':
      return <CornerDownRight size={12} strokeWidth={2.75} className="tour-nudge-icon" />;
    case 'problem':
      return <CircleAlert size={14} strokeWidth={2.5} className="tour-problem-icon" />;
    case 'done':
      return (
        <span className="tour-done-mark" aria-label="Done">
          <Check size={9} strokeWidth={4} />
        </span>
      );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Finish
// ---------------------------------------------------------------------------------------------------------------------

const exampleRequests = ["What's on my calendar tomorrow?", 'Draw how to turn on Do not disturb.', 'Start an agent to compare three standing desks.'];

/** The last card doubles as a cheat sheet, so the person leaves with the short version in front of them. */
function FinishContent(props: { model: TourModel }) {
  const { model } = props;
  return (
    <div className="tour-lesson">
      <div className="tour-header">
        <ProgressSegments completedCount={allTourLessons.length} currentIndex={null} />
        <span className="tour-step-count">Done</span>
      </div>
      <h2 className="tour-lesson-title">You're set</h2>
      <p className="tour-lesson-body">Here is the short version, for when you need it.</p>
      <div className="tour-cheat-sheet">
        <div className="tour-cheat-row">
          <span className="tour-cheat-leading">
            <KeycapRow labels={keycapLabels(model.shortcut)} size={18} />
          </span>
          <span>Hold to talk, let go to send.</span>
        </div>
        <div className="tour-cheat-row">
          <span className="tour-cheat-leading">
            {/* The resting bar itself, so "the bar" has a picture. */}
            <span className="tour-resting-bar-picture" />
          </span>
          <span>Click the bar to type instead.</span>
        </div>
        <div className="tour-cheat-row">
          <span className="tour-cheat-leading">
            <AudioLines size={15} strokeWidth={2.25} className="tour-tray-icon" />
          </span>
          <span>Settings and Replay the tour are in Ambient's icon in the taskbar corner.</span>
        </div>
      </div>
      <p className="tour-things-to-try-label">Things to try</p>
      <ul className="tour-things-to-try">
        {exampleRequests.map((exampleRequest) => (
          <li key={exampleRequest}>“{exampleRequest}”</li>
        ))}
      </ul>
      <div className="tour-finish-footer">
        <CapsuleButton title="Done" prominence="primary" isCompact isDefaultAction onClick={() => model.endTour()} />
      </div>
    </div>
  );
}
