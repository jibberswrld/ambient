import type {
  AgentEvent,
  AmbientCommandName,
  AmbientCommands,
  AmbientEventName,
  AmbientEvents,
  AmbientHost,
  AmbientWindowLabel,
  ApprovalRequest,
  BackgroundTask,
  BarPlacement,
  DisplayInfo,
  GateScreen,
  GeneralSettings,
  LogicalRect,
  PermissionStatuses,
  SettingsNavigation,
} from './contract';
import {
  sampleAccountSummary,
  sampleBackgroundTasks,
  sampleConnectorApps,
  sampleDrawing,
  sampleGateScreens,
  sampleLongReply,
  sampleMediumReply,
  sampleMemoryItems,
  sampleSkills,
  sampleTaskTranscript,
} from './mockData';

// A scripted fake backend so every window runs in a plain browser. It keeps the same state Rust would, answers every
// command in the contract, and plays believable turns: type anything into the bar, or hold Ctrl+Alt in the page to
// "talk". Words in a request steer the script: "agent" asks to start an agent, "command" asks to run a command,
// "draw" draws on the overlay, "fail" runs out of allowance, "long" gives a long answer.
//
// In the browser, `#root` stands in for the OS window: `set_window_frame` moves and resizes it over the page, which
// plays the desktop, so the bar's own sizing and docking logic runs exactly as it does in the app.

type Handler = (payload: never) => void;

