import type { CSSProperties } from 'react';
import type { OverlayDrawing } from '../host/contract';
import { annotationInkColor, annotationPathData, captionCenters, scaleAnnotationToView, type OverlaySize } from './annotationGeometry';

// Ambient drawing on the screen, ported from AmbientAnnotationOverlay.swift: each annotation is stroked one after
// another, as if drawn by hand, and its caption rises in when the stroke lands. Several captions are numbered so they
// read as steps. The host sends shapes in capture pixels; they are scaled to the overlay's own pixels here so strokes
// and captions keep their designed size whatever the capture's resolution.

/** Seconds between one annotation starting and the next. */
const staggerSeconds = 0.42;
const strokeSeconds = 0.46;

export function AnnotationOverlay(props: { drawing: OverlayDrawing; viewSize: OverlaySize; isStatic?: boolean }) {
  const { drawing, viewSize } = props;
  const scaleX = viewSize.width / drawing.captureWidth;
  const scaleY = viewSize.height / drawing.captureHeight;
  const annotations = drawing.annotations.map((annotation) => scaleAnnotationToView(annotation, scaleX, scaleY));
  const captionedCount = annotations.filter((annotation) => (annotation.text ?? '').length > 0).length;
  const numbersSteps = captionedCount > 1;
  const captionPositions = captionCenters(annotations, viewSize);
  let stepNumber = 0;

  return (
    <div
      className={`annotation-overlay${props.isStatic ? ' is-static' : ''}`}
      role="img"
      aria-label={annotations.map((annotation) => annotation.text).filter(Boolean).join('. ')}
    >
      <svg className="annotation-strokes" width={viewSize.width} height={viewSize.height} viewBox={`0 0 ${viewSize.width} ${viewSize.height}`}>
        {annotations.map((annotation, annotationIndex) => {
          const pathData = annotationPathData(annotation.shape);
          if (!pathData) return null;
          const inkColor = annotationInkColor(annotation.ink);
          const timing = { '--annotation-delay': `${annotationIndex * staggerSeconds}s`, '--stroke-duration': `${strokeSeconds}s` } as CSSProperties;
          return (
            <g key={annotationIndex} style={timing}>
              {annotation.isFilled ? <path className="annotation-fill" d={pathData} fill={inkColor} /> : null}
              {/* An under-stroke of the opposite tone keeps the line readable on white pages and bright photos. */}
              <path
                className="annotation-stroke"
                d={pathData}
                pathLength={1}
                stroke={annotation.ink === 'black' ? 'rgb(255 255 255 / 0.55)' : 'rgb(0 0 0 / 0.42)'}
                strokeWidth={6.5}
              />
              <path
                className="annotation-stroke annotation-ink"
                d={pathData}
                pathLength={1}
                stroke={inkColor}
                strokeWidth={3.5}
                style={{ filter: `drop-shadow(0 0 5px ${inkColor.replace('rgb(', 'rgba(').replace(')', ', 0.55)')})` }}
              />
            </g>
          );
        })}
      </svg>
      {annotations.map((annotation, annotationIndex) => {
        const captionPosition = captionPositions[annotationIndex];
        if (!annotation.text || !captionPosition) return null;
        stepNumber += 1;
        return (
          <div
            key={annotationIndex}
            className="annotation-caption smoked-glass"
            style={
              {
                left: captionPosition.x,
                top: captionPosition.y,
                '--annotation-delay': `${annotationIndex * staggerSeconds + strokeSeconds * 0.7}s`,
              } as CSSProperties
            }
          >
            {numbersSteps ? <span className="annotation-step-number">{stepNumber}</span> : null}
            <span className="annotation-caption-text">{annotation.text}</span>
          </div>
        );
      })}
    </div>
  );
}
