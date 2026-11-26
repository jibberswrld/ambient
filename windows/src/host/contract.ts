// THE HOST CONTRACT.
//
// This file is the whole agreement between Ambient's interface (this Vite app, loaded in five Tauri windows) and the
// Rust core. The interface talks to Rust only through the `AmbientHost` defined at the bottom of this file; the Rust
// side implements every command and emits every event listed here, exactly as written.
//
// Conventions
// - Commands are `invoke(name, args)` with a snake_case name and ONE camelCase args object (`{}` when there are none).
//   They resolve with JSON. A command that can fail rejects with a plain-language message string the interface may
//   show as is (Tauri does this when the Rust command returns `Err(String)`).
// - Events are named `ambient:<kebab-name>` and carry the typed payload below. Unless a line says otherwise, Rust
//   broadcasts every event to every window (`app.emit`), because any window may need any fact.
// - All payload fields are camelCase (serde `rename_all = "camelCase"`). Rust `Option` is `null`, never missing.
// - Ids are UUID strings. Dates are ISO-8601 strings in UTC.
// - Every window loads its initial state by calling `get_*` commands when it mounts and only then listens for
//   updates. Never rely on a window having received an earlier event: windows are created and reloaded at any time.
// - Window geometry is in LOGICAL pixels of the virtual desktop: a monitor's physical position and size divided by its
//   own scale factor (what `Monitor.position.toLogical(monitor.scaleFactor)` gives in `@tauri-apps/api`).
//
// Window labels (each is the same page; it picks its surface from the label, see `main.tsx`):
//   bar, settings, onboarding, tour, overlay.

// ---------------------------------------------------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------------------------------------------------

export type Uuid = string;
export type IsoDateString = string;

export type AmbientWindowLabel = 'bar' | 'settings' | 'onboarding' | 'tour' | 'overlay';

/** The two keys held to talk. Matches `ambient_platform::push_to_talk::PushToTalkShortcut` (serde camelCase). */
export type PushToTalkShortcut = 'controlAlt' | 'controlWindows' | 'controlShift';

/** The screen edge the bar lives on. */
export type DockEdge = 'bottom' | 'top' | 'left' | 'right';

/** The voice side of a turn. Working, responding, finished and failed arrive as `AgentEvent`s instead. */
export type RuntimePhase =
  | { kind: 'idle' }
  /** `audioLevel` is the live microphone level, 0 to 1. Emit it 30 to 60 times a second while listening. */
  | { kind: 'listening'; audioLevel: number }
  | { kind: 'transcribing' }
  | { kind: 'thinking' };

/** `ambient_contracts::AgentFailure`, serialised as it already is (`#[serde(tag = "kind", rename_all = "camelCase")]`). */
export type AgentFailure =
  | { kind: 'paymentRequired'; message: string; topUpUrl: string | null }
  | { kind: 'notSignedIn' }
  | { kind: 'cancelled' }
  | { kind: 'other'; message: string };

/** `ambient_contracts::AgentEvent`, verbatim, one per event, in order. Tag it the same way as `AgentFailure`. */
export type AgentEvent =
  | { kind: 'textDelta'; text: string }
  | { kind: 'toolStarted'; callId: string; toolName: string; activityLabel: string }
  | { kind: 'toolFinished'; callId: string; toolName: string; isError: boolean }
  | { kind: 'finished'; finalText: string }
  | { kind: 'failed'; failure: AgentFailure };

export type ApprovalKind = 'shellCommand' | 'backgroundAgent' | 'other';

/** A question Ambient must ask before doing something with consequences. */
export interface ApprovalRequest {
  requestId: Uuid;
  title: string;
  /** For `shellCommand` the exact command line; for `backgroundAgent` what the agent will be asked to do. */
  detail: string;
  kind: ApprovalKind;
}

export type BackgroundTaskKind = 'codexAgent' | 'claudeAgent' | 'shellCommand' | 'ambientAgent';
export type BackgroundTaskStatus = 'running' | 'succeeded' | 'failed' | 'cancelled';

/** `ambient_contracts::BackgroundTask`, serialised as it already is. */
export interface BackgroundTask {
  id: Uuid;
  kind: BackgroundTaskKind;
  title: string;
  status: BackgroundTaskStatus;
  workingDirectory: string | null;
  startedAt: IsoDateString;
  finishedAt: IsoDateString | null;
  latestActivity: string;
  result: string | null;
}

/** `ambient_contracts::MemoryItem`. */
export interface MemoryItem {
  id: Uuid;
  text: string;
  createdAt: IsoDateString;
  wasLearnedAutomatically: boolean;
}

