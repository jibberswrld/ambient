//! Anonymous usage events: counts, durations, enums and Ambient's own tool names only. No account, request, reply,
//! screen, drawing text, window, URL, path or error-message data enters an event.
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ambient_contracts::{AgentFailure, BackgroundTask};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(Clone, Copy, Serialize, Deserialize, Eq, PartialEq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Step {
    SigninShown,
    SignedIn,
    PermissionsShown,
    MicGranted,
    TourStarted,
    TourFinished,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Input {
    Voice,
    Text,
}

/// How a submitted request ended.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Finished,
    Failed,
    Cancelled,
    PaymentRequired,
    NotSignedIn,
    /// Transcription produced no words.
    Empty,
}

impl Outcome {
    pub fn of(failure: &AgentFailure) -> Self {
        match failure {
            AgentFailure::PaymentRequired { .. } => Outcome::PaymentRequired,
            AgentFailure::NotSignedIn => Outcome::NotSignedIn,
            AgentFailure::Cancelled => Outcome::Cancelled,
            AgentFailure::Other { .. } => Outcome::Failed,
        }
    }
}

/// A failure's kind, never its message.
pub fn failure_kind(failure: &AgentFailure) -> &'static str {
    match failure {
        AgentFailure::PaymentRequired { .. } => "payment_required",
        AgentFailure::NotSignedIn => "not_signed_in",
        AgentFailure::Cancelled => "cancelled",
        AgentFailure::Other { .. } => "other",
    }
}

/// One submitted request, measured while it runs.
pub struct Command {
    input: Input,
    started: Instant,
    /// The model finished; a later cancellation (say, of the spoken reply) does not change that.
    pub finished: bool,
    pub transcribe_ms: Option<u128>,
    pub sent_at: Option<Instant>,
    pub first_reply_ms: Option<u128>,
    pub tool_calls: u32,
    pub tool_errors: u32,
    pub tools: BTreeSet<String>,
    pub spoken_replies: Option<bool>,
    pub request_chars: Option<usize>,
    pub reply_chars: usize,
}

impl Command {
    pub fn new(input: Input) -> Self {
        Self { input, started: Instant::now(), finished: false, transcribe_ms: None, sent_at: None, first_reply_ms: None,
            tool_calls: 0, tool_errors: 0, tools: BTreeSet::new(), spoken_replies: None, request_chars: None, reply_chars: 0 }
    }

    /// Text became visible to the person.
    pub fn revealed(&mut self, characters: usize) {
        if let (None, Some(sent_at)) = (self.first_reply_ms, self.sent_at) {
            self.first_reply_ms = Some(sent_at.elapsed().as_millis());
        }
        self.reply_chars += characters;
    }

    fn properties(&self, outcome: Outcome) -> Value {
        let outcome = if self.finished { Outcome::Finished } else { outcome };
        let mut properties = json!({
            "input": self.input, "ok": outcome == Outcome::Finished, "outcome": outcome,
            "total_ms": self.started.elapsed().as_millis(), "tool_calls": self.tool_calls, "tool_errors": self.tool_errors,
            "tools": self.tools, "reply_chars": self.reply_chars,
        });
        // Windows always transcribes with publik.
        if matches!(self.input, Input::Voice) { properties["transcriber"] = json!("publik"); }
        if let Some(value) = self.transcribe_ms { properties["transcribe_ms"] = json!(value); }
        if let Some(value) = self.first_reply_ms { properties["first_reply_ms"] = json!(value); }
        if let Some(value) = self.spoken_replies { properties["spoken_replies"] = json!(value); }
        if let Some(value) = self.request_chars { properties["request_chars"] = json!(value); }
        properties
    }
}

/// A drawing as counts of each requested mark type (as on the Mac) and how many carry a caption, never the caption.
pub fn drawing_properties(annotations: &[Value], display_index: usize, display_count: usize, replaced_previous: bool) -> Value {
    const KNOWN_KINDS: [&str; 7] = ["arrow", "circle", "box", "line", "path", "underline", "label"];
    let mut kinds = BTreeMap::<&str, u32>::new();
    for annotation in annotations {
        let kind = annotation["type"].as_str().filter(|kind| KNOWN_KINDS.contains(kind)).unwrap_or("other");
        *kinds.entry(kind).or_default() += 1;
    }
    let labeled_marks = annotations.iter().filter(|annotation| annotation["text"].as_str().is_some_and(|text| !text.is_empty())).count();
    json!({ "marks": annotations.len(), "kinds": kinds, "labeled_marks": labeled_marks,
        "display_index": display_index, "display_count": display_count, "replaced_previous": replaced_previous })
}

