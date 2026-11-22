import { useEffect, useRef } from 'react';
import { isStillCaptureMode } from '../design/stillCapture';
import { usePrefersReducedMotion } from '../design/useModel';
import type { FlowBarModel } from './flowBarModel';
import { WaveformDynamics } from './waveformDynamics';

const barCount = 13;
const barThickness = 2.5;
const barSpacing = 2.5;
const barMaximumLength = 20;
const stackLength = barCount * barThickness + (barCount - 1) * barSpacing;

/**
 * The live voice waveform, drawn on a canvas every frame from the model's audio level. Louder bars run warmer, so the
 * centre of a loud word glows ember; a faint ember glow behind the bars brightens with the voice.
 */
export function WaveformView(props: { model: FlowBarModel; mode: 'listening' | 'transcribing'; isUpright: boolean; isStillCapture?: boolean }) {
  const { model, mode, isUpright } = props;
  const isStillCapture = props.isStillCapture ?? isStillCaptureMode();
  const canvasReference = useRef<HTMLCanvasElement>(null);
  const reduceMotion = usePrefersReducedMotion();
  const pillWidth = isUpright ? 36 : 104;
  const pillHeight = isUpright ? 104 : 36;

  useEffect(() => {
    const canvas = canvasReference.current;
    if (!canvas) return;
    const drawingContext = canvas.getContext('2d');
    if (!drawingContext) return;
    const pixelRatio = window.devicePixelRatio || 1;
    canvas.width = pillWidth * pixelRatio;
    canvas.height = pillHeight * pixelRatio;
    const dynamics = new WaveformDynamics(barCount);
    let animationFrameRequest = 0;

    const drawFrame = (timestampMilliseconds: number) => {
      const barLengths = dynamics.advance(timestampMilliseconds / 1000, model.audioLevel, mode === 'transcribing', reduceMotion, isStillCapture);
      drawingContext.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
      drawingContext.clearRect(0, 0, pillWidth, pillHeight);

      // Kept faint: ember at high alpha over smoke turns muddy brown. The glow is a hint of warmth, not a blob.
      const glowStrength = mode === 'transcribing' ? 0.06 : 0.05 + 0.22 * dynamics.smoothedLevel;
      const centreX = pillWidth / 2;
      const centreY = pillHeight / 2;
      const glowRadius = Math.min(pillWidth, pillHeight) * 0.9;
      drawingContext.save();
      drawingContext.translate(centreX, centreY);
      drawingContext.scale(isUpright ? 1 : 1.6, isUpright ? 1.6 : 1);
      const glowGradient = drawingContext.createRadialGradient(0, 0, 0, 0, 0, glowRadius);
      glowGradient.addColorStop(0, `rgba(255, 149, 74, ${glowStrength})`);
      glowGradient.addColorStop(1, 'rgba(255, 149, 74, 0)');
      drawingContext.fillStyle = glowGradient;
      drawingContext.beginPath();
      drawingContext.arc(0, 0, glowRadius, 0, Math.PI * 2);
      drawingContext.fill();
      drawingContext.restore();

      const stackStart = ((isUpright ? pillHeight : pillWidth) - stackLength) / 2;
      barLengths.forEach((normalizedLength, barIndex) => {
        const barLength = Math.max(barThickness, normalizedLength * barMaximumLength);
        const positionAlongStack = stackStart + barIndex * (barThickness + barSpacing);
        const warmth = Math.min(1, normalizedLength * 1.3);
        const green = Math.round(255 * (0.97 - 0.27 * warmth));
        const blue = Math.round(255 * (0.93 - 0.55 * warmth));
        drawingContext.fillStyle = `rgba(255, ${green}, ${blue}, 0.94)`;
        drawingContext.beginPath();
        if (isUpright) {
          drawingContext.roundRect((pillWidth - barLength) / 2, positionAlongStack, barLength, barThickness, barThickness / 2);
        } else {
          drawingContext.roundRect(positionAlongStack, (pillHeight - barLength) / 2, barThickness, barLength, barThickness / 2);
        }
        drawingContext.fill();
      });
      if (!isStillCapture) animationFrameRequest = requestAnimationFrame(drawFrame);
    };
    animationFrameRequest = requestAnimationFrame(drawFrame);
    return () => cancelAnimationFrame(animationFrameRequest);
  }, [model, mode, isUpright, reduceMotion, pillWidth, pillHeight, isStillCapture]);

  return (
    <canvas
      ref={canvasReference}
      className="waveform-canvas"
      style={{ width: pillWidth, height: pillHeight, display: 'block' }}
      role="img"
      aria-label={mode === 'listening' ? 'Listening' : 'Transcribing'}
    />
  );
}