/** `ambient_contracts::SkillSummary` (`directory` is the folder path as a string). */
export interface SkillSummary {
  name: string;
  description: string;
  isBuiltIn: boolean;
  directory: string;
}

/** `ambient_contracts::ConnectorApp`. */
export interface ConnectorApp {
  slug: string;
  name: string;
  logoUrl: string | null;
  isConnected: boolean;
}

/** Everything on Settings → General. `dockEdge` always equals the edge of the current `BarPlacement`. */
export interface GeneralSettings {
  pushToTalkShortcut: PushToTalkShortcut;
  dockEdge: DockEdge;
  speaksReplies: boolean;
  /** Short, quiet cues when Ambient listens, sends, needs an answer, finishes or fails. Played by Rust. */
  playsSoundEffects: boolean;
  sharesAnonymousUsageStats: boolean;
  runsCommandsWithoutAsking: boolean;
  launchesAtLogin: boolean;
}

/** Where the bar lives. Rust stores it as opaque JSON and hands it back unchanged. */
export interface BarPlacement {
  /** `Monitor.name` of the display (for example `\\.\DISPLAY2`). Null means the primary display. */
  displayIdentifier: string | null;
  edge: DockEdge;
  /** 0 is the start of the edge (left end of top/bottom, TOP end of left/right), 1 the end, 0.5 the centre. */
  positionAlongEdge: number;
}

/** The publik account. Usage is a fraction only: never show or send currency amounts. */
export interface AccountSummary {
  publikHandle: string | null;
  planName: string | null;
  /** 0 to 1, null while unknown. */
  usageRemainingFraction: number | null;
  usageResetsOn: IsoDateString | null;
  manageAccountUrl: string;
}

export type PermissionStatus = 'granted' | 'notYetAsked' | 'waiting' | 'deniedInSystemSettings';

/** Windows has one permission Ambient needs: the microphone (Settings → Privacy & security → Microphone). */
export interface PermissionStatuses {
  microphone: PermissionStatus;
}

export type GateButtonProminence = 'primary' | 'secondary' | 'quiet';

/** One screen of the publik sign-in gate. The publik module decides all of it; the interface only draws it. */
export interface GateScreen {
  /** Identifies the screen, so a change of words on the same screen updates in place instead of turning a page. */
  id: string;
  title: string;
  body: string;
  /** A small line under the picture, such as "Waiting for you to sign in". */
  note: string | null;
  /** Shows the breathing ember beside the note while something happens elsewhere (the browser sign-in). */
  isWaiting: boolean;
  /** Drawn left to right; at most one `primary`, conventionally last. */
  buttons: { action: string; label: string; prominence: GateButtonProminence }[];
}

export type SettingsSection = 'general' | 'connectors' | 'memory' | 'skills' | 'activity' | 'account';

/** Which page Settings should show, and on Activity which task (from the tray's Read report / Transcript). */
export interface SettingsNavigation {
  section: SettingsSection;
  taskId: Uuid | null;
}

export type PushToTalkTransition = { kind: 'pressed' } | { kind: 'released'; heldForSeconds: number };

export interface CapturePoint {
  x: number;
  y: number;
}

/** Ink for drawings. Ember is Ambient's own colour and the default. */
export type AnnotationInk = 'ember' | 'red' | 'yellow' | 'green' | 'blue' | 'purple' | 'white' | 'black';

/**
 * One shape of `draw_on_screen`, in pixels of the capture it was drawn on (top-left origin). Rust builds these from the
 * tool's arguments with the same rules as `AmbientScreenToolProvider.swift` (default arrow tails, the box's 4 px
 * outset, the radius clamp, `line` becoming a two-point open path).
 */
export type AnnotationShape =
  | { kind: 'arrow'; tail: CapturePoint; tip: CapturePoint }
  | { kind: 'circle'; center: CapturePoint; radius: number }
  | { kind: 'box'; x: number; y: number; width: number; height: number }
  | { kind: 'underline'; from: CapturePoint; to: CapturePoint }
  | { kind: 'path'; points: CapturePoint[]; isClosed: boolean }
  | { kind: 'label'; at: CapturePoint };

export interface ScreenAnnotation {
  shape: AnnotationShape;
  text: string | null;
  ink: AnnotationInk;
  isFilled: boolean;
}

/** `point_at`: x and y in capture pixels; the overlay window covers exactly the captured monitor. */
export interface OverlayPoint {
  x: number;
  y: number;
  label: string | null;
  captureWidth: number;
  captureHeight: number;
}

