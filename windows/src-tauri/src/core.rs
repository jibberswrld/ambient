//! The composition root and the one agent pipeline, ported from `Ambient/AmbientRuntime.swift`,
//! `Ambient/AmbientInteraction.swift` and the wiring in `Ambient/AmbientApp.swift`.
//!
//! `Shell` is what the windows see (events, approvals, the sign-in gate, the overlay). `Runtime` owns the services and
//! runs turns. The pipeline is: hold the shortcut → 16 kHz WAV → publik transcription → `AmbientAgentSession` with
//! tools → memory learning and optional spoken reply.
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ambient_agent::{publik, AmbientAgentSession, PublikAiClient, PublikCredentialSource, PublikSpeechClient, PublikWebSearchProvider, AMBIENT_BACKGROUND_AGENT_PROMPT, DEFAULT_VOICE};
use ambient_background::{AgentWorkspaceToolProvider, Approval, BackgroundApprovalSettings, BackgroundTaskManager, BackgroundToolProvider, InProcessAgent};
use ambient_connectors::{AmbientConnectorClient, ComposioToolProvider};
use ambient_contracts::{AgentEvent, AgentFailure, AgentSession, AiCredentialSource, MemoryStore, SkillStore, TextCompletionService, ToolProvider, UserTurn};
use ambient_memory::{FileSkillStore, MemoryToolProvider, PersistentMemoryStore, SkillToolProvider};
use ambient_platform::dictation::{microphone_access_status, DictationRecorder, MicrophoneAccess};
use ambient_platform::playback::{AudioPlayback, PlayingClip};
use ambient_platform::push_to_talk::{PushToTalkMonitor, ShortcutTransition};
use ambient_platform::screen_capture::CapturedDisplay;
use serde::Serialize;
use serde_json::{json, Value};
use tauri::async_runtime::JoinHandle;
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

use crate::screen_tools::{ScreenOverlay, ScreenToolProvider, ScreenTools};
use crate::settings::SettingsStore;
use crate::{log_line, windows};

/// The conversation's state. Only the first four are sent to the windows as `ambient:runtime-phase`; the rest reach
/// them as agent events, and are kept here so a change back to `Thinking` is noticed.
#[derive(Debug, Clone, PartialEq)]
pub enum Phase {
    Idle,
    Listening { audio_level: f64 },
    Transcribing,
    Thinking,
    Working,
    Responding,
    Finished,
    Failed,
}

impl Phase {
    pub fn payload(&self) -> Option<Value> {
        match self {
            Phase::Idle => Some(json!({ "kind": "idle" })),
            Phase::Listening { audio_level } => Some(json!({ "kind": "listening", "audioLevel": audio_level })),
            Phase::Transcribing => Some(json!({ "kind": "transcribing" })),
            Phase::Thinking => Some(json!({ "kind": "thinking" })),
            _ => None,
        }
    }
}

