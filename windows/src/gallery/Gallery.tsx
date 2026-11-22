import { Minus, Square, X } from 'lucide-react';
import { useMemo, type ReactNode } from 'react';
import { FlowBarSurface } from '../bar/FlowBarSurface';
import type { DockEdge, GateScreen, PermissionStatuses, SettingsSection } from '../host/contract';
import { createMockHost } from '../host/mock';
import { sampleDrawing, sampleGateScreens, sampleSketch } from '../host/mockData';
import { OnboardingView } from '../onboarding/OnboardingWindow';
import { AnnotationOverlay } from '../overlay/AnnotationOverlay';
import { PointerView } from '../overlay/PointerView';
import '../overlay/overlay.css';
import { SettingsWindowView } from '../settings/SettingsWindow';
import { TourCoachCard } from '../tour/TourCoachCard';
import '../tour/tour.css';
import { barCardStateNames, barStateNames, makeBarModel, makeTourModel, tourStateNames, type BarStateName, type TourStateName } from './galleryStates';
import './gallery.css';

// The browser-only gallery (`?window=gallery`, like the Mac's AmbientUIDemo): every bar state on the bottom and left
// edges over a dark and a light desktop with a text window behind it, every Settings page in light and dark,
// onboarding, the tour's coach card and the drawing overlay. Each tile carries `data-capture` so
// scripts/capture-gallery.mjs can save it as its own image. Add `&still=1` for deterministic captures.

type DesktopTone = 'dark' | 'light';

const settingsSections: SettingsSection[] = ['general', 'connectors', 'memory', 'skills', 'activity', 'account'];

export function Gallery() {
  const galleryHost = useMemo(() => createMockHost('settings'), []);
  return (
    <div className="gallery">
      <header className="gallery-header">
        <h1>Ambient for Windows</h1>
        <p>Every surface, driven by the mock host. Bar tiles show a Windows desktop with its taskbar; the bar docks 8 px from the work area.</p>
      </header>

      {(['bottom', 'left'] as DockEdge[]).map((edge) =>
        (['dark', 'light'] as DesktopTone[]).map((desktopTone) => (
          <GallerySection key={`${edge}-${desktopTone}`} title={`Bar on the ${edge} edge, ${desktopTone} desktop`}>
            {barStateNames.map((stateName) => (
              <BarTile key={stateName} stateName={stateName} edge={edge} desktopTone={desktopTone} />
            ))}
          </GallerySection>
        )),
      )}

      <GallerySection title="Bar, increased contrast">
        {(['hovering', 'working', 'reply'] as BarStateName[]).map((stateName) =>
          (['dark', 'light'] as DesktopTone[]).map((desktopTone) => (
            <BarTile key={`${stateName}-${desktopTone}`} stateName={stateName} edge="bottom" desktopTone={desktopTone} isIncreasedContrast />
          )),
        )}
      </GallerySection>

      {(['dark', 'light'] as DesktopTone[]).map((appearance) => (
        <GallerySection key={appearance} title={`Settings, ${appearance}`}>
          {settingsSections.map((section) => (
            <WindowFrame key={section} title="Ambient Settings" appearance={appearance} width={820} height={580} captureName={`settings-${section}-${appearance}`}>
              <SettingsWindowView host={galleryHost} appearanceClassName={`appearance-${appearance}`} initialSection={section} />
            </WindowFrame>
          ))}
        </GallerySection>
      ))}

      <GallerySection title="Onboarding">
        <OnboardingTile captureName="onboarding-sign-in" gateScreen={sampleGateScreens.signIn} permissionStatuses={null} />
        <OnboardingTile captureName="onboarding-waiting" gateScreen={sampleGateScreens.waiting} permissionStatuses={null} />
        <OnboardingTile captureName="onboarding-permissions-not-asked" gateScreen={null} permissionStatuses={{ microphone: 'notYetAsked' }} />
        <OnboardingTile captureName="onboarding-permissions-waiting" gateScreen={null} permissionStatuses={{ microphone: 'waiting' }} />
        <OnboardingTile captureName="onboarding-permissions-denied" gateScreen={null} permissionStatuses={{ microphone: 'deniedInSystemSettings' }} />
        <OnboardingTile captureName="onboarding-permissions-granted" gateScreen={null} permissionStatuses={{ microphone: 'granted' }} />
      </GallerySection>

      {(['dark', 'light'] as DesktopTone[]).map((desktopTone) => (
        <GallerySection key={desktopTone} title={`Tour, ${desktopTone} desktop`}>
          {tourStateNames.map((stateName) => (
            <TourTile key={stateName} stateName={stateName} desktopTone={desktopTone} />
          ))}
        </GallerySection>
      ))}

      <GallerySection title="Pointing and drawing">
        <OverlayTile captureName="drawing-dark" desktopTone="dark">
          <AnnotationOverlay drawing={sampleDrawing()} viewSize={{ width: 900, height: 560 }} isStatic />
        </OverlayTile>
        <OverlayTile captureName="drawing-light" desktopTone="light">
          <AnnotationOverlay drawing={sampleDrawing()} viewSize={{ width: 900, height: 560 }} isStatic />
        </OverlayTile>
        <OverlayTile captureName="sketch-light" desktopTone="light">
          <AnnotationOverlay drawing={sampleSketch()} viewSize={{ width: 900, height: 560 }} isStatic />
        </OverlayTile>
        <OverlayTile captureName="pointer-light" desktopTone="light">
          <PointerView x={330} y={150} label="Share button" labelPlacement="trailingBelow" />
          <PointerView x={700} y={420} label="Link settings" labelPlacement="leadingAbove" />
        </OverlayTile>
      </GallerySection>
    </div>
  );
}