/** `draw_on_screen`: replaces any drawing already shown. */
export interface OverlayDrawing {
  annotations: ScreenAnnotation[];
  captureWidth: number;
  captureHeight: number;
}

/** A rectangle in logical desktop pixels. */
export interface LogicalRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** One monitor as the interface sees it, in logical desktop pixels. */
export interface DisplayInfo {
  /** `Monitor.name`; stable across restarts, used as `BarPlacement.displayIdentifier`. */
  identifier: string;
  isPrimary: boolean;
  bounds: LogicalRect;
  /** The bounds without the taskbar. */
  workArea: LogicalRect;
  scaleFactor: number;
}

// ---------------------------------------------------------------------------------------------------------------------
// Commands: the interface calls, Rust handles. `args` is the single camelCase object passed to `invoke`.
// ---------------------------------------------------------------------------------------------------------------------

type NoArgs = Record<string, never>;

export interface AmbientCommands {
  // The turn ---------------------------------------------------------------------------------------------------------
  /** Any window on mount: the runtime's current voice phase. */
  get_runtime_phase: { args: NoArgs; result: RuntimePhase };
  /** Bar typed request (also the tour's typed turns). Cancels the turn in flight and stops playback first, like a new press. Rust then emits `ambient:text-submitted`. */
  submit_text: { args: { text: string }; result: null };
  /** Bar Stop / ✕ while thinking, working or responding. Rust cancels the turn; its stream ends with `failed{cancelled}`. */
  cancel_turn: { args: NoArgs; result: null };

  // Approvals --------------------------------------------------------------------------------------------------------
  /** Bar on mount: the request waiting for an answer, if any. */
  get_pending_approval: { args: NoArgs; result: ApprovalRequest | null };
  /** Bar Allow / Deny. Rust resolves the waiting approval, then emits `ambient:approval-answered`. Unknown ids are ignored. */
  answer_approval: { args: { requestId: Uuid; isAllowed: boolean }; result: null };

  // Background tasks -------------------------------------------------------------------------------------------------
  /** Bar and Settings → Activity on mount: newest first. */
  get_background_tasks: { args: NoArgs; result: BackgroundTask[] };
  /** Tray ✕ on a running task. */
  cancel_background_task: { args: { taskId: Uuid }; result: null };
  /** Tray Dismiss on a finished task. */
  dismiss_background_task: { args: { taskId: Uuid }; result: null };
  /** Settings → Activity: everything the task printed so far. Polled every second while the task runs. */
  get_background_task_transcript: { args: { taskId: Uuid }; result: string };

  // Memory -----------------------------------------------------------------------------------------------------------
  get_memory_items: { args: NoArgs; result: MemoryItem[] };
  add_memory: { args: { text: string }; result: null };
  delete_memory: { args: { itemId: Uuid }; result: null };
  get_automatic_learning_enabled: { args: NoArgs; result: boolean };
  set_automatic_learning_enabled: { args: { isEnabled: boolean }; result: null };

  // Skills -----------------------------------------------------------------------------------------------------------
  get_skills: { args: NoArgs; result: SkillSummary[] };
  /** Rust shows the folder picker ("Choose a skill folder. It needs a SKILL.md file inside.") and installs it. Resolves `true` when installed, `false` when the picker was cancelled; rejects when the folder could not be installed. */
  install_skill_from_folder: { args: NoArgs; result: boolean };
  /** Rejects when it could not be deleted. */
  delete_skill: { args: { skillName: string }; result: null };

  // Connectors -------------------------------------------------------------------------------------------------------
  /** Apps matching `query` (popular ones when empty). Rejects when the connector service cannot be reached. Also polled by the tour every 3 s on its Connect lesson. */
  get_connector_apps: { args: { query: string }; result: ConnectorApp[] };
  /** Rust asks the connector service for the authorisation page and opens it in the default browser. Rejects on failure. */
  authorize_connector: { args: { appSlug: string }; result: null };
  /** Rejects on failure. */
  disconnect_connector: { args: { appSlug: string }; result: null };