const fakeTaskbarHeight = 48;

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export function createMockHost(windowLabel: AmbientWindowLabel): AmbientHost {
  const handlersByEvent = new Map<AmbientEventName, Set<Handler>>();
  // The bar starts with two tasks so its resting dots read clearly; Settings shows all four, including a finished report.
  let backgroundTasks: BackgroundTask[] = windowLabel === 'bar' ? sampleBackgroundTasks().slice(0, 2) : sampleBackgroundTasks();
  let memoryItems = sampleMemoryItems();
  let skills = sampleSkills();
  let connectorApps = sampleConnectorApps();
  let automaticLearningEnabled = true;
  let generalSettings: GeneralSettings = {
    pushToTalkShortcut: 'controlAlt',
    dockEdge: 'bottom',
    speaksReplies: true,
    sharesAnonymousUsageStats: true,
    runsCommandsWithoutAsking: false,
    launchesAtLogin: true,
  };
  let barPlacement: BarPlacement | null = null;
  let permissionStatuses: PermissionStatuses = { microphone: 'notYetAsked' };
  let onboardingCompleted = false;
  let gateScreen: GateScreen | null = windowLabel === 'onboarding' && new URLSearchParams(location.search).get('step') !== 'permissions' ? sampleGateScreens.signIn : null;
  let pendingApproval: ApprovalRequest | null = null;
  let settingsNavigation: SettingsNavigation = { section: 'general', taskId: null };
  let currentTurnNumber = 0;

  function emit<EventName extends AmbientEventName>(eventName: EventName, payload: AmbientEvents[EventName]): void {
    const handlers = handlersByEvent.get(eventName);
    if (!handlers) return;
    queueMicrotask(() => {
      for (const handler of handlers) (handler as (payload: AmbientEvents[EventName]) => void)(payload);
    });
  }

  function emitAgentEvent(event: AgentEvent): void {
    emit('ambient:agent-event', event);
  }

  function setBackgroundTasks(tasks: BackgroundTask[]): void {
    backgroundTasks = tasks;
    emit('ambient:background-tasks', backgroundTasks);
  }

  /** Streams `text` the way a model does: uneven bursts of a few words. */
  async function streamReply(text: string, turnNumber: number): Promise<boolean> {
    const words = text.split(/(\s+)/);
    for (let wordIndex = 0; wordIndex < words.length; wordIndex += 6) {
      if (turnNumber !== currentTurnNumber) return false;
      emitAgentEvent({ kind: 'textDelta', text: words.slice(wordIndex, wordIndex + 6).join('') });
      await sleep(70 + Math.random() * 90);
    }
    return turnNumber === currentTurnNumber;
  }

  async function playTurn(requestText: string): Promise<void> {
    currentTurnNumber += 1;
    const turnNumber = currentTurnNumber;
    const loweredRequest = requestText.toLowerCase();
    emit('ambient:runtime-phase', { kind: 'thinking' });
    await sleep(700);
    if (turnNumber !== currentTurnNumber) return;

    if (loweredRequest.includes('fail')) {
      emitAgentEvent({
        kind: 'failed',
        failure: { kind: 'paymentRequired', message: "You have used this month's allowance.", topUpUrl: 'https://publikhq.com/wallet' },
      });
      return;
    }
    if (loweredRequest.includes('agent') || loweredRequest.includes('command')) {
      const isAgent = loweredRequest.includes('agent');
      emitAgentEvent({ kind: 'toolStarted', callId: 'spawn', toolName: isAgent ? 'spawn_agent' : 'run_command', activityLabel: isAgent ? 'Starting an agent' : 'Running a command' });
      pendingApproval = {
        requestId: crypto.randomUUID(),
        title: isAgent ? 'Start agent?' : 'Run this command?',
        detail: isAgent ? requestText.replace(/^start an agent to /i, '') : 'git push origin feature/settings-refactor',
        kind: isAgent ? 'backgroundAgent' : 'shellCommand',
      };
      emit('ambient:approval-requested', pendingApproval);
      return;
    }
    if (loweredRequest.includes('draw') || loweredRequest.includes('show me')) {
      emitAgentEvent({ kind: 'toolStarted', callId: 'look', toolName: 'look_at_screen', activityLabel: 'Looking at your screen' });
      await sleep(900);
      emitAgentEvent({ kind: 'toolFinished', callId: 'look', toolName: 'look_at_screen', isError: false });
      emitAgentEvent({ kind: 'toolStarted', callId: 'draw', toolName: 'draw_on_screen', activityLabel: 'Drawing on your screen' });
      emit('ambient:overlay-draw', sampleDrawing());
      await sleep(500);
      emitAgentEvent({ kind: 'toolFinished', callId: 'draw', toolName: 'draw_on_screen', isError: false });
      if (await streamReply('Click Share first, then pick the person. I marked both.', turnNumber)) {
        emitAgentEvent({ kind: 'finished', finalText: 'Click Share first, then pick the person. I marked both.' });
      }
      return;
    }

    emitAgentEvent({ kind: 'toolStarted', callId: 'gmail', toolName: 'gmail_search_threads', activityLabel: 'Searching Gmail' });
    await sleep(1100);
    if (turnNumber !== currentTurnNumber) return;
    emitAgentEvent({ kind: 'toolFinished', callId: 'gmail', toolName: 'gmail_search_threads', isError: false });
    emitAgentEvent({ kind: 'toolStarted', callId: 'calendar', toolName: 'calendar_list_events', activityLabel: 'Checking your calendar' });
    await sleep(900);
    if (turnNumber !== currentTurnNumber) return;
    emitAgentEvent({ kind: 'toolFinished', callId: 'calendar', toolName: 'calendar_list_events', isError: false });
    const replyText = loweredRequest.includes('long') ? sampleLongReply : sampleMediumReply;
    if (await streamReply(replyText, turnNumber)) emitAgentEvent({ kind: 'finished', finalText: replyText });
  }

  async function startMockAgent(title: string): Promise<void> {
    const taskId = crypto.randomUUID();
    const newTask: BackgroundTask = {
      id: taskId,
      kind: 'ambientAgent',
      title,
      status: 'running',
      workingDirectory: null,
      startedAt: new Date().toISOString(),
      finishedAt: null,
      latestActivity: 'Searching the web',
      result: null,
    };
    setBackgroundTasks([newTask, ...backgroundTasks]);
    await sleep(9000);
    setBackgroundTasks(
      backgroundTasks.map((backgroundTask) =>
        backgroundTask.id === taskId
          ? { ...backgroundTask, status: 'succeeded', finishedAt: new Date().toISOString(), result: 'Found three places worth trying. **Lucali** is the pick for a sit-down dinner.' }
          : backgroundTask,
      ),
    );
  }

  /** Hold Ctrl+Alt in the page to talk: the mock plays a voice turn with a synthetic microphone level. */
  function installPushToTalkSimulation(): void {
    let pressedAt: number | null = null;
    let levelTimer: ReturnType<typeof setInterval> | null = null;
    window.addEventListener('keydown', (event) => {
      if (!(event.ctrlKey && event.altKey) || pressedAt !== null) return;
      pressedAt = performance.now();
      currentTurnNumber += 1;
      emit('ambient:push-to-talk', { kind: 'pressed' });
      levelTimer = setInterval(() => {
        const syllable = Math.max(0, Math.sin(performance.now() / 140)) * 0.7 + Math.random() * 0.25;
        emit('ambient:runtime-phase', { kind: 'listening', audioLevel: syllable });
      }, 33);
    });
    window.addEventListener('keyup', () => {
      if (pressedAt === null) return;
      const heldForSeconds = (performance.now() - pressedAt) / 1000;
      pressedAt = null;
      if (levelTimer) clearInterval(levelTimer);
      emit('ambient:push-to-talk', { kind: 'released', heldForSeconds });
      emit('ambient:runtime-phase', { kind: 'transcribing' });
      setTimeout(() => {
        void playTurn('What can you help me with?');
      }, 600);
    });
  }

  function applyMockWindowFrame(frame: LogicalRect): void {
    const rootElement = document.getElementById('root');
    if (!rootElement) return;
    rootElement.style.position = 'fixed';
    rootElement.style.left = `${frame.x}px`;
    rootElement.style.top = `${frame.y}px`;
    rootElement.style.width = `${frame.width}px`;
    rootElement.style.height = `${frame.height}px`;
  }

  const commandHandlers: { [CommandName in AmbientCommandName]: (args: AmbientCommands[CommandName]['args']) => Promise<AmbientCommands[CommandName]['result']> | AmbientCommands[CommandName]['result'] } = {
    get_runtime_phase: () => ({ kind: 'idle' }),
    submit_text: ({ text }) => {
      emit('ambient:text-submitted', { text });
      void playTurn(text);
      return null;
    },
    cancel_turn: () => {
      currentTurnNumber += 1;
      if (pendingApproval) {
        emit('ambient:approval-cancelled', { requestId: pendingApproval.requestId });
        pendingApproval = null;
      }
      emitAgentEvent({ kind: 'failed', failure: { kind: 'cancelled' } });
      return null;
    },
    get_pending_approval: () => pendingApproval,
    answer_approval: ({ requestId, isAllowed }) => {
      if (!pendingApproval || pendingApproval.requestId !== requestId) return null;
      const answeredRequest = pendingApproval;
      pendingApproval = null;
      emit('ambient:approval-answered', { requestId, kind: answeredRequest.kind, isAllowed });
      const turnNumber = currentTurnNumber;
      void (async () => {
        const toolName = answeredRequest.kind === 'backgroundAgent' ? 'spawn_agent' : 'run_command';
        emitAgentEvent({ kind: 'toolFinished', callId: 'spawn', toolName, isError: !isAllowed });
        if (isAllowed && answeredRequest.kind === 'backgroundAgent') void startMockAgent(answeredRequest.detail);
        const replyText = isAllowed
          ? answeredRequest.kind === 'backgroundAgent'
            ? 'Started. I will tell you when it is done.'
            : 'Pushed. The branch is up to date.'
          : 'Okay, I left it.';
        if (await streamReply(replyText, turnNumber)) emitAgentEvent({ kind: 'finished', finalText: replyText });
      })();
      return null;
    },
    get_background_tasks: () => backgroundTasks,
    cancel_background_task: ({ taskId }) => {
      setBackgroundTasks(
        backgroundTasks.map((backgroundTask) =>
          backgroundTask.id === taskId ? { ...backgroundTask, status: 'cancelled', finishedAt: new Date().toISOString() } : backgroundTask,
        ),
      );
      return null;
    },
    dismiss_background_task: ({ taskId }) => {
      setBackgroundTasks(backgroundTasks.filter((backgroundTask) => backgroundTask.id !== taskId));
      return null;
    },
    get_background_task_transcript: () => sampleTaskTranscript,
    get_memory_items: () => memoryItems,
    add_memory: ({ text }) => {
      memoryItems = [{ id: crypto.randomUUID(), text, createdAt: new Date().toISOString(), wasLearnedAutomatically: false }, ...memoryItems];
      emit('ambient:memory-items', memoryItems);
      return null;
    },
    delete_memory: ({ itemId }) => {
      memoryItems = memoryItems.filter((memoryItem) => memoryItem.id !== itemId);
      emit('ambient:memory-items', memoryItems);
      return null;
    },
    get_automatic_learning_enabled: () => automaticLearningEnabled,
    set_automatic_learning_enabled: ({ isEnabled }) => {
      automaticLearningEnabled = isEnabled;
      return null;
    },
    get_skills: () => skills,
    install_skill_from_folder: async () => {
      await sleep(300);
      skills = [{ name: 'release-notes', description: 'Turns merged pull requests into release notes.', isBuiltIn: false, directory: 'C:\\skills\\release-notes' }, ...skills];
      emit('ambient:skills', skills);
      return true;
    },
    delete_skill: ({ skillName }) => {
      skills = skills.filter((skill) => skill.name !== skillName);
      emit('ambient:skills', skills);
      return null;
    },
    get_connector_apps: async ({ query }) => {
      await sleep(350);
      const loweredQuery = query.trim().toLowerCase();
      return connectorApps.filter((app) => app.name.toLowerCase().includes(loweredQuery));
    },
    authorize_connector: async ({ appSlug }) => {
      await sleep(200);
      // The mock "finishes in the browser" a few seconds later.
      setTimeout(() => {
        connectorApps = connectorApps.map((app) => (app.slug === appSlug ? { ...app, isConnected: true } : app));
      }, 4000);
      return null;
    },
    disconnect_connector: async ({ appSlug }) => {
      await sleep(400);
      connectorApps = connectorApps.map((app) => (app.slug === appSlug ? { ...app, isConnected: false } : app));
      return null;
    },
    get_general_settings: () => generalSettings,
    set_general_settings: ({ settings }) => {
      const edgeChanged = settings.dockEdge !== generalSettings.dockEdge;
      generalSettings = settings;
      emit('ambient:general-settings', generalSettings);
      if (edgeChanged) {
        barPlacement = { displayIdentifier: barPlacement?.displayIdentifier ?? null, edge: settings.dockEdge, positionAlongEdge: 0.5 };
        emit('ambient:bar-placement', barPlacement);
      }
      return generalSettings;
    },
    get_bar_placement: () => barPlacement,
    set_bar_placement: ({ placement }) => {
      barPlacement = placement;
      generalSettings = { ...generalSettings, dockEdge: placement.edge };
      emit('ambient:bar-placement', placement);
      emit('ambient:general-settings', generalSettings);
      return null;
    },
    get_account_summary: () => sampleAccountSummary(),
    get_settings_navigation: () => settingsNavigation,
    get_permission_statuses: () => permissionStatuses,
    request_microphone_permission: async () => {
      permissionStatuses = { microphone: 'waiting' };
      emit('ambient:permission-statuses', permissionStatuses);
      await sleep(1200);
      permissionStatuses = { microphone: 'granted' };
      emit('ambient:permission-statuses', permissionStatuses);
      return null;
    },
    open_microphone_settings: () => null,
    finish_permissions_step: () => null,
    get_onboarding_completed: () => onboardingCompleted,
    set_onboarding_completed: ({ isCompleted }) => {
      onboardingCompleted = isCompleted;
      return null;
    },
    get_gate_screen: () => gateScreen,
    answer_gate: ({ action }) => {
      if (action === 'sign-in' || action === 'open-again') gateScreen = sampleGateScreens.waiting;
      else if (action === 'cancel') gateScreen = sampleGateScreens.signIn;
      emit('ambient:gate-screen', gateScreen);
      if (gateScreen?.isWaiting) {
        setTimeout(() => {
          gateScreen = null;
          emit('ambient:gate-screen', null);
        }, 3000);
      }
      return null;
    },
    open_settings: ({ section, taskId }) => {
      settingsNavigation = { section: section ?? settingsNavigation.section, taskId };
      emit('ambient:settings-navigate', settingsNavigation);
      return null;
    },
    open_url: ({ url }) => {
      window.open(url, '_blank', 'noopener');
      return null;
    },
    check_for_updates: () => null,
    quit: () => null,
    show_bar: () => null,
    hide_bar: () => null,
    start_tour: () => null,
    end_tour: () => null,
    clear_drawing: () => {
      emit('ambient:overlay-clear', null);
      return null;
    },
    save_text_file: () => true,
    set_window_frame: ({ frame }) => {
      applyMockWindowFrame(frame);
      return null;
    },
    set_bar_accepts_keyboard: () => null,
    get_overlay_drawing: () => (windowLabel === 'overlay' ? sampleDrawing() : null),
    overlay_content_changed: () => null,
  };

  if (windowLabel === 'bar') installPushToTalkSimulation();

  const viewportDisplay = (): DisplayInfo => ({
    identifier: '\\\\.\\DISPLAY1',
    isPrimary: true,
    bounds: { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight },
    workArea: { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight - fakeTaskbarHeight },
    scaleFactor: window.devicePixelRatio || 1,
  });

  let lastPointerPosition = { x: 0, y: 0 };
  window.addEventListener('pointermove', (event) => (lastPointerPosition = { x: event.clientX, y: event.clientY }), { capture: true });

  return {
    invoke: async (commandName, args) => {
      const handler = commandHandlers[commandName] as (args: unknown) => unknown;
      return (await handler(args)) as never;
    },
    listen: async (eventName, handler) => {
      const handlers = handlersByEvent.get(eventName) ?? new Set<Handler>();
      handlers.add(handler as Handler);
      handlersByEvent.set(eventName, handlers);
      return () => handlers.delete(handler as Handler);
    },
    ownWindow: {
      label: windowLabel,
      listDisplays: async () => [viewportDisplay()],
      cursorPosition: async () => lastPointerPosition,
      currentFrame: async () => {
        const rootRect = document.getElementById('root')?.getBoundingClientRect();
        return rootRect ? { x: rootRect.left, y: rootRect.top, width: rootRect.width, height: rootRect.height } : { x: 0, y: 0, width: 0, height: 0 };
      },
      startDragging: async () => undefined,
    },
  };
}
