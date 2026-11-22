//! The seams between Ambient's subsystems, ported from
//! `Packages/AmbientKit/Sources/AmbientContracts/Contracts.swift`. Each subsystem crate depends on this crate only.
//! Changing a declaration here changes the agreement for every crate: keep it small.
//!
//! Swift → Rust conventions used everywhere in the Windows port:
//! - `JSONValue` is `serde_json::Value`.
//! - `AsyncStream<T>` of events is a `tokio::sync::mpsc::UnboundedReceiver<T>`; the stream ends when the sender drops.
//! - `updates()` streams that resend the whole list are a `tokio::sync::watch::Receiver<Vec<T>>`.
//! - `URL` is a `String`; file locations are `PathBuf`; `Date` is `chrono::DateTime<Utc>`.
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, watch};
use uuid::Uuid;

pub use serde_json::Value as JsonValue;

// ---------- Tools ----------

/// One function the model can call. `parameters_json_schema` is a JSON Schema object.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters_json_schema: JsonValue,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ToolResult {
    /// What the model reads back. Plain text or JSON text.
    pub content: String,
    pub is_error: bool,
    /// Images the model should see next (a screenshot tool returns them here).
    pub images: Vec<ImageAttachment>,
}

impl ToolResult {
    pub fn text(content: impl Into<String>) -> Self {
        Self { content: content.into(), is_error: false, images: Vec::new() }
    }
    pub fn error(content: impl Into<String>) -> Self {
        Self { content: content.into(), is_error: true, images: Vec::new() }
    }
}

#[async_trait]
pub trait AmbientTool: Send + Sync {
    fn definition(&self) -> ToolDefinition;
    /// A few words for the flow bar while this call runs, such as "Searching Gmail". None shows the tool name.
    fn activity_label(&self, _arguments: &JsonValue) -> Option<String> {
        None
    }
    async fn run(&self, arguments: JsonValue) -> ToolResult;
}

/// A subsystem's contribution to the agent: its tools, and what the model must know to use them.
/// The agent asks again at the start of every user turn, so both may change over time.
#[async_trait]
pub trait ToolProvider: Send + Sync {
    async fn tools(&self) -> Vec<Arc<dyn AmbientTool>>;
    async fn system_prompt_section(&self) -> Option<String>;
}

// ---------- Agent ----------

#[derive(Debug, Clone, PartialEq)]
pub struct ImageAttachment {
    pub data: Vec<u8>,
    pub mime_type: String,
    /// Shown to the model beside the image, such as "screen 1 of 2 (primary), 1512x982 pixels".
    pub label: String,
}

#[derive(Debug, Clone, Default)]
pub struct UserTurn {
    pub text: String,
    pub images: Vec<ImageAttachment>,
}

impl UserTurn {
    pub fn text(text: impl Into<String>) -> Self {
        Self { text: text.into(), images: Vec::new() }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum AgentEvent {
    TextDelta(String),
    ToolStarted { call_id: String, tool_name: String, activity_label: String },
    ToolFinished { call_id: String, tool_name: String, is_error: bool },
    /// The turn ended normally. `final_text` is the whole assistant reply.
    Finished { final_text: String },
    Failed(AgentFailure),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum AgentFailure {
    /// publik answered 402. Show `message` and the one link, nothing else.
    #[serde(rename_all = "camelCase")]
    PaymentRequired { message: String, top_up_url: Option<String> },
    NotSignedIn,
    Cancelled,
    Other { message: String },
}

impl std::fmt::Display for AgentFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AgentFailure::PaymentRequired { message, .. } | AgentFailure::Other { message } => formatter.write_str(message),
            AgentFailure::NotSignedIn => formatter.write_str("Sign in with publik to use Ambient."),
            AgentFailure::Cancelled => formatter.write_str("Cancelled."),
        }
    }
}
impl std::error::Error for AgentFailure {}

/// One running conversation. `send` runs the model and its tool calls to completion and streams what happens.
#[async_trait]
pub trait AgentSession: Send + Sync {
    /// The stream ends after `Finished` or `Failed`.
    fn send(&self, turn: UserTurn) -> mpsc::UnboundedReceiver<AgentEvent>;
    /// Stops the turn in flight; its stream ends with `Failed(Cancelled)`.
    async fn cancel(&self);
    /// Forgets the conversation so far.
    async fn reset(&self);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelTier {
    Fast,
    Balanced,
    Smart,
}

impl ModelTier {
    pub fn model_name(self) -> &'static str {
        match self {
            ModelTier::Fast => "publik-fast",
            ModelTier::Balanced => "publik-balanced",
            ModelTier::Smart => "publik-smart",
        }
    }
}