  // Settings and placement -------------------------------------------------------------------------------------------
  get_general_settings: { args: NoArgs; result: GeneralSettings };
  /** Settings → General after every change. Rust applies it (shortcut monitor, spoken replies, approvals, login item, and a changed `dockEdge` re-docks the bar at the centre of that edge), persists it, emits `ambient:general-settings` (and `ambient:bar-placement` when the edge changed), and resolves with what actually applied (Open at login can fail). */
  set_general_settings: { args: { settings: GeneralSettings }; result: GeneralSettings };
  /** Bar on mount. Null before the first placement is saved (the bar then uses bottom, centre, primary display). */
  get_bar_placement: { args: NoArgs; result: BarPlacement | null };
  /** Bar after it is dragged to a new place. Rust persists it, sets `GeneralSettings.dockEdge`, and broadcasts `ambient:bar-placement` and `ambient:general-settings`. */
  set_bar_placement: { args: { placement: BarPlacement }; result: null };
  /** Settings → Account on mount. Null until `GET /wallet` has answered. */
  get_account_summary: { args: NoArgs; result: AccountSummary | null };
  /** Settings on mount: the page it was last asked to show. */
  get_settings_navigation: { args: NoArgs; result: SettingsNavigation };

  // Permissions and onboarding ---------------------------------------------------------------------------------------
  get_permission_statuses: { args: NoArgs; result: PermissionStatuses };
  /** Permissions step Allow / Open settings, and the tour's fix button. Rust asks for the microphone when it has never been asked, otherwise opens `ms-settings:privacy-microphone`; then re-checks and emits `ambient:permission-statuses`. */
  request_microphone_permission: { args: NoArgs; result: null };
  /** Opens `ms-settings:privacy-microphone`. */
  open_microphone_settings: { args: NoArgs; result: null };
  /** Permissions step Continue / Not now. Rust closes the onboarding window and starts the tour if onboarding was never completed. */
  finish_permissions_step: { args: NoArgs; result: null };
  get_onboarding_completed: { args: NoArgs; result: boolean };
  /** The tour sets this when it finishes or is ended. */
  set_onboarding_completed: { args: { isCompleted: boolean }; result: null };
  /** Onboarding on mount: the sign-in gate screen, or null when the gate is not showing (the window then shows the permissions step). */
  get_gate_screen: { args: NoArgs; result: GateScreen | null };
  /** A gate button was pressed. Rust hands `action` to the publik sign-in module. */
  answer_gate: { args: { action: string }; result: null };

  // App -------------------------------------------------------------------------------------------------------------
  /** Opens (creating if needed) and focuses the Settings window on `section` (default: the last one). With `taskId`, Activity selects that task. Rust emits `ambient:settings-navigate`. */
  open_settings: { args: { section: SettingsSection | null; taskId: Uuid | null }; result: null };
  /** Opens a web link in the default browser. Only http(s) URLs. */
  open_url: { args: { url: string }; result: null };
  check_for_updates: { args: NoArgs; result: null };
  quit: { args: NoArgs; result: null };
  show_bar: { args: NoArgs; result: null };
  hide_bar: { args: NoArgs; result: null };
  /** Creates the `tour` window (replacing a running tour). */
  start_tour: { args: NoArgs; result: null };
  /** Closes the `tour` window. */
  end_tour: { args: NoArgs; result: null };
  /** Removes the drawing from the overlay (emits `ambient:overlay-clear`). */
  clear_drawing: { args: NoArgs; result: null };
  /** Rust shows the Save dialog (in Documents, with `suggestedName`) and writes `text` as UTF-8. Resolves `true` when saved, `false` when cancelled; rejects when the write failed. */
  save_text_file: { args: { suggestedName: string; text: string }; result: boolean };

  // Windows ---------------------------------------------------------------------------------------------------------
  /** Moves AND resizes the calling window in one step (one `SetWindowPos`), in logical desktop pixels. Used by `bar` and `tour`, which size themselves to their content. Two separate move/resize calls would show a frame of the bar in the wrong place. */
  set_window_frame: { args: { frame: LogicalRect }; result: null };
  /** The bar's text box opened (true) or closed (false). True: let the bar window take focus and focus it. False: make it non-activating again and give focus back to the window that had it before. */
  set_bar_accepts_keyboard: { args: { acceptsKeyboard: boolean }; result: null };
  /** Overlay on mount: the drawing currently shown, if any (a pointer is never replayed). */
  get_overlay_drawing: { args: NoArgs; result: OverlayDrawing | null };
  /** Overlay: whether anything (pointer or drawing) is on screen. Rust may hide the overlay window while false. */
  overlay_content_changed: { args: { hasContent: boolean }; result: null };
}

// ---------------------------------------------------------------------------------------------------------------------
// Events: Rust emits, windows listen. Every event is broadcast to all windows unless a line says otherwise.
// ---------------------------------------------------------------------------------------------------------------------