/// The tour's lessons, named as the tour names them.
#[derive(Clone, Copy, Serialize, Deserialize)]
/// The tour window sends camelCase ids; events use snake_case, like the Mac.
#[serde(rename_all(serialize = "snake_case", deserialize = "camelCase"))]
pub enum TourLesson {
    Talk,
    ShowScreen,
    HandOff,
    ConnectApps,
    PlaceBar,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LessonResult {
    Completed,
    Skipped,
}

#[derive(Serialize, Deserialize)]
struct Install {
    distinct_id: Uuid,
    enabled: bool,
    first_launch: bool,
    first_command: bool,
    steps: HashSet<Step>,
}

#[derive(Clone)]
pub struct Analytics {
    path: PathBuf,
    install: Arc<Mutex<Option<Install>>>,
    client: Option<reqwest::Client>,
    /// One per launch, never stored.
    session_id: Uuid,
    launched_at: Instant,
    commands: Arc<AtomicU64>,
}

fn sending_allowed() -> bool {
    std::env::var("AMBIENT_ANALYTICS_DEV").as_deref() == Ok("1")
        || (!cfg!(debug_assertions) && !cfg!(test))
}

impl Analytics {
    pub fn new() -> Self {
        Self::in_directory(ambient_contracts::ambient_data_directory())
    }