/// A single model call with no tools, for subsystems that need one (memory extraction, titles).
#[async_trait]
pub trait TextCompletionService: Send + Sync {
    async fn complete(&self, system_prompt: &str, user_prompt: &str, tier: ModelTier) -> Result<String, AgentFailure>;
}

/// Where the model key comes from. None means the person has not signed in.
#[derive(Debug, Clone, PartialEq)]
pub struct AiCredential {
    pub base_url: String,
    pub api_key: String,
}

#[async_trait]
pub trait AiCredentialSource: Send + Sync {
    async fn credential(&self) -> Option<AiCredential>;
}

// ---------- Background tasks (agents and commands that run without a window) ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BackgroundTaskKind {
    CodexAgent,
    ClaudeAgent,
    ShellCommand,
    AmbientAgent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BackgroundTaskStatus {
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackgroundTask {
    pub id: Uuid,
    pub kind: BackgroundTaskKind,
    pub title: String,
    pub status: BackgroundTaskStatus,
    pub working_directory: Option<String>,
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
    /// The newest thing it did, one line, for the flow bar.
    pub latest_activity: String,
    /// Its final answer, once it has one.
    pub result: Option<String>,
}

#[async_trait]
pub trait BackgroundTaskStore: Send + Sync {
    async fn tasks(&self) -> Vec<BackgroundTask>;
    /// The whole list, sent again on every change. Newest first.
    fn updates(&self) -> watch::Receiver<Vec<BackgroundTask>>;
    async fn cancel(&self, task_id: Uuid);
    /// Removes a finished task from the list.
    async fn dismiss(&self, task_id: Uuid);
    /// Everything the task printed so far, readable by a person.
    async fn transcript(&self, task_id: Uuid) -> String;
}

// ---------- Memory (ambient learning) ----------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryItem {
    pub id: Uuid,
    /// One durable fact or preference, as a sentence.
    pub text: String,
    pub created_at: DateTime<Utc>,
    /// True when Ambient learned it from a conversation; false when the person or the model saved it on purpose.
    pub was_learned_automatically: bool,
}

#[async_trait]
pub trait MemoryStore: Send + Sync {
    async fn items(&self) -> Vec<MemoryItem>;
    fn updates(&self) -> watch::Receiver<Vec<MemoryItem>>;
    async fn add(&self, text: &str);
    async fn delete(&self, item_id: Uuid);
    async fn is_automatic_learning_enabled(&self) -> bool;
    async fn set_automatic_learning_enabled(&self, is_enabled: bool);
    /// Called after each finished exchange. Decides on its own whether anything in it is worth keeping.
    async fn learn(&self, user_text: &str, assistant_text: &str);
}

// ---------- Skills ----------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillSummary {
    pub name: String,
    pub description: String,
    pub is_built_in: bool,
    pub directory: PathBuf,
}

#[async_trait]
pub trait SkillStore: Send + Sync {
    async fn skills(&self) -> Vec<SkillSummary>;
    fn updates(&self) -> watch::Receiver<Vec<SkillSummary>>;
    /// Copies a skill folder (one that holds a SKILL.md) into the person's skills.
    async fn install(&self, from_directory: &std::path::Path) -> Result<(), String>;
    async fn delete(&self, skill_name: &str) -> Result<(), String>;
}

// ---------- Connectors (Composio) ----------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectorApp {
    pub slug: String,
    pub name: String,
    pub logo_url: Option<String>,
    pub is_connected: bool,
}

#[async_trait]
pub trait ConnectorService: Send + Sync {
    /// Apps matching `query`, or the popular ones when it is empty, each with whether this person connected it.
    async fn apps(&self, matching_query: &str) -> Result<Vec<ConnectorApp>, String>;
    /// The page where the person authorises the app. Open it in the browser.
    async fn authorization_url(&self, app_slug: &str) -> Result<String, String>;
    async fn disconnect(&self, app_slug: &str) -> Result<(), String>;
}

/// Where Ambient keeps its own files on this computer: `%APPDATA%\Ambient` on Windows,
/// `~/Library/Application Support/Ambient Windows Dev` when the port is run on a Mac for development
/// (so it never touches the real Mac app's stores), `~/.config/Ambient` elsewhere.
/// `AMBIENT_DATA_DIR` overrides it (tests).
pub fn ambient_data_directory() -> PathBuf {
    if let Some(override_directory) = std::env::var_os("AMBIENT_DATA_DIR").filter(|value| !value.is_empty()) {
        return PathBuf::from(override_directory);
    }
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from).unwrap_or_default();
    if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| home.join("AppData").join("Roaming")).join("Ambient")
    } else if cfg!(target_os = "macos") {
        home.join("Library").join("Application Support").join("Ambient Windows Dev")
    } else {
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config")).join("Ambient")
    }
}