export interface AmbientEvents {
  /** Whenever the runtime's voice phase changes, and every level update while listening. Emit `idle` only when the runtime returns to idle (cancelled, or nothing was heard); never after a turn finishes, which ends with an agent event instead. */
  'ambient:runtime-phase': RuntimePhase;
  /** Every `AgentEvent` of the bar's conversation, verbatim and in order. */
  'ambient:agent-event': AgentEvent;
  /** After `submit_text` was accepted (the tour tells typed turns from spoken ones). */
  'ambient:text-submitted': { text: string };
  /** An approval is waiting. Rust shows the bar first. A new request replaces (denies) the previous one. */
  'ambient:approval-requested': ApprovalRequest;
  /** The waiting approval was withdrawn (the turn was cancelled); the bar drops its card. */
  'ambient:approval-cancelled': { requestId: Uuid };
  /** After `answer_approval` resolved a request (the tour reacts to Allow / Deny made in the bar). */
  'ambient:approval-answered': { requestId: Uuid; kind: ApprovalKind; isAllowed: boolean };
  /** The whole task list, newest first, on every change (`BackgroundTaskStore::updates`). */
  'ambient:background-tasks': BackgroundTask[];
  /** The whole memory list on every change (`MemoryStore::updates`). */
  'ambient:memory-items': MemoryItem[];
  /** The whole skill list on every change (`SkillStore::updates`). */
  'ambient:skills': SkillSummary[];
  /** After general settings changed, from any window or from Rust. */
  'ambient:general-settings': GeneralSettings;
  /** After the placement changed (dragged in the bar, or re-docked from Settings), and again, unchanged, whenever monitors are added, removed or rearranged or the taskbar moves, so the bar re-reads the displays and re-docks. The bar applies it; the tour moves its card away from it. */
  'ambient:bar-placement': BarPlacement;
  /** The push-to-talk keys went down or came up. `heldForSeconds` is measured by Rust from the press. Emit `pressed` BEFORE cancelling the turn in flight, so the tour reads the cancelled turn's events as part of the new hold. */
  'ambient:push-to-talk': PushToTalkTransition;
  /** Permission statuses, whenever a check finds a change (Rust re-checks every 1.5 s and after each request). */
  'ambient:permission-statuses': PermissionStatuses;
  /** The gate screen to show, or null to stop showing the gate. Rust creates the onboarding window before emitting a screen. */
  'ambient:gate-screen': GateScreen | null;
  /** The account summary, whenever `GET /wallet` answers. */
  'ambient:account-summary': AccountSummary | null;
  /** Settings should show this page (sent with `open_settings`). */
  'ambient:settings-navigate': SettingsNavigation;
  /** Point at something. Sent to the `overlay` window only, AFTER Rust has moved it to cover the captured monitor exactly and shown it. */
  'ambient:overlay-point': OverlayPoint;
  /** Draw. Sent to the `overlay` window only, after it covers the captured monitor. Replaces the previous drawing. */
  'ambient:overlay-draw': OverlayDrawing;
  /** Remove the drawing (Clear Drawing in the tray menu, or the `clear_drawing` tool). Sent to the `overlay` window only. */
  'ambient:overlay-clear': null;
}

// ---------------------------------------------------------------------------------------------------------------------
// The host interface the interface code is written against. `tauri.ts` implements it for real, `mock.ts` in a browser.
// ---------------------------------------------------------------------------------------------------------------------

export type AmbientCommandName = keyof AmbientCommands;
export type AmbientEventName = keyof AmbientEvents;
export type StopListening = () => void;

/** Questions about the calling window itself. The real host answers them with `@tauri-apps/api/window`. */
export interface OwnWindowHost {
  readonly label: AmbientWindowLabel;
  /** Every monitor, in logical desktop pixels. */
  listDisplays(): Promise<DisplayInfo[]>;
  /** The pointer, in logical desktop pixels. */
  cursorPosition(): Promise<{ x: number; y: number }>;
  /** This window's current outer frame, in logical desktop pixels (after the person may have dragged it). */
  currentFrame(): Promise<LogicalRect>;
  /** Hands an ongoing left-button press to the system so it moves the window (the tour card is dragged by its body). */
  startDragging(): Promise<void>;
}

export interface AmbientHost {
  invoke<CommandName extends AmbientCommandName>(
    commandName: CommandName,
    args: AmbientCommands[CommandName]['args'],
  ): Promise<AmbientCommands[CommandName]['result']>;
  listen<EventName extends AmbientEventName>(
    eventName: EventName,
    handler: (payload: AmbientEvents[EventName]) => void,
  ): Promise<StopListening>;
  readonly ownWindow: OwnWindowHost;
}
