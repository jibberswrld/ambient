/**
 * The gallery's still-capture mode (`?still=1`): indicators rest at their middle values and the waveform draws one
 * settled frame, so screenshots are deterministic. Never on in the app.
 */
export function isStillCaptureMode(): boolean {
  return typeof window !== 'undefined' && new URLSearchParams(window.location.search).get('still') === '1';
}