pub fn agent_event_payload(event: &AgentEvent) -> Value {
    match event {
        AgentEvent::TextDelta(text) => json!({ "kind": "textDelta", "text": text }),
        AgentEvent::ToolStarted { call_id, tool_name, activity_label } => json!({ "kind": "toolStarted", "callId": call_id, "toolName": tool_name, "activityLabel": activity_label }),
        AgentEvent::ToolFinished { call_id, tool_name, is_error } => json!({ "kind": "toolFinished", "callId": call_id, "toolName": tool_name, "isError": is_error }),
        AgentEvent::Finished { final_text } => json!({ "kind": "finished", "finalText": final_text }),
        AgentEvent::Failed(failure) => json!({ "kind": "failed", "failure": failure }),
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalRequest {
    pub request_id: Uuid,
    pub title: String,
    pub detail: String,
    pub kind: &'static str,
}

struct PendingApproval {
    request: ApprovalRequest,
    answer: oneshot::Sender<bool>,
}

/// Everything the windows can observe or answer.
pub struct Shell {
    pub app: AppHandle,
    phase: Mutex<Phase>,
    pending_approval: Mutex<Option<PendingApproval>>,
    pub gate_screen: Mutex<Option<Value>>,
    pub gate_answers: Mutex<Option<std::sync::mpsc::Sender<String>>>,
    pub overlay_drawing: Mutex<Option<Value>>,
    pub account_summary: Mutex<Option<Value>>,
    pub settings_navigation: Mutex<Value>,
    pub microphone_access: Mutex<Option<MicrophoneAccess>>,
    /// False while the person has hidden the bar from the tray.
    pub bar_should_be_visible: AtomicBool,
    /// The bar's page has put the window where it belongs; before that, showing it would flash it in the wrong place.
    pub bar_has_been_placed: AtomicBool,
}

impl Shell {
    pub fn new(app: AppHandle) -> Arc<Self> {
        Arc::new(Self {
            app,
            phase: Mutex::new(Phase::Idle),
            pending_approval: Mutex::new(None),
            gate_screen: Mutex::new(None),
            gate_answers: Mutex::new(None),
            overlay_drawing: Mutex::new(None),
            account_summary: Mutex::new(None),
            settings_navigation: Mutex::new(json!({ "section": "general", "taskId": null })),
            microphone_access: Mutex::new(None),
            bar_should_be_visible: AtomicBool::new(false),
            bar_has_been_placed: AtomicBool::new(false),
        })
    }

    pub fn emit(&self, event_name: &str, payload: impl Serialize + Clone) {
        if let Err(error) = self.app.emit(event_name, payload) {
            log_line(&format!("could not emit {event_name}: {error}"));
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase.lock().unwrap().clone()
    }

    /// Records the phase and tells the windows when it is one of theirs. Repeats are not sent, except live levels.
    pub fn set_phase(&self, phase: Phase) {
        {
            let mut current = self.phase.lock().unwrap();
            if *current == phase {
                return;
            }
            *current = phase.clone();
        }
        // Debug text stays on this computer; credentials and tool payloads are never logged.
        if !matches!(phase, Phase::Listening { .. }) {
            log_line(&format!("state: {phase:?}"));
        }
        if let Some(payload) = phase.payload() {
            self.emit("ambient:runtime-phase", payload);
        }
    }

    pub fn emit_agent_event(&self, event: &AgentEvent) {
        self.emit("ambient:agent-event", agent_event_payload(event));
    }

    pub fn show_bar(&self) {
        self.bar_should_be_visible.store(true, Ordering::SeqCst);
        if self.bar_has_been_placed.load(Ordering::SeqCst) {
            if let Some(bar) = self.app.get_webview_window("bar") {
                let _ = bar.show();
            }
        }
        windows::bar_visibility_changed(&self.app, true);
    }

    pub fn hide_bar(&self) {
        self.bar_should_be_visible.store(false, Ordering::SeqCst);
        if let Some(bar) = self.app.get_webview_window("bar") {
            let _ = bar.hide();
        }
        windows::bar_visibility_changed(&self.app, false);
    }

    pub fn pending_approval(&self) -> Option<ApprovalRequest> {
        self.pending_approval.lock().unwrap().as_ref().map(|pending| pending.request.clone())
    }

    /// Asks the person in the bar and waits. A new question replaces (denies) the one before it; with no answer
    /// (the turn was cancelled, the app is quitting) the answer is no.
    pub async fn approve(&self, title: String, detail: String) -> bool {
        self.show_bar();
        let kind = match title.as_str() {
            "Run shell command?" => "shellCommand",
            "Start Codex agent?" | "Start Claude agent?" | "Start agent?" | "Continue agent?" => "backgroundAgent",
            _ => "other",
        };
        let request = ApprovalRequest { request_id: Uuid::new_v4(), title, detail, kind };
        let (answer, answered) = oneshot::channel();
        *self.pending_approval.lock().unwrap() = Some(PendingApproval { request: request.clone(), answer });
        log_line(&format!("approval presented: {}", request.title));
        self.emit("ambient:approval-requested", request);
        let is_allowed = answered.await.unwrap_or(false);
        log_line(&format!("approval answered: {is_allowed}"));
        is_allowed
    }

    pub fn answer_approval(&self, request_id: Uuid, is_allowed: bool) {
        let pending = {
            let mut slot = self.pending_approval.lock().unwrap();
            if slot.as_ref().is_some_and(|pending| pending.request.request_id == request_id) { slot.take() } else { None }
        };
        if let Some(pending) = pending {
            let _ = pending.answer.send(is_allowed);
            self.emit("ambient:approval-answered", json!({ "requestId": request_id, "kind": pending.request.kind, "isAllowed": is_allowed }));
        }
    }

    pub fn cancel_approval(&self) {
        if let Some(pending) = self.pending_approval.lock().unwrap().take() {
            // Dropping the sender answers no.
            self.emit("ambient:approval-cancelled", json!({ "requestId": pending.request.request_id }));
        }
    }

    pub fn open_in_browser(&self, url: &str) {
        use tauri_plugin_opener::OpenerExt;
        if let Err(error) = self.app.opener().open_url(url, None::<&str>) {
            log_line(&format!("could not open a link: {error}"));
        }
    }

    pub fn permission_statuses(&self) -> Value {
        // A computer with no microphone has nothing to grant; recording explains itself when it is tried.
        let status = match *self.microphone_access.lock().unwrap() {
            Some(MicrophoneAccess::Granted) | Some(MicrophoneAccess::NoDevice) => "granted",
            Some(MicrophoneAccess::Denied) => "deniedInSystemSettings",
            None => "notYetAsked",
        };
        json!({ "microphone": status })
    }

    pub fn is_microphone_usable(&self) -> bool {
        !matches!(*self.microphone_access.lock().unwrap(), Some(MicrophoneAccess::Denied))
    }

    /// Opens the microphone briefly to learn whether Windows lets desktop apps use it, and tells the windows.
    pub async fn refresh_microphone_access(&self) {
        let access = tauri::async_runtime::spawn_blocking(microphone_access_status).await.ok();
        let changed = {
            let mut current = self.microphone_access.lock().unwrap();
            let changed = *current != access;
            *current = access;
            changed
        };
        if changed {
            self.emit("ambient:permission-statuses", self.permission_statuses());
        }
    }

    fn show_overlay_on(&self, display: &CapturedDisplay) -> bool {
        let Some(overlay) = self.app.get_webview_window("overlay") else { return false };
        // One pixel short of the display, so Windows does not treat the overlay as a full-screen app and hide the taskbar.
        let moved = overlay.set_position(tauri::PhysicalPosition::new(display.display_x, display.display_y)).is_ok()
            && overlay.set_size(tauri::PhysicalSize::new(display.display_pixel_width, display.display_pixel_height.saturating_sub(1))).is_ok();
        moved && overlay.show().is_ok()
    }
}

impl ScreenOverlay for Shell {
    fn point(&self, display: &CapturedDisplay, x: f64, y: f64, label: &str) -> bool {
        if !self.show_overlay_on(display) {
            return false;
        }
        let payload = json!({ "x": x, "y": y, "label": label, "captureWidth": display.image_pixel_width, "captureHeight": display.image_pixel_height });
        self.app.emit_to("overlay", "ambient:overlay-point", payload).is_ok()
    }

    fn draw(&self, display: &CapturedDisplay, annotations: Value) -> bool {
        if !self.show_overlay_on(display) {
            return false;
        }
        let drawing = json!({ "annotations": annotations, "captureWidth": display.image_pixel_width, "captureHeight": display.image_pixel_height });
        *self.overlay_drawing.lock().unwrap() = Some(drawing.clone());
        self.app.emit_to("overlay", "ambient:overlay-draw", drawing).is_ok()
    }

    fn clear_drawing(&self) -> bool {
        let had_drawing = self.overlay_drawing.lock().unwrap().take().is_some();
        let _ = self.app.emit_to("overlay", "ambient:overlay-clear", Value::Null);
        had_drawing
    }
}

/// Draws the publik sign-in gate in the onboarding window. `show` runs on the sign-in module's own blocking thread.
pub struct WindowGate {
    pub shell: Arc<Shell>,
}

impl publik::GateUi for WindowGate {
    fn show(&mut self, screen: &publik::Screen, done: Arc<AtomicBool>) -> Option<&'static str> {
        let buttons: Vec<Value> = screen.buttons.iter().enumerate()
            .map(|(index, (action, label))| json!({ "action": action, "label": label, "prominence": if index == 0 { "primary" } else { "secondary" } }))
            .collect();
        let payload = json!({ "id": screen.id, "title": screen.title, "body": screen.body, "note": screen.note, "isWaiting": screen.note.is_some(), "buttons": buttons });
        let (answers, pressed) = std::sync::mpsc::channel();
        *self.shell.gate_screen.lock().unwrap() = Some(payload.clone());
        *self.shell.gate_answers.lock().unwrap() = Some(answers);
        windows::show_onboarding(&self.shell.app);
        self.shell.emit("ambient:gate-screen", payload);
        loop {
            if done.load(Ordering::SeqCst) {
                return None;
            }
            if let Ok(action) = pressed.recv_timeout(Duration::from_millis(100)) {
                if let Some((known_action, _)) = screen.buttons.iter().find(|(known_action, _)| *known_action == action) {
                    return Some(known_action);
                }
            }
        }
    }

    fn open_url(&mut self, url: &str) {
        self.shell.open_in_browser(url);
    }
}

pub struct Runtime {
    pub shell: Arc<Shell>,
    pub settings: SettingsStore,
    pub credential_source: Arc<dyn AiCredentialSource>,
    pub background_tasks: Arc<BackgroundTaskManager>,
    pub memory: Arc<dyn MemoryStore>,
    pub skills: Arc<dyn SkillStore>,
    pub connectors: Arc<AmbientConnectorClient>,
    pub approval_settings: Arc<BackgroundApprovalSettings>,
    session: Arc<AmbientAgentSession>,
    speech: Arc<PublikSpeechClient>,
    screen_tools: Arc<ScreenToolProvider>,
    /// Raised by every cancellation; work that began under an older number must stop touching the bar.
    turn_generation: AtomicU64,
    turn_task: Mutex<Option<JoinHandle<()>>>,
    cancellation_task: Mutex<Option<JoinHandle<()>>>,
    playing_clip: Mutex<Option<PlayingClip>>,
    is_ready: AtomicBool,
    pending_text: Mutex<Option<String>>,
    recorder: Mutex<DictationRecorder>,
    shortcut_monitor: Mutex<Option<PushToTalkMonitor>>,
    shortcut_pressed_at: Mutex<Option<Instant>>,
}

struct SpokenReply {
    sentences: mpsc::UnboundedSender<String>,
    playback: JoinHandle<()>,
}

impl Runtime {
    pub fn new(shell: Arc<Shell>) -> Result<Arc<Self>, String> {
        let settings = SettingsStore::load()?;
        let credential_source: Arc<dyn AiCredentialSource> = Arc::new(PublikCredentialSource::new(None));
        let completion_service: Arc<dyn TextCompletionService> = Arc::new(PublikAiClient::new(credential_source.clone()));
        let memory: Arc<dyn MemoryStore> = Arc::new(PersistentMemoryStore::new(completion_service)?);
        let skills: Arc<dyn SkillStore> = Arc::new(FileSkillStore::new()?);
        let background_tasks = Arc::new(BackgroundTaskManager::new(None, None)?);
        let connectors = Arc::new(AmbientConnectorClient::new(credential_source.clone()));
        let approval_settings = Arc::new(BackgroundApprovalSettings::new(None)?);
        let speech = Arc::new(PublikSpeechClient::new(credential_source.clone()));
        let web_search: Arc<dyn ToolProvider> = Arc::new(PublikWebSearchProvider::new(credential_source.clone()));
        let authorizing_shell = shell.clone();
        let connector_tools: Arc<dyn ToolProvider> = Arc::new(ComposioToolProvider::new(connectors.clone(), move |url: String| {
            let shell = authorizing_shell.clone();
            async move { shell.open_in_browser(&url) }
        }));
        let memory_tools: Arc<dyn ToolProvider> = Arc::new(MemoryToolProvider::new(memory.clone()));
        let skill_tools: Arc<dyn ToolProvider> = Arc::new(SkillToolProvider::new(skills.clone()));
        let screen_tools = ScreenToolProvider::new(shell.clone());

        // A background agent is a second conversation on the person's publik account: the same tools minus the
        // screen and spawning, plus a shell confined to its working directory, and more reasoning than the bar.
        let agent_providers = (credential_source.clone(), web_search.clone(), connector_tools.clone(), memory_tools.clone(), skill_tools.clone());
        let ambient_agent: InProcessAgent = Arc::new(move |prompt: String, working_directory: PathBuf, report_activity| {
            let (credential_source, web_search, connector_tools, memory_tools, skill_tools) = agent_providers.clone();
            Box::pin(async move {
                let workspace: Arc<dyn ToolProvider> = Arc::new(AgentWorkspaceToolProvider::new(working_directory));
                let session = AmbientAgentSession::new(credential_source, vec![workspace, web_search, connector_tools, memory_tools, skill_tools],
                    Some(AMBIENT_BACKGROUND_AGENT_PROMPT.to_string()), "high");
                let mut events = session.send(UserTurn::text(prompt));
                while let Some(event) = events.recv().await {
                    match event {
                        AgentEvent::ToolStarted { activity_label, .. } => report_activity(activity_label),
                        AgentEvent::Finished { final_text } => return Ok(final_text),
                        AgentEvent::Failed(failure) => return Err(failure),
                        AgentEvent::TextDelta(_) | AgentEvent::ToolFinished { .. } => {}
                    }
                }
                Err(AgentFailure::Cancelled)
            })
        });
        let approving_shell = shell.clone();
        let approve: Approval = Arc::new(move |title: String, detail: String| {
            let shell = approving_shell.clone();
            Box::pin(async move { shell.approve(title, detail).await })
        });
        let background_tools: Arc<dyn ToolProvider> = Arc::new(BackgroundToolProvider::new(background_tasks.clone(), approval_settings.clone(), Some(ambient_agent), approve));
        // The bar answers and acts with as little deliberation as the model allows; agents do the thinking.
        let session = Arc::new(AmbientAgentSession::new(credential_source.clone(),
            vec![web_search, background_tools, connector_tools, memory_tools, skill_tools, Arc::new(ScreenTools(screen_tools.clone()))], None, "low"));

        Ok(Arc::new(Self {
            shell, settings, credential_source, background_tasks, memory, skills, connectors, approval_settings, session, speech, screen_tools,
            turn_generation: AtomicU64::new(0),
            turn_task: Mutex::new(None),
            cancellation_task: Mutex::new(None),
            playing_clip: Mutex::new(None),
            is_ready: AtomicBool::new(false),
            pending_text: Mutex::new(None),
            recorder: Mutex::new(DictationRecorder::new()),
            shortcut_monitor: Mutex::new(None),
            shortcut_pressed_at: Mutex::new(None),
        }))
    }

    pub fn is_ready(&self) -> bool {
        self.is_ready.load(Ordering::SeqCst)
    }

    /// Called once sign-in has succeeded: turns may run, and a request that arrived early is sent.
    pub fn became_ready(self: &Arc<Self>) {
        self.is_ready.store(true, Ordering::SeqCst);
        log_line("sign-in ready");
        if let Some(text) = self.pending_text.lock().unwrap().take() {
            self.submit_text(text);
        }
    }

    fn is_current(&self, generation: u64) -> bool {
        self.turn_generation.load(Ordering::SeqCst) == generation
    }

    pub fn speaks_replies(&self) -> bool {
        self.settings.read().speaks_replies
    }

    pub fn stop_playback(&self) {
        if let Some(mut clip) = self.playing_clip.lock().unwrap().take() {
            clip.stop();
        }
    }

    pub fn report_failure(&self, failure: AgentFailure) {
        self.shell.set_phase(Phase::Failed);
        self.shell.emit_agent_event(&AgentEvent::Failed(failure));
    }

    pub fn cancel_current_turn(self: &Arc<Self>) {
        self.turn_generation.fetch_add(1, Ordering::SeqCst);
        if let Some(turn_task) = self.turn_task.lock().unwrap().take() {
            log_line("turn cancelled; playback stopped");
            turn_task.abort();
        }
        self.stop_playback();
        // Cancellation is ordered before the next send, rather than racing the new turn.
        let prior_cancellation = self.cancellation_task.lock().unwrap().take();
        let session = self.session.clone();
        *self.cancellation_task.lock().unwrap() = Some(tauri::async_runtime::spawn(async move {
            if let Some(prior_cancellation) = prior_cancellation {
                let _ = prior_cancellation.await;
            }
            session.cancel().await;
        }));
        self.shell.cancel_approval();
        self.screen_tools.clear_captures();
        self.shell.set_phase(Phase::Idle);
    }

    /// Stops recording and the turn: the bar's Stop, a new press, and quitting all come here.
    pub fn cancel_turn(self: &Arc<Self>) {
        self.recorder.lock().unwrap().cancel();
        self.cancel_current_turn();
    }

    pub fn submit_text(self: &Arc<Self>, text: String) {
        if text.trim().is_empty() {
            return;
        }
        self.recorder.lock().unwrap().cancel();
        if !self.is_ready() {
            *self.pending_text.lock().unwrap() = Some(text);
            return;
        }
        self.shell.emit("ambient:text-submitted", json!({ "text": text }));
        self.start_turn(Some(text), None);
    }

    pub fn submit_recording(self: &Arc<Self>, wav_data: Vec<u8>) {
        self.start_turn(None, Some(wav_data));
    }

    fn start_turn(self: &Arc<Self>, typed_text: Option<String>, recorded_wav: Option<Vec<u8>>) {
        self.cancel_current_turn();
        if !self.is_ready() {
            self.report_failure(AgentFailure::NotSignedIn);
            return;
        }
        let generation = self.turn_generation.load(Ordering::SeqCst);
        self.shell.set_phase(if typed_text.is_some() { Phase::Thinking } else { Phase::Transcribing });
        let runtime = self.clone();
        let turn_task = tauri::async_runtime::spawn(async move {
            let prior_cancellation = runtime.cancellation_task.lock().unwrap().take();
            if let Some(prior_cancellation) = prior_cancellation {
                let _ = prior_cancellation.await;
            }
            if !runtime.is_current(generation) {
                return;
            }
            let heard_text = match (typed_text, recorded_wav) {
                (Some(text), _) => text,
                (None, Some(wav_data)) => {
                    let started = Instant::now();
                    match runtime.speech.transcribe(wav_data).await {
                        Ok(text) => {
                            log_line(&format!("transcribed with publik in {:.2} s", started.elapsed().as_secs_f64()));
                            text
                        }
                        Err(failure) => {
                            if runtime.is_current(generation) {
                                runtime.report_failure(failure);
                            }
                            return;
                        }
                    }
                }
                (None, None) => return,
            };
            if !runtime.is_current(generation) {
                return;
            }
            let user_text = heard_text.trim().to_string();
            if user_text.is_empty() {
                runtime.shell.set_phase(Phase::Idle);
                return;
            }
            log_line(&format!("heard: {user_text}"));
            runtime.shell.set_phase(Phase::Thinking);
            runtime.run_conversation(generation, user_text).await;
        });
        *self.turn_task.lock().unwrap() = Some(turn_task);
    }

    async fn run_conversation(self: &Arc<Self>, generation: u64, user_text: String) {
        // Everything the person reads goes through here, so the bar and the state never disagree.
        let revealing_runtime = self.clone();
        let reveal: Arc<dyn Fn(&str) + Send + Sync> = Arc::new(move |fragment: &str| {
            if fragment.is_empty() || !revealing_runtime.is_current(generation) {
                return;
            }
            revealing_runtime.shell.set_phase(Phase::Responding);
            revealing_runtime.shell.emit_agent_event(&AgentEvent::TextDelta(fragment.to_string()));
        });
        // With spoken replies on, each sentence is written as it is said, not ahead of the voice.
        let mut spoken_reply = self.speaks_replies().then(|| self.start_speaking(generation, reveal.clone()));
        let mut unspoken_text = String::new();
        let mut activities: Vec<(String, String)> = Vec::new();
        let mut events = self.session.send(UserTurn::text(user_text.clone()));
        while let Some(event) = events.recv().await {
            if !self.is_current(generation) {
                return;
            }
            match &event {
                AgentEvent::TextDelta(fragment) => match &spoken_reply {
                    None => reveal(fragment),
                    Some(spoken_reply) => {
                        unspoken_text.push_str(fragment);
                        while let Some(sentence) = take_sentence(&mut unspoken_text) {
                            let _ = spoken_reply.sentences.send(sentence);
                        }
                    }
                },
                AgentEvent::ToolStarted { call_id, tool_name, activity_label } => {
                    self.shell.emit_agent_event(&event);
                    activities.push((call_id.clone(), activity_label.clone()));
                    log_line(&format!("tool started: {tool_name}"));
                    self.shell.set_phase(Phase::Working);
                }
                AgentEvent::ToolFinished { call_id, tool_name, is_error } => {
                    self.shell.emit_agent_event(&event);
                    activities.retain(|(active_call_id, _)| active_call_id != call_id);
                    log_line(&format!("tool finished: {tool_name} error={is_error}"));
                    if activities.is_empty() {
                        self.shell.set_phase(Phase::Thinking);
                    }
                }
                AgentEvent::Finished { final_text } => {
                    if let Some(spoken_reply) = spoken_reply.take() {
                        let _ = spoken_reply.sentences.send(std::mem::take(&mut unspoken_text));
                        drop(spoken_reply.sentences);
                        // The turn is finished once the last sentence has been said and written.
                        let _ = spoken_reply.playback.await;
                        if !self.is_current(generation) {
                            return;
                        }
                    }
                    self.shell.set_phase(Phase::Finished);
                    self.shell.emit_agent_event(&event);
                    // Learning is a separate model call; it must not delay the reply or its speech.
                    let (memory, user_text, final_text) = (self.memory.clone(), user_text.clone(), final_text.clone());
                    tauri::async_runtime::spawn(async move { memory.learn(&user_text, &final_text).await });
                }
                AgentEvent::Failed(failure) => self.report_failure(failure.clone()),
            }
        }
    }

    /// Synthesis of each sentence starts as soon as it arrives; playback keeps them in order and writes each
    /// sentence word by word while it is being said. A sentence that cannot be spoken is still written.
    fn start_speaking(self: &Arc<Self>, generation: u64, reveal: Arc<dyn Fn(&str) + Send + Sync>) -> SpokenReply {
        let (sentences, mut incoming_sentences) = mpsc::unbounded_channel::<String>();
        let (clips, mut incoming_clips) = mpsc::unbounded_channel::<(String, Option<JoinHandle<Result<Vec<u8>, AgentFailure>>>)>();
        let voice = self.settings.read().spoken_voice.unwrap_or_else(|| DEFAULT_VOICE.to_string());
        let speech = self.speech.clone();
        tauri::async_runtime::spawn(async move {
            while let Some(sentence) = incoming_sentences.recv().await {
                if sentence.trim().is_empty() {
                    // Blank lines carry the reply's layout and have nothing to say.
                    let _ = clips.send((sentence, None));
                    continue;
                }
                // publik limits one speech call to 4096 characters.
                let characters: Vec<char> = sentence.chars().collect();
                for chunk in characters.chunks(4096) {
                    let chunk: String = chunk.iter().collect();
                    let (speech, voice, text) = (speech.clone(), voice.clone(), chunk.clone());
                    let synthesis = tauri::async_runtime::spawn(async move { speech.synthesize(&text, &voice).await });
                    let _ = clips.send((chunk, Some(synthesis)));
                }
            }
        });
        let runtime = self.clone();
        let playback = tauri::async_runtime::spawn(async move {
            while let Some((text, synthesis)) = incoming_clips.recv().await {
                if !runtime.is_current(generation) {
                    return;
                }
                let Some(synthesis) = synthesis.filter(|_| runtime.speaks_replies()) else {
                    reveal(&text);
                    continue;
                };
                let started_clip = match synthesis.await {
                    Ok(Ok(audio)) => tauri::async_runtime::spawn_blocking(move || AudioPlayback::play(audio)).await.unwrap_or_else(|error| Err(error.to_string())),
                    Ok(Err(failure)) => Err(failure.to_string()),
                    Err(error) => Err(error.to_string()),
                };
                if !runtime.is_current(generation) {
                    return;
                }
                match started_clip {
                    Ok(clip) => *runtime.playing_clip.lock().unwrap() = Some(clip),
                    Err(message) => {
                        log_line(&format!("speech failed for one sentence: {message}"));
                        reveal(&text);
                        continue;
                    }
                }
                log_line("speech playback started");
                let words = words_keeping_spacing(&text);
                let mut revealed_word_count = 0;
                loop {
                    let progress = runtime.playing_clip.lock().unwrap().as_ref().filter(|clip| clip.is_playing()).map(|clip| (clip.position_seconds(), clip.duration_seconds()));
                    let Some((position_seconds, duration_seconds)) = progress else { break };
                    // Writing runs slightly ahead of the voice so the last word is on screen before it is said.
                    let spoken_fraction = ((position_seconds + 0.25) / (duration_seconds * 0.9).max(0.1)).min(1.0);
                    let word_count_due = ((words.len() as f64 * spoken_fraction).ceil() as usize).min(words.len());
                    if word_count_due > revealed_word_count {
                        reveal(&words[revealed_word_count..word_count_due].concat());
                        revealed_word_count = word_count_due;
                    }
                    tokio::time::sleep(Duration::from_millis(30)).await;
                    if !runtime.is_current(generation) {
                        return;
                    }
                    if !runtime.speaks_replies() {
                        runtime.stop_playback();
                    }
                }
                reveal(&words[revealed_word_count..].concat());
            }
        });
        SpokenReply { sentences, playback }
    }

    // ---------- Push to talk ----------

    pub fn start_shortcut_monitor(self: &Arc<Self>) {
        let runtime = self.clone();
        let shortcut = self.settings.read().push_to_talk_shortcut;
        // The callback runs on the keyboard hook's thread, which must return at once or Windows drops the hook.
        let monitor = PushToTalkMonitor::start(shortcut, move |transition| {
            let runtime = runtime.clone();
            tauri::async_runtime::spawn(async move { runtime.handle_shortcut(transition).await });
        });
        match monitor {
            Ok(monitor) => *self.shortcut_monitor.lock().unwrap() = Some(monitor),
            Err(message) => {
                log_line(&format!("the push-to-talk shortcut could not start: {message}"));
                self.report_failure(AgentFailure::Other { message: "The hold-to-talk shortcut could not start. Restart Ambient to try again.".into() });
            }
        }
    }

    pub fn set_shortcut(&self, shortcut: ambient_platform::push_to_talk::PushToTalkShortcut) {
        if let Some(monitor) = self.shortcut_monitor.lock().unwrap().as_mut() {
            monitor.set_shortcut(shortcut);
        }
    }

    pub async fn handle_shortcut(self: &Arc<Self>, transition: ShortcutTransition) {
        match transition {
            ShortcutTransition::Pressed => {
                *self.shortcut_pressed_at.lock().unwrap() = Some(Instant::now());
                // Before the turn is cancelled, so the tour treats the cancelled turn's idle as part of a new hold.
                self.shell.emit("ambient:push-to-talk", json!({ "kind": "pressed" }));
                self.cancel_turn();
                if !self.is_ready() {
                    self.report_failure(AgentFailure::Other { message: "Finish signing in with publik before recording.".into() });
                    return;
                }
                self.shell.show_bar();
                self.shell.set_phase(Phase::Listening { audio_level: 0.0 });
                let level_runtime = self.clone();
                let last_level_sent_at = Mutex::new(Instant::now());
                let recording_runtime = self.clone();
                let started = tauri::async_runtime::spawn_blocking(move || {
                    recording_runtime.recorder.lock().unwrap().start(move |audio_level| {
                        // The microphone reports far more often than the bar can draw.
                        let mut last_sent_at = last_level_sent_at.lock().unwrap();
                        if last_sent_at.elapsed() < Duration::from_millis(25) || !matches!(level_runtime.shell.phase(), Phase::Listening { .. }) {
                            return;
                        }
                        *last_sent_at = Instant::now();
                        level_runtime.shell.set_phase(Phase::Listening { audio_level: f64::from(audio_level.clamp(0.0, 1.0)) });
                    })
                })
                .await
                .unwrap_or_else(|error| Err(error.to_string()));
                if let Err(message) = started {
                    self.report_failure(AgentFailure::Other { message });
                    self.shell.refresh_microphone_access().await;
                }
            }
            ShortcutTransition::Released => {
                let held_for_seconds = self.shortcut_pressed_at.lock().unwrap().take().map(|pressed_at| pressed_at.elapsed().as_secs_f64()).unwrap_or(0.0);
                self.shell.emit("ambient:push-to-talk", json!({ "kind": "released", "heldForSeconds": held_for_seconds }));
                let recording_runtime = self.clone();
                let recording = tauri::async_runtime::spawn_blocking(move || recording_runtime.recorder.lock().unwrap().finish()).await.ok().flatten();
                match recording {
                    Some(wav_data) => self.submit_recording(wav_data),
                    None => {
                        if matches!(self.shell.phase(), Phase::Listening { .. }) {
                            self.cancel_current_turn();
                        }
                    }
                }
            }
        }
    }

    // ---------- Account ----------

    /// `GET /wallet` as the Settings → Account page needs it: a handle, a plan label and a share remaining. Never money.
    pub async fn refresh_account_summary(self: &Arc<Self>) {
        let Some(credential) = self.credential_source.credential().await else { return };
        let api_key = credential.api_key.clone();
        let wallet = tauri::async_runtime::spawn_blocking(move || publik::read_wallet(&api_key)).await;
        match wallet {
            Ok(Ok((200, Some(wallet), _))) => {
                let summary = account_summary_from_wallet(&wallet);
                *self.shell.account_summary.lock().unwrap() = Some(summary.clone());
                self.shell.emit("ambient:account-summary", summary);
            }
            _ => self.report_failure(AgentFailure::Other { message: "Your publik account could not be loaded. Try opening Settings again.".into() }),
        }
    }

    pub fn stop(self: &Arc<Self>) {
        self.cancel_turn();
        if let Some(mut monitor) = self.shortcut_monitor.lock().unwrap().take() {
            monitor.stop();
        }
    }
}

pub fn account_summary_from_wallet(wallet: &Value) -> Value {
    let percentage = wallet["remaining_percent"].as_f64().or_else(|| wallet["prepaid_remaining_percent"].as_f64());
    json!({
        "publikHandle": wallet["account"]["handle"].as_str(),
        "planName": wallet["plan"]["label"].as_str(),
        "usageRemainingFraction": percentage.map(|percentage| (percentage / 100.0).clamp(0.0, 1.0)),
        "usageResetsOn": wallet["resets_at"].as_str(),
        "manageAccountUrl": wallet["top_up_url"].as_str().unwrap_or("https://publikhq.com/wallet"),
    })
}

/// The first complete sentence of `text`, removed from it, with the space or line break that ended it so the
/// written reply keeps its spacing. A sentence ends at ". ", "! ", "? " or a line break.
pub fn take_sentence(text: &mut String) -> Option<String> {
    let mut previous: Option<char> = None;
    for (byte_index, character) in text.char_indices() {
        let ends_sentence = character == '\n' || character == '\r' || (character == ' ' && previous.is_some_and(|previous| ".!?".contains(previous)));
        if ends_sentence {
            let rest = text.split_off(byte_index + character.len_utf8());
            return Some(std::mem::replace(text, rest));
        }
        previous = Some(character);
    }
    None
}

/// Splits text after each run of whitespace, so joining the pieces gives the text back unchanged.
pub fn words_keeping_spacing(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    for character in text.chars() {
        if !character.is_whitespace() && current.chars().last().is_some_and(char::is_whitespace) {
            words.push(std::mem::take(&mut current));
        }
        current.push(character);
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

/// `ambient://ask?text=...`: the permanent automation hook, routed through the same agent path and approvals.
pub fn automation_text(link: &str) -> Option<String> {
    let url = url::Url::parse(link).ok()?;
    if !url.scheme().eq_ignore_ascii_case("ambient") || url.host_str() != Some("ask") {
        return None;
    }
    let text = url.query_pairs().find(|(name, _)| name == "text")?.1.into_owned();
    (!text.trim().is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentences_are_taken_with_the_spacing_that_ended_them() {
        let mut text = "One. Two!\nThree".to_string();
        assert_eq!(take_sentence(&mut text).as_deref(), Some("One. "));
        assert_eq!(take_sentence(&mut text).as_deref(), Some("Two!\n"));
        assert_eq!(take_sentence(&mut text), None);
        assert_eq!(text, "Three");
        let mut decimal = "Version 1.5 is out".to_string();
        assert_eq!(take_sentence(&mut decimal), None);
    }

    #[test]
    fn words_join_back_into_the_same_text() {
        let text = "Hello  there,\nworld ";
        let words = words_keeping_spacing(text);
        assert_eq!(words, vec!["Hello  ", "there,\n", "world "]);
        assert_eq!(words.concat(), text);
    }

    #[test]
    fn automation_links_are_decoded_and_others_refused() {
        assert_eq!(automation_text("ambient://ask?text=what%20time%20is%20it").as_deref(), Some("what time is it"));
        assert_eq!(automation_text("AMBIENT://ask?text=hi").as_deref(), Some("hi"));
        assert_eq!(automation_text("ambient://ask?text=%20"), None);
        assert_eq!(automation_text("ambient://other?text=hi"), None);
        assert_eq!(automation_text("https://ask?text=hi"), None);
    }

    #[test]
    fn the_account_summary_shows_a_share_and_never_money() {
        let summary = account_summary_from_wallet(&json!({ "account": { "handle": "jabir" }, "plan": { "label": "Plus" }, "remaining_percent": 64.0, "balance_micros": 12345 }));
        assert_eq!(summary["publikHandle"], "jabir");
        assert_eq!(summary["usageRemainingFraction"], 0.64);
        assert_eq!(summary["manageAccountUrl"], "https://publikhq.com/wallet");
        assert!(summary.get("balanceMicros").is_none());
    }
}