    fn in_directory(directory: PathBuf) -> Self {
        let path = directory.join("analytics.json");
        let install = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).ok(),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let install = Install {
                    distinct_id: Uuid::new_v4(),
                    enabled: true,
                    first_launch: false,
                    first_command: false,
                    steps: HashSet::new(),
                };
                std::fs::create_dir_all(&directory)
                    .ok()
                    .and_then(|_| Self::save(&path, &install).ok())
                    .map(|_| install)
            }
            // Never reset an opt-out or replace an unreadable identity.
            Err(_) => None,
        };
        Self {
            path,
            install: Arc::new(Mutex::new(install)),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .ok(),
            session_id: Uuid::new_v4(),
            launched_at: Instant::now(),
            commands: Arc::new(AtomicU64::new(0)),
        }
    }

    fn save(path: &std::path::Path, install: &Install) -> std::io::Result<()> {
        let temporary_path = path.with_extension("json.tmp");
        std::fs::write(&temporary_path, serde_json::to_vec(install)?)?;
        std::fs::rename(temporary_path, path)
    }

    pub fn is_enabled(&self) -> bool {
        self.install
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|install| install.enabled)
    }

    pub fn set_enabled(&self, enabled: bool) {
        if let Some(install) = self.install.lock().unwrap().as_mut() {
            install.enabled = enabled;
            if Self::save(&self.path, install).is_err() {
                install.enabled = false;
            }
        }
    }

    pub fn launched(&self) {
        if self.mark_once(|install| !std::mem::replace(&mut install.first_launch, true)) {
            self.capture("ambient_first_launch", json!({}));
        }
        self.capture("ambient_app_opened", json!({}));
    }

    pub fn reached(&self, step: Step) {
        if self.mark_once(|install| install.steps.insert(step)) {
            self.capture("ambient_onboarding_step", json!({ "step": step }));
        }
    }

    pub fn command_submitted(&self) {
        if self.mark_once(|install| !std::mem::replace(&mut install.first_command, true)) {
            self.capture("ambient_first_command", json!({}));
        }
    }

    pub fn command_completed(&self, command: &Command, outcome: Outcome) {
        self.commands.fetch_add(1, Ordering::SeqCst);
        self.capture("ambient_command", command.properties(outcome));
    }

    pub fn tool_finished(&self, tool: &str, ok: bool, duration: Duration) {
        self.capture("ambient_tool", json!({ "tool": tool, "ok": ok, "duration_ms": duration.as_millis() }));
    }

    pub fn drew(&self, properties: Value) {
        self.capture("ambient_drawing", properties);
    }

    /// `via` is "menu" or "tool".
    pub fn drawing_cleared(&self, via: &'static str) {
        self.capture("ambient_drawing_cleared", json!({ "via": via }));
    }

    pub fn pointed(&self, display_index: usize) {
        self.capture("ambient_point", json!({ "display_index": display_index }));
    }

    pub fn looked_at_screen(&self, displays: usize, duration: Duration, ok: bool) {
        self.capture("ambient_screen_look", json!({ "displays": displays, "duration_ms": duration.as_millis(), "ok": ok }));
    }

    /// `decision` is "allowed", "denied" or "cancelled".
    pub fn approval(&self, kind: &'static str, decision: &'static str, wait: Duration) {
        self.capture("ambient_approval", json!({ "kind": kind, "decision": decision, "wait_ms": wait.as_millis() }));
    }

    pub fn background_task_finished(&self, task: &BackgroundTask) {
        let duration_ms = task.finished_at.map(|finished_at| (finished_at - task.started_at).num_milliseconds().max(0));
        self.capture("ambient_background_task", json!({ "kind": task.kind, "status": task.status, "duration_ms": duration_ms }));
    }

    /// `outcome` is "recorded" or "too_short" (the hold produced no audio).
    pub fn shortcut_released(&self, hold: Duration, outcome: &'static str) {
        self.capture("ambient_shortcut", json!({ "hold_ms": hold.as_millis(), "outcome": outcome }));
    }

    pub fn error(&self, stage: &'static str, kind: &'static str) {
        self.capture("ambient_error", json!({ "stage": stage, "kind": kind }));
    }

    /// Only booleans and enums; free-text settings are never sent.
    pub fn setting_changed(&self, setting: &'static str, value: Value) {
        self.capture("ambient_setting_changed", json!({ "setting": setting, "value": value }));
    }

    /// `toolkit` is the connector's app slug, such as "gmail".
    pub fn connector(&self, connected: bool, toolkit: &str) {
        let event = if connected { "ambient_connector_connected" } else { "ambient_connector_disconnected" };
        self.capture(event, json!({ "toolkit": toolkit }));
    }

    pub fn tour_lesson(&self, lesson: TourLesson, result: LessonResult) {
        self.capture("ambient_tour_lesson", json!({ "lesson": lesson, "result": result }));
    }

    pub fn bar_moved(&self, edge: &str) {
        if ["top", "bottom", "left", "right"].contains(&edge) {
            self.capture("ambient_bar_moved", json!({ "edge": edge }));
        }
    }

    /// Called while quitting: waits at most a second for the event to leave.
    pub fn session_ended(&self) {
        let properties = json!({ "duration_s": self.launched_at.elapsed().as_secs(), "commands": self.commands.load(Ordering::SeqCst) });
        if let Some(request) = self.request("ambient_session_ended", properties) {
            tauri::async_runtime::block_on(async { let _ = tokio::time::timeout(Duration::from_secs(1), request).await; });
        }
    }

    fn mark_once(&self, change: impl FnOnce(&mut Install) -> bool) -> bool {
        if !sending_allowed() {
            return false;
        }
        let mut state = self.install.lock().unwrap();
        let Some(install) = state.as_mut().filter(|install| install.enabled) else {
            return false;
        };
        change(install) && Self::save(&self.path, install).is_ok()
    }

    fn capture(&self, event: &'static str, properties: Value) {
        if let Some(request) = self.request(event, properties) {
            tauri::async_runtime::spawn(request);
        }
    }

    fn request(&self, event: &'static str, mut properties: Value) -> Option<impl Future<Output = ()> + Send + 'static> {
        if !sending_allowed() {
            return None;
        }
        let client = self.client.clone()?;
        {
            let state = self.install.lock().unwrap();
            let install = state.as_ref().filter(|install| install.enabled)?;
            properties["distinct_id"] = json!(install.distinct_id);
        }
        properties["platform"] = json!("windows");
        properties["app_version"] = json!(env!("CARGO_PKG_VERSION"));
        properties["session_id"] = json!(self.session_id);
        if std::env::var("AMBIENT_ANALYTICS_DEV").as_deref() == Ok("1") {
            properties["dev"] = json!(true);
        }
        let analytics = self.clone();
        let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        Some(async move {
            if !analytics.is_enabled() {
                return;
            }
            properties["os_version"] = json!(os_version());
            let response = client
                .post("https://us.i.posthog.com/i/v0/e/")
                .json(&json!({
                    // Public, write-only capture key, not an account credential.
                    "api_key": concat!("phc_", "uUbhzyktostk57hnvmntXArEXWkrk78HpdvrcQQVbLvH"),
                    "event": event, "properties": properties, "timestamp": timestamp,
                }))
                .send()
                .await;
            #[cfg(debug_assertions)]
            if std::env::args().any(|argument| argument == "--analytics-smoke-test") {
                if let Ok(response) = response {
                    eprintln!(
                        "PostHog {event} HTTP {}: {}",
                        response.status(),
                        response.text().await.unwrap_or_default()
                    );
                }
            }
            #[cfg(not(debug_assertions))]
            let _ = response;
        })
    }
}

