import { StrictMode, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import './design/tokens.css';
import './design/controls.css';
import './bar/flowBar.css';
import './windows.css';
import { BarWindow } from './bar/BarWindow';
import { isStillCaptureMode } from './design/stillCapture';
import { getHost, isRunningInTauri, windowLabelFromQuery } from './host';
import { OnboardingWindow } from './onboarding/OnboardingWindow';
import { OverlayWindow } from './overlay/OverlayWindow';
import { SettingsWindow } from './settings/SettingsWindow';
import { TourWindow } from './tour/TourWindow';
import { Gallery } from './gallery/Gallery';

// One page, five windows: the surface comes from the Tauri window label, or `?window=<label>` in a browser preview.
// `?window=gallery` (browser only) shows every state of every surface side by side.

const host = getHost();
const requestedWindow = new URLSearchParams(window.location.search).get('window');
const isGallery = !isRunningInTauri() && requestedWindow === 'gallery';
const windowLabel = isRunningInTauri() ? host.ownWindow.label : windowLabelFromQuery();

document.documentElement.dataset.window = isGallery ? 'gallery' : windowLabel;
document.documentElement.dataset.preview = isRunningInTauri() ? 'app' : 'browser';
if (isStillCaptureMode()) document.documentElement.classList.add('is-still-capture');

function surfaceForWindow(): ReactNode {
  if (isGallery) return <Gallery />;
  switch (windowLabel) {
    case 'bar':
      return <BarWindow host={host} />;
    case 'settings':
      return <SettingsWindow host={host} />;
    case 'onboarding':
      return <OnboardingWindow host={host} />;
    case 'tour':
      return <TourWindow host={host} />;
    case 'overlay':
      return <OverlayWindow host={host} />;
  }
}

createRoot(document.getElementById('root')!).render(<StrictMode>{surfaceForWindow()}</StrictMode>);