function GallerySection(props: { title: string; children: ReactNode }) {
  return (
    <section className="gallery-section">
      <h2>{props.title}</h2>
      <div className="gallery-grid">{props.children}</div>
    </section>
  );
}

/** A Windows desktop: wallpaper, a document window behind the bar, and the taskbar along the bottom. */
function DesktopBackdrop(props: { desktopTone: DesktopTone; documentPosition?: 'left' | 'centre' }) {
  const paragraph =
    'The review moves to Thursday. Pricing page ships first, then the onboarding copy, then the docs. '.repeat(14);
  return (
    <div className={`desktop-backdrop tone-${props.desktopTone}`} aria-hidden>
      <div className={`desktop-document position-${props.documentPosition ?? 'centre'}`}>
        <div className="desktop-document-caption">
          <span>Launch plan.docx</span>
          <span className="desktop-document-caption-buttons">
            <Minus size={10} />
            <Square size={9} />
            <X size={11} />
          </span>
        </div>
        <h3>Launch plan</h3>
        <p>{paragraph}</p>
      </div>
      <div className="desktop-taskbar">
        <span className="desktop-taskbar-start" />
        <span className="desktop-taskbar-app" />
        <span className="desktop-taskbar-app is-open" />
        <span className="desktop-taskbar-app" />
      </div>
    </div>
  );
}

function BarTile(props: { stateName: BarStateName; edge: DockEdge; desktopTone: DesktopTone; isIncreasedContrast?: boolean }) {
  const model = useMemo(() => makeBarModel(props.stateName, props.edge), [props.stateName, props.edge]);
  const isCard = barCardStateNames.has(props.stateName);
  const captureName = `flowbar-${props.edge}-${props.desktopTone}-${props.stateName}${props.isIncreasedContrast ? '-contrast' : ''}`;
  return (
    <figure
      className={`gallery-tile bar-tile${isCard ? ' is-card' : ''} edge-${props.edge}${props.isIncreasedContrast ? ' contrast-more' : ''}`}
      data-capture={captureName}
    >
      <DesktopBackdrop desktopTone={props.desktopTone} documentPosition={props.edge === 'left' ? 'centre' : 'centre'} />
      <div className="bar-tile-work-area">
        <FlowBarSurface model={model} placement={{ kind: 'docked', gapFromEdge: 8, offsetAlongEdge: 0 }} />
      </div>
      <figcaption>{props.stateName}</figcaption>
    </figure>
  );
}

/** Settings and onboarding are ordinary decorated windows; the gallery draws a plain Windows caption bar over them. */
function WindowFrame(props: { title: string; appearance: DesktopTone; width: number; height: number; captureName: string; children: ReactNode }) {
  return (
    <figure className={`gallery-tile window-frame appearance-${props.appearance}`} data-capture={props.captureName} style={{ width: props.width }}>
      <div className="window-frame-caption">
        <span>{props.title}</span>
        <span className="window-frame-caption-buttons" aria-hidden>
          <Minus size={11} strokeWidth={1.5} />
          <Square size={9.5} strokeWidth={1.5} />
          <X size={12} strokeWidth={1.5} />
        </span>
      </div>
      <div className="window-frame-content" style={{ height: props.height }}>
        {props.children}
      </div>
    </figure>
  );
}

function OnboardingTile(props: { captureName: string; gateScreen: GateScreen | null; permissionStatuses: PermissionStatuses | null }) {
  return (
    <WindowFrame title="Ambient" appearance="dark" width={600} height={530} captureName={props.captureName}>
      <OnboardingView
        gateScreen={props.gateScreen}
        permissionStatuses={props.permissionStatuses}
        onGateAction={() => undefined}
        onGrantMicrophone={() => undefined}
        onContinue={() => undefined}
      />
    </WindowFrame>
  );
}

function TourTile(props: { stateName: TourStateName; desktopTone: DesktopTone }) {
  const model = useMemo(() => makeTourModel(props.stateName), [props.stateName]);
  const barModel = useMemo(() => makeBarModel(props.stateName === 'talk-listening' ? 'listening' : 'resting', 'bottom'), [props.stateName]);
  return (
    <figure className="gallery-tile tour-tile" data-capture={`tour-${props.desktopTone}-${props.stateName}`}>
      <DesktopBackdrop desktopTone={props.desktopTone} documentPosition="left" />
      <div className="bar-tile-work-area">
        <FlowBarSurface model={barModel} placement={{ kind: 'docked', gapFromEdge: 8, offsetAlongEdge: 0 }} />
      </div>
      <div className="tour-tile-corner">
        <TourCoachCard model={model} />
      </div>
      <figcaption>{props.stateName}</figcaption>
    </figure>
  );
}

function OverlayTile(props: { captureName: string; desktopTone: DesktopTone; children: ReactNode }) {
  return (
    <figure className={`gallery-tile overlay-tile tone-${props.desktopTone}`} data-capture={props.captureName}>
      {props.children}
    </figure>
  );
}
