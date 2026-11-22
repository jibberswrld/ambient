// The per-bar physics of the voice waveform, ported from FlowBarWaveformDynamics in FlowBarIndicators.swift: attack
// quickly, release slowly, like a VU meter. Each bar follows the real microphone level through its own envelope, so loud
// syllables lift the centre first and silence settles the bars to dots. Nothing loops on its own while listening.

export class WaveformDynamics {
  /** Bars at rest show as dots of this normalised length. */
  static readonly restingLength = 0.12;

  barLengths: number[];
  smoothedLevel = 0;
  private lastUpdateSeconds: number | null = null;
  private readonly centreEmphasis: number[];
  private readonly wobbleFrequencies: number[];
  private readonly wobblePhases: number[];

  constructor(barCount: number) {
    this.barLengths = Array.from({ length: barCount }, () => WaveformDynamics.restingLength);
    const centreIndex = (barCount - 1) / 2;
    // The centre bars carry the voice; the outer bars are quieter echoes of it.
    this.centreEmphasis = Array.from({ length: barCount }, (_unused, barIndex) => {
      const distanceFromCentre = Math.abs(barIndex - centreIndex) / Math.max(centreIndex, 1);
      return 1 - 0.62 * distanceFromCentre * distanceFromCentre;
    });
    // Fixed, uneven frequencies so neighbouring bars never move in lockstep.
    this.wobbleFrequencies = Array.from({ length: barCount }, (_unused, barIndex) => 5.3 + ((barIndex * 7) % 5) * 1.17);
    this.wobblePhases = Array.from({ length: barCount }, (_unused, barIndex) => barIndex * 1.91);
  }

  advance(nowSeconds: number, inputLevel: number, isTranscribing: boolean, reduceMotion: boolean, settlesInstantly: boolean): number[] {
    const elapsedSeconds = this.lastUpdateSeconds === null ? 1 / 60 : Math.min(nowSeconds - this.lastUpdateSeconds, 0.1);
    this.lastUpdateSeconds = nowSeconds;

    // Lift quiet speech so normal talking fills the bars without shouting.
    const perceivedLevel = Math.pow(Math.min(Math.max(inputLevel, 0), 1), 0.6);
    this.smoothedLevel = settlesInstantly
      ? perceivedLevel
      : followEnvelope(this.smoothedLevel, perceivedLevel, elapsedSeconds, 0.04, 0.16);

    for (let barIndex = 0; barIndex < this.barLengths.length; barIndex += 1) {
      let targetLength: number;
      if (isTranscribing) {
        // The voice has stopped: one bright swell sweeps across the dots while the words are read back, so "working on
        // what you said" looks different from "listening to silence".
        const sweepPeriodSeconds = 0.9;
        const sweepPosition = reduceMotion ? 0.5 : ((nowSeconds / sweepPeriodSeconds) % 1) * 1.4 - 0.2;
        const barPosition = barIndex / Math.max(this.barLengths.length - 1, 1);
        const distanceFromSweep = (barPosition - sweepPosition) / 0.14;
        const swell = Math.exp(-distanceFromSweep * distanceFromSweep);
        targetLength = WaveformDynamics.restingLength + 0.34 * swell;
      } else {
        const variation = reduceMotion
          ? 1
          : 0.62 + 0.38 * (0.5 + 0.5 * Math.sin(nowSeconds * this.wobbleFrequencies[barIndex] + this.wobblePhases[barIndex]));
        const drive = Math.min(1, this.smoothedLevel * this.centreEmphasis[barIndex] * variation * 1.35);
        targetLength = WaveformDynamics.restingLength + (1 - WaveformDynamics.restingLength) * drive;
      }
      this.barLengths[barIndex] = settlesInstantly
        ? targetLength
        : followEnvelope(this.barLengths[barIndex], targetLength, elapsedSeconds, 0.05, 0.13);
    }
    return this.barLengths;
  }
}

/** Exponential approach toward `target`, faster when rising than when falling. */
function followEnvelope(current: number, target: number, elapsedSeconds: number, attackSeconds: number, releaseSeconds: number): number {
  const timeConstant = target > current ? attackSeconds : releaseSeconds;
  const blend = 1 - Math.exp(-elapsedSeconds / timeConstant);
  return current + (target - current) * blend;
}
