import { Search, WifiOff } from 'lucide-react';
import { useCallback, useEffect, useRef, useState } from 'react';
import type { AmbientHost, ConnectorApp } from '../host/contract';
import { CapsuleButton, RunningArc } from '../design/controls';
import { EmptyState, FieldContainer, InlineError, ListCard, LoadingRows, SettingsPage, SettingsSectionLabel, messageFromRejection } from './settingsShared';

type ConnectorLoadState = { kind: 'loading' } | { kind: 'loaded'; apps: ConnectorApp[] } | { kind: 'failed'; message: string };

/** Typing pauses this long before a search goes out, so each keystroke does not cost a request. */
const searchDebounceMilliseconds = 250;

/** Connected apps first, then by name. */
function sortedForDisplay(apps: ConnectorApp[]): ConnectorApp[] {
  return [...apps].sort((firstApp, secondApp) => {
    if (firstApp.isConnected !== secondApp.isConnected) return firstApp.isConnected ? -1 : 1;
    return firstApp.name.localeCompare(secondApp.name, undefined, { sensitivity: 'base' });
  });
}

/**
 * Connectors: search apps, connect them in the browser, disconnect them. After Connect the row says "Finish in your
 * browser" until the app comes back connected; the list refreshes when the window regains focus, which is when the
 * person returns from authorising.
 */
export function ConnectorsPage(props: { host: AmbientHost }) {
  const { host } = props;
  const [searchQuery, setSearchQuery] = useState('');
  const [loadState, setLoadState] = useState<ConnectorLoadState>({ kind: 'loading' });
  /** Apps whose browser authorisation is open, waiting for the person to come back. */
  const [appSlugsAwaitingAuthorization, setAppSlugsAwaitingAuthorization] = useState<Set<string>>(() => new Set());
  const [appSlugsBeingDisconnected, setAppSlugsBeingDisconnected] = useState<Set<string>>(() => new Set());
  const [actionErrorMessage, setActionErrorMessage] = useState<string | null>(null);

  // The query a load started with is compared with the latest one, so a slow answer to an old search never
  // overwrites the answer to the search the person is looking at now.
  const latestSearchQueryReference = useRef(searchQuery);
  latestSearchQueryReference.current = searchQuery;

  const loadApps = useCallback(
    async (showingPlaceholder: boolean) => {
      if (showingPlaceholder) setLoadState({ kind: 'loading' });
      const queryAtStart = latestSearchQueryReference.current;
      try {
        const apps = await host.invoke('get_connector_apps', { query: queryAtStart.trim() });
        if (queryAtStart !== latestSearchQueryReference.current) return;
        setLoadState({ kind: 'loaded', apps: sortedForDisplay(apps) });
        const connectedSlugs = new Set(apps.filter((app) => app.isConnected).map((app) => app.slug));
        setAppSlugsAwaitingAuthorization((previousSlugs) => new Set([...previousSlugs].filter((slug) => !connectedSlugs.has(slug))));
      } catch (rejection) {
        if (queryAtStart !== latestSearchQueryReference.current) return;
        setLoadState({ kind: 'failed', message: messageFromRejection(rejection, 'Could not reach your connectors. Check your connection and try again.') });
      }
    },
    [host],
  );

  useEffect(() => {
    // An empty query (the first load, or a cleared search) goes out at once; typing waits for a pause.
    const delayMilliseconds = searchQuery.length > 0 ? searchDebounceMilliseconds : 0;
    const searchTimer = setTimeout(() => void loadApps(true), delayMilliseconds);
    return () => clearTimeout(searchTimer);
  }, [searchQuery, loadApps]);

  useEffect(() => {
    // Coming back from the browser after authorising: refresh quietly so the new connection shows.
    const refreshAfterReturning = () => void loadApps(false);
    window.addEventListener('focus', refreshAfterReturning);
    return () => window.removeEventListener('focus', refreshAfterReturning);
  }, [loadApps]);

  async function connect(app: ConnectorApp) {
    setActionErrorMessage(null);
    try {
      await host.invoke('authorize_connector', { appSlug: app.slug });
      setAppSlugsAwaitingAuthorization((previousSlugs) => new Set(previousSlugs).add(app.slug));
    } catch {
      setActionErrorMessage(`Could not start connecting ${app.name}. Try again.`);
    }
  }

  async function disconnect(app: ConnectorApp) {
    setActionErrorMessage(null);
    setAppSlugsBeingDisconnected((previousSlugs) => new Set(previousSlugs).add(app.slug));
    try {
      await host.invoke('disconnect_connector', { appSlug: app.slug });
      await loadApps(false);
    } catch {
      setActionErrorMessage(`Could not disconnect ${app.name}. Try again.`);
    } finally {
      setAppSlugsBeingDisconnected((previousSlugs) => {
        const remainingSlugs = new Set(previousSlugs);
        remainingSlugs.delete(app.slug);
        return remainingSlugs;
      });
    }
  }

  return (
    <SettingsPage section="connectors">
      <div className="settings-stack is-tight">
        <FieldContainer icon={Search}>
          <input
            className="settings-field-input"
            type="search"
            placeholder="Search apps"
            aria-label="Search apps"
            value={searchQuery}
            spellCheck={false}
            onChange={(event) => setSearchQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Escape') setSearchQuery('');
            }}
          />
        </FieldContainer>
        {actionErrorMessage ? <InlineError message={actionErrorMessage} /> : null}
        <ConnectorList
          loadState={loadState}
          searchQuery={searchQuery}
          appSlugsAwaitingAuthorization={appSlugsAwaitingAuthorization}
          appSlugsBeingDisconnected={appSlugsBeingDisconnected}
          onRetry={() => void loadApps(true)}
          onConnect={(app) => void connect(app)}
          onDisconnect={(app) => void disconnect(app)}
        />
      </div>
    </SettingsPage>
  );
}

