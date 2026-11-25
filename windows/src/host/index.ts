import type { AmbientHost, AmbientWindowLabel } from './contract';
import { createMockHost } from './mock';
import { createTauriHost } from './tauri';

/** True inside the Tauri webview (Tauri injects `__TAURI_INTERNALS__`); false in a plain browser preview. */
export function isRunningInTauri(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

const knownWindowLabels: AmbientWindowLabel[] = ['bar', 'settings', 'onboarding', 'tour', 'overlay'];

/** The browser preview's window: `?window=<label>` (default `bar`). */
export function windowLabelFromQuery(): AmbientWindowLabel {
  const requestedLabel = new URLSearchParams(window.location.search).get('window');
  return knownWindowLabels.find((label) => label === requestedLabel) ?? 'bar';
}

let sharedHost: AmbientHost | null = null;

/** The one host for this window: the real Tauri host in the app, the scripted mock in a browser. */
export function getHost(): AmbientHost {
  if (!sharedHost) sharedHost = isRunningInTauri() ? createTauriHost() : createMockHost(windowLabelFromQuery());
  return sharedHost;
}