fn os_version() -> String {
    static VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    VERSION
        .get_or_init(|| {
            #[cfg(windows)]
            let mut command = {
                use std::os::windows::process::CommandExt;
                let mut command = std::process::Command::new("cmd.exe");
                command.args(["/C", "ver"]).creation_flags(0x08000000); // CREATE_NO_WINDOW
                command
            };
            #[cfg(not(windows))]
            let mut command = {
                let mut command = std::process::Command::new("sw_vers");
                command.arg("-productVersion");
                command
            };
            command
                .output()
                .ok()
                .filter(|output| output.status.success())
                .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
                .unwrap_or_else(|| "unknown".into())
        })
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tour_lessons_arrive_in_camel_case_and_are_sent_in_snake_case_like_the_mac() {
        let lesson: TourLesson = serde_json::from_value(json!("showScreen")).unwrap();
        assert_eq!(serde_json::to_value(lesson).unwrap(), json!("show_screen"));
    }

    fn directory() -> PathBuf {
        std::env::temp_dir().join(format!("ambient-analytics-{}", Uuid::new_v4()))
    }

    #[test]
    fn identity_and_opt_out_survive_relaunch_and_corrupt_state_is_preserved() {
        let directory = directory();
        let analytics = Analytics::in_directory(directory.clone());
        let id = analytics
            .install
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .distinct_id;
        assert!(analytics.is_enabled());
        analytics.set_enabled(false);
        let relaunched = Analytics::in_directory(directory.clone());
        assert!(!relaunched.is_enabled());
        assert_eq!(
            relaunched
                .install
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .distinct_id,
            id
        );
        relaunched.launched();
        relaunched.command_submitted();
        assert!(
            !relaunched
                .install
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .first_command
        );
        std::fs::write(&analytics.path, b"invalid").unwrap();
        let corrupt = Analytics::in_directory(directory.clone());
        assert!(!corrupt.is_enabled());
        corrupt.set_enabled(true);
        assert_eq!(std::fs::read(&analytics.path).unwrap(), b"invalid");
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_command_is_counts_and_durations_and_a_finished_reply_stays_finished() {
        let mut command = Command::new(Input::Voice);
        command.transcribe_ms = Some(420);
        command.sent_at = Some(Instant::now());
        command.revealed(5);
        command.revealed(7);
        command.tool_calls = 3;
        command.tool_errors = 1;
        command.tools.extend(["look_at_screen".to_string(), "draw_on_screen".to_string()]);
        command.request_chars = Some(18);
        command.spoken_replies = Some(true);
        let properties = command.properties(Outcome::Failed);
        assert_eq!(properties["outcome"], "failed");
        assert_eq!(properties["ok"], false);
        assert_eq!(properties["transcriber"], "publik");
        assert_eq!(properties["reply_chars"], 12);
        assert_eq!(properties["tools"], json!(["draw_on_screen", "look_at_screen"]));
        assert!(properties["first_reply_ms"].is_u64());
        command.finished = true;
        // Stopping the spoken reply of a finished turn does not make it a cancelled command.
        assert_eq!(command.properties(Outcome::Cancelled)["outcome"], "finished");
        assert_eq!(command.properties(Outcome::Cancelled)["ok"], true);

        let typed = Command::new(Input::Text).properties(Outcome::Empty);
        assert_eq!(typed["outcome"], "empty");
        for absent in ["transcriber", "transcribe_ms", "first_reply_ms", "spoken_replies", "request_chars"] {
            assert!(typed.get(absent).is_none(), "{absent} should be omitted");
        }
        assert_eq!(Outcome::of(&AgentFailure::Other { message: "secret".into() }), Outcome::Failed);
        assert_eq!(failure_kind(&AgentFailure::PaymentRequired { message: "secret".into(), top_up_url: None }), "payment_required");
    }

    #[test]
    fn tests_do_not_mark_events_without_explicit_override() {
        if std::env::var("AMBIENT_ANALYTICS_DEV").as_deref() == Ok("1") {
            return;
        }
        assert!(!sending_allowed());
        let directory = directory();
        let analytics = Analytics::in_directory(directory.clone());
        analytics.launched();
        analytics.command_submitted();
        analytics.reached(Step::SigninShown);
        let state = analytics.install.lock().unwrap();
        let install = state.as_ref().unwrap();
        assert!(!install.first_launch && !install.first_command && install.steps.is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }
}