function ConnectorList(props: {
  loadState: ConnectorLoadState;
  searchQuery: string;
  appSlugsAwaitingAuthorization: Set<string>;
  appSlugsBeingDisconnected: Set<string>;
  onRetry: () => void;
  onConnect: (app: ConnectorApp) => void;
  onDisconnect: (app: ConnectorApp) => void;
}) {
  const { loadState } = props;
  if (loadState.kind === 'loading') return <LoadingRows rowCount={6} />;
  if (loadState.kind === 'failed') {
    return (
      <EmptyState
        icon={WifiOff}
        title="Connectors did not load"
        message={loadState.message}
        isError
        action={<CapsuleButton title="Try again" prominence="secondary" surface="window" onClick={props.onRetry} />}
      />
    );
  }
  if (loadState.apps.length === 0) {
    return <EmptyState icon={Search} title="No apps match" message={`Nothing called “${props.searchQuery.trim()}”. Try another name.`} />;
  }
  const connectedCount = loadState.apps.filter((app) => app.isConnected).length;
  return (
    <>
      {connectedCount > 0 && props.searchQuery.length === 0 ? (
        <div className="settings-label-above-list">
          <SettingsSectionLabel>
            <span className="tabular-figures">{connectedCount}</span> connected
          </SettingsSectionLabel>
        </div>
      ) : null}
      <ListCard label="Apps">
        {loadState.apps.map((app) => (
          <ConnectorRow
            key={app.slug}
            app={app}
            isAwaitingAuthorization={props.appSlugsAwaitingAuthorization.has(app.slug)}
            isDisconnecting={props.appSlugsBeingDisconnected.has(app.slug)}
            onConnect={() => props.onConnect(app)}
            onDisconnect={() => props.onDisconnect(app)}
          />
        ))}
      </ListCard>
    </>
  );
}

function ConnectorRow(props: {
  app: ConnectorApp;
  isAwaitingAuthorization: boolean;
  isDisconnecting: boolean;
  onConnect: () => void;
  onDisconnect: () => void;
}) {
  const { app } = props;
  return (
    <div className="settings-list-row connector-row" role="listitem">
      <AppLogo name={app.name} logoUrl={app.logoUrl} />
      <div className="settings-list-row-text">
        <p className="settings-list-row-title">{app.name}</p>
        {app.isConnected ? (
          <p className="connector-status">
            <span className="connector-status-dot" aria-hidden />
            Connected
          </p>
        ) : props.isAwaitingAuthorization ? (
          <p className="connector-status">Finish in your browser</p>
        ) : null}
      </div>
      <div className="settings-list-row-trailing">
        {props.isDisconnecting ? (
          <span className="connector-progress">
            <RunningArc diameter={14} label="Disconnecting" />
          </span>
        ) : app.isConnected ? (
          // Disconnect is destructive and rarely wanted, so it only appears under the pointer (or keyboard focus).
          <span className="reveal-on-row-hover">
            <CapsuleButton title="Disconnect" prominence="quiet" surface="window" isCompact onClick={props.onDisconnect} />
          </span>
        ) : props.isAwaitingAuthorization ? (
          <CapsuleButton title="Open again" prominence="quiet" surface="window" isCompact onClick={props.onConnect} />
        ) : (
          <CapsuleButton title="Connect" prominence="secondary" surface="window" isCompact onClick={props.onConnect} />
        )}
      </div>
    </div>
  );
}

/** The app's logo on white, or its first letter when there is none or it fails to load. */
function AppLogo(props: { name: string; logoUrl: string | null }) {
  const [didLogoFail, setDidLogoFail] = useState(false);
  useEffect(() => setDidLogoFail(false), [props.logoUrl]);
  const showsLogo = props.logoUrl !== null && !didLogoFail;
  return (
    <span className={`app-logo${showsLogo ? ' has-image' : ''}`} aria-hidden>
      {showsLogo ? (
        <img className="app-logo-image" src={props.logoUrl ?? undefined} alt="" draggable={false} onError={() => setDidLogoFail(true)} />
      ) : (
        props.name.slice(0, 1).toUpperCase()
      )}
    </span>
  );
}
