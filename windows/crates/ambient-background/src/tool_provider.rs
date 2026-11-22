use crate::{
    AgentExecutableResolver, BackgroundTaskManager, HeadlessProcess, HeadlessProcessResult,
    InProcessAgent,
};
use ambient_contracts::{
    ambient_data_directory, AmbientTool, BackgroundTask, BackgroundTaskKind, BackgroundTaskStore,
    ToolDefinition, ToolProvider, ToolResult,
};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::Arc,
    time::Duration,
};
use uuid::Uuid;

pub type Approval =
    Arc<dyn Fn(String, String) -> Pin<Box<dyn Future<Output = bool> + Send>> + Send + Sync>;

pub struct BackgroundApprovalSettings {
    path: PathBuf,
}
#[derive(Serialize, Deserialize, Default)]
struct ApprovalDocument {
    allow_without_asking: bool,
}
impl BackgroundApprovalSettings {
    pub const ALLOW_WITHOUT_ASKING_KEY: &'static str = "ambient.background.allowWithoutAsking";
    pub fn new(path: Option<PathBuf>) -> Result<Self, String> {
        let settings = Self {
            path: path.unwrap_or_else(|| ambient_data_directory().join("background-approval.json")),
        };
        settings.read()?;
        Ok(settings)
    }
    fn read(&self) -> Result<ApprovalDocument, String> {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| format!("Could not read background approval settings: {error}")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(ApprovalDocument::default())
            }
            Err(error) => Err(error.to_string()),
        }
    }
    pub fn allow_without_asking(&self) -> bool {
        self.read()
            .map(|document| document.allow_without_asking)
            .unwrap_or(false)
    }
    pub fn set_allow_without_asking(&self, allow_without_asking: bool) -> Result<(), String> {
        self.read()?;
        crate::create_private_directory(self.path.parent().ok_or("Missing settings directory.")?)?;
        crate::private_write(
            &self.path,
            &serde_json::to_vec(&ApprovalDocument {
                allow_without_asking,
            })
            .map_err(|error| error.to_string())?,
        )
    }
}

pub struct BackgroundToolProvider {
    pub manager: Arc<BackgroundTaskManager>,
    pub approval_settings: Arc<BackgroundApprovalSettings>,
    ambient_agent: Option<InProcessAgent>,
    approve: Approval,
}
impl BackgroundToolProvider {
    pub fn new(
        manager: Arc<BackgroundTaskManager>,
        approval_settings: Arc<BackgroundApprovalSettings>,
        ambient_agent: Option<InProcessAgent>,
        approve: Approval,
    ) -> Self {
        Self {
            manager,
            approval_settings,
            ambient_agent,
            approve,
        }
    }
}
#[async_trait]
impl ToolProvider for BackgroundToolProvider {
    async fn tools(&self) -> Vec<Arc<dyn AmbientTool>> {
        Operation::ALL
            .iter()
            // AppleScript does not exist on Windows; offering the tool would only waste the model's attention.
            .filter(|operation| !(cfg!(windows) && matches!(operation, Operation::AppleScript)))
            .map(|operation| {
                Arc::new(BackgroundTool {
                    operation: *operation,
                    manager: self.manager.clone(),
                    settings: self.approval_settings.clone(),
                    ambient_agent: self.ambient_agent.clone(),
                    approve: self.approve.clone(),
                }) as Arc<dyn AmbientTool>
            })
            .collect()
    }
    async fn system_prompt_section(&self) -> Option<String> {
        let mut prompt = "Work without interrupting the person's desktop. Use spawn_agent for any multi-step job that can run
while the person does something else: coding, fixing or building a project, research, and work in
their connected apps. Start several at once when the jobs are independent. An agent runs on the
person's publik account with a stronger model than this conversation. It has a working directory
with shell access (writes are confined to that directory), web search, the app connections, memory,
and skills; it cannot see the screen. Brief it with the goal, relevant context and files, constraints,
and a concrete definition of done; it knows nothing of this conversation. Pass working_directory when
the job is about an existing project. Leave kind omitted. Set kind to codex or claude only when the
person asks for Codex or Claude Code by name; those need the person's own CLI and subscription.
Use run_shell_command for a specific known command; set
run_in_background for lengthy work. Foreground commands time out after 30 seconds and output is capped
at 256 KiB. Agents and background commands continue after your reply. After starting one, say in a few
words that it is running and stop; never read a task id aloud, and do not wait or poll for it in the
same turn. Use list_background_tasks and get_task_result when the person asks about progress or results. continue_agent
resumes a finished Codex or Claude agent in its original directory and conversation. Agents run without
a terminal or a window: Codex is confined to its workspace; Claude auto-accepts edits and denies
anything that would need another permission prompt. Report permission failures honestly.
".to_owned();
        #[cfg(windows)] prompt.push_str("Shell commands, spawning, and continuing agents require the person's confirmation unless\nthey enabled Allow without asking. A denial means stop that action; do not retry it another way.\nrun_shell_command runs PowerShell on Windows. Use PowerShell syntax, not zsh or bash. AppleScript is unavailable on Windows.\nopen_url and open_application request no activation by default; set activate=true only when the person asked to see the destination.");
        #[cfg(not(windows))] prompt.push_str("Shell commands, AppleScript, spawning, and continuing agents require the person's confirmation unless\nthey enabled Allow without asking. A denial means stop that action; do not retry it another way.\nUse AppleScript for app control without activating the app. Never include activate, open UI, or bring\nan app forward unless the person explicitly asked to see it. open_url and open_application keep the\ncurrent app focused by default; set activate=true only when the person asked to see the destination.");
        Some(prompt)
    }
}
#[derive(Clone, Copy)]
enum Operation {
    Spawn,
    Continue,
    List,
    Result,
    Cancel,
    Shell,
    AppleScript,
    ReadClipboard,
    WriteClipboard,
    OpenUrl,
    OpenApplication,
}
impl Operation {
    const ALL: [Self; 11] = [
        Self::Spawn,
        Self::Continue,
        Self::List,
        Self::Result,
        Self::Cancel,
        Self::Shell,
        Self::AppleScript,
        Self::ReadClipboard,
        Self::WriteClipboard,
        Self::OpenUrl,
        Self::OpenApplication,
    ];
    fn name(self) -> &'static str {
        match self {
            Self::Spawn => "spawn_agent",
            Self::Continue => "continue_agent",
            Self::List => "list_background_tasks",
            Self::Result => "get_task_result",
            Self::Cancel => "cancel_task",
            Self::Shell => "run_shell_command",
            Self::AppleScript => "run_applescript",
            Self::ReadClipboard => "read_clipboard",
            Self::WriteClipboard => "write_clipboard",
            Self::OpenUrl => "open_url",
            Self::OpenApplication => "open_application",
        }
    }
    fn activity(self) -> &'static str {
        match self {
            Self::Spawn => "Starting background agent",
            Self::Continue => "Continuing background agent",
            Self::List => "Checking background tasks",
            Self::Result => "Reading task result",
            Self::Cancel => "Cancelling background task",
            Self::Shell => "Running shell command",
            Self::AppleScript => "Running AppleScript",
            Self::ReadClipboard => "Reading clipboard",
            Self::WriteClipboard => "Writing clipboard",
            Self::OpenUrl => "Opening link",
            Self::OpenApplication => "Opening application",
        }
    }
    fn description(self) -> &'static str {
        match self {
            Self::Spawn => "Start a background agent for coding, research, or work in connected apps, and return its task id immediately. No window opens.",
            Self::Continue => "Resume a finished coding agent with a follow-up message. Returns the same task id immediately.",
            Self::List => "List background tasks, newest first, with status and latest activity.",
            Self::Result => "Get task status, latest activity, final result, and the last 8,000 characters of its readable transcript.",
            Self::Cancel => if cfg!(windows) { "Cancel a task and kill its entire process tree. Finished tasks remain unchanged." } else { "Cancel a task and kill its entire process group. Finished tasks remain unchanged." },
            Self::Shell => if cfg!(windows) { "Run a PowerShell command after approval. Foreground: 30-second timeout, combined output capped at 256 KiB. Background: return a task id immediately." } else { "Run a zsh command after approval. Foreground: 30-second timeout, combined output capped at 256 KiB. Background: return a task id immediately." },
            Self::AppleScript => if cfg!(windows) { "AppleScript is unavailable on Windows. Use PowerShell through run_shell_command for Windows automation." } else { "Run AppleScript after approval, without activating apps unless the script explicitly asks. 30-second timeout; 256 KiB output cap." },
            Self::ReadClipboard => if cfg!(windows) { "Read plain text from the Windows clipboard." } else { "Read plain text from the macOS clipboard." },
            Self::WriteClipboard => if cfg!(windows) { "Replace the Windows clipboard with plain text." } else { "Replace the macOS clipboard with plain text." },
            Self::OpenUrl => "Open a URL while keeping the current app focused by default. Activate only if the person asked to see it.",
            Self::OpenApplication => if cfg!(windows) { "Open an installed Windows application by name or absolute executable path, without activating by default." } else { "Open an installed macOS application by name, bundle id, or absolute .app path, without activating by default." },
        }
    }
    fn properties(self) -> Value {
        fn string(description: &str) -> Value {
            json!({"type":"string","description":description})
        }
        let directory = string(
            "Existing absolute working directory. Omit for a new private Ambient workspace.",
        );
        let task_id = json!({"type":"string","format":"uuid","description":"The task id returned by spawn_agent or run_shell_command."});
        let activation = json!({"type":"boolean","default":false,"description":"Bring the destination to the front only when the person explicitly asked to see it."});
        match self {
            Self::Spawn => {
                json!({"kind":{"type":"string","enum":["ambient","codex","claude"],"description":"Omit for Ambient's own agent. codex or claude only when the person asked for that tool by name."},
                "prompt":string("Goal, context, constraints, and definition of done for the agent."),"title":string("Short readable task title."),"working_directory":directory,"model":string("Optional model explicitly requested by the person; otherwise the CLI default applies.")})
            }
            Self::Continue => {
                json!({"task_id":task_id,"message":string("Follow-up instructions for the original agent session.")})
            }
            Self::Result | Self::Cancel => json!({"task_id":task_id}),
            Self::Shell => {
                json!({"command":string(if cfg!(windows) { "The exact PowerShell command to execute." } else { "The exact zsh command to execute." }),"working_directory":directory,"run_in_background":{"type":"boolean","default":false}})
            }
            Self::AppleScript => {
                json!({"source":string("AppleScript source. Avoid activate and UI-opening commands unless explicitly requested.")})
            }
            Self::WriteClipboard => json!({"text":string("Plain text to place on the clipboard.")}),
            Self::OpenUrl => json!({"url":string("Absolute URL to open."),"activate":activation}),
            Self::OpenApplication => {
                json!({"application":string(if cfg!(windows) { "Installed app name or absolute executable path." } else { "Installed app name, bundle identifier, or absolute .app path." }),"activate":activation})
            }
            Self::List | Self::ReadClipboard => json!({}),
        }
    }
    fn required(self) -> Vec<&'static str> {
        match self {
            Self::Spawn => vec!["prompt", "title"],
            Self::Continue => vec!["task_id", "message"],
            Self::Result | Self::Cancel => vec!["task_id"],
            Self::Shell => vec!["command"],
            Self::AppleScript => vec!["source"],
            Self::WriteClipboard => vec!["text"],
            Self::OpenUrl => vec!["url"],
            Self::OpenApplication => vec!["application"],
            Self::List | Self::ReadClipboard => vec![],
        }
    }
}
struct BackgroundTool {
    operation: Operation,
    manager: Arc<BackgroundTaskManager>,
    settings: Arc<BackgroundApprovalSettings>,
    ambient_agent: Option<InProcessAgent>,
    approve: Approval,
}
#[async_trait]
impl AmbientTool for BackgroundTool {
    fn definition(&self) -> ToolDefinition {
        ToolDefinition {
            name: self.operation.name().into(),
            description: self.operation.description().into(),
            parameters_json_schema: json!({"type":"object","properties":self.operation.properties(),"required":self.operation.required(),"additionalProperties":false}),
        }
    }
    fn activity_label(&self, _arguments: &Value) -> Option<String> {
        Some(self.operation.activity().into())
    }
    async fn run(&self, arguments: Value) -> ToolResult {
        match self.execute(arguments).await {
            Ok(result) => result,
            Err(error) => ToolResult::error(error),
        }
    }
}
impl BackgroundTool {
    async fn approved(&self, title: &str, detail: String) -> bool {
        self.settings.allow_without_asking() || (self.approve)(title.into(), detail).await
    }
    async fn execute(&self, arguments: Value) -> Result<ToolResult, String> {
        self.validate(&arguments)?;
        let working_directory = arguments["working_directory"].as_str().map(str::to_owned);
        let detail = |command: &str| {
            format!(
                "{command}\nDirectory: {}",
                working_directory
                    .as_deref()
                    .unwrap_or("new Ambient workspace")
            )
        };
        let denied = || ToolResult::text("The person denied this action. Nothing was run.");
        match self.operation {
            Operation::Spawn => {
                let kind = arguments["kind"].as_str().unwrap_or("ambient");
                let prompt = text(&arguments, "prompt", false)?;
                if !matches!(kind, "ambient" | "codex" | "claude") {
                    return Err("kind must be codex, claude, or ambient.".into());
                }
                if kind == "ambient" {
                    let run = self
                        .ambient_agent
                        .clone()
                        .ok_or("Ambient agents are not available. Choose codex or claude.")?;
                    if !self.approved("Start agent?", detail(&prompt)).await {
                        return Ok(denied());
                    }
                    let task = self.manager.spawn_in_process_agent(
                        prompt,
                        working_directory,
                        text(&arguments, "title", false)?,
                        run,
                    )?;
                    return Ok(json_result(task_json(&task)));
                }
                if !self
                    .approved(
                        if kind == "codex" {
                            "Start Codex agent?"
                        } else {
                            "Start Claude agent?"
                        },
                        detail(&prompt),
                    )
                    .await
                {
                    return Ok(denied());
                }
                let task = self
                    .manager
                    .spawn_agent(
                        if kind == "codex" {
                            BackgroundTaskKind::CodexAgent
                        } else {
                            BackgroundTaskKind::ClaudeAgent
                        },
                        prompt,
                        working_directory,
                        text(&arguments, "title", false)?,
                        arguments["model"].as_str().map(str::to_owned),
                    )
                    .await?;
                Ok(json_result(task_json(&task)))
            }
            Operation::Continue => {
                let message = text(&arguments, "message", false)?;
                if !self.approved("Continue agent?", message.clone()).await {
                    return Ok(denied());
                }
                Ok(json_result(task_json(
                    &self
                        .manager
                        .continue_agent(task_id(&arguments)?, message)
                        .await?,
                )))
            }
            Operation::List => Ok(json_result(Value::Array(
                self.manager.tasks().await.iter().map(task_json).collect(),
            ))),
            Operation::Result => {
                let id = task_id(&arguments)?;
                let task = self
                    .manager
                    .tasks()
                    .await
                    .into_iter()
                    .find(|task| task.id == id)
                    .ok_or("Task not found.")?;
                let mut result = task_json(&task);
                result["transcript_tail"] =
                    json!(crate::tail(&self.manager.transcript(id).await, 8000));
                Ok(json_result(result))
            }
            Operation::Cancel => {
                let id = task_id(&arguments)?;
                if !self.manager.tasks().await.iter().any(|task| task.id == id) {
                    return Err("Task not found.".into());
                }
                self.manager.cancel(id).await;
                Ok(ToolResult::text(if cfg!(windows) {
                    "Cancellation requested; any running process tree was terminated."
                } else {
                    "Cancellation requested; any running process group was terminated."
                }))
            }
            Operation::Shell => {
                let command = text(&arguments, "command", false)?;
                if !self.approved("Run shell command?", detail(&command)).await {
                    return Ok(denied());
                }
                if arguments["run_in_background"] == true {
                    return Ok(json_result(task_json(
                        &self
                            .manager
                            .run_shell_command(command, working_directory)
                            .await?,
                    )));
                }
                let directory = foreground_directory(working_directory.as_deref())?;
                let (executable, arguments) = crate::headless_process::shell_command(&command);
                Ok(process_result(
                    run(&executable, &arguments, &directory).await?,
                ))
            }
            Operation::AppleScript => {
                let source = text(&arguments, "source", false)?;
                if !self.approved("Run AppleScript?", source.clone()).await {
                    return Ok(denied());
                }
                #[cfg(windows)]
                {
                    Err("AppleScript is not available on Windows. Use run_shell_command with PowerShell.".into())
                }
                #[cfg(not(windows))]
                {
                    Ok(process_result(
                        run(
                            Path::new("/usr/bin/osascript"),
                            &["-e".into(), source],
                            &crate::home_directory(),
                        )
                        .await?,
                    ))
                }
            }
            Operation::ReadClipboard => {
                #[cfg(windows)] let (executable, arguments) = crate::headless_process::shell_command("[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $text = Get-Clipboard -Raw; if ($null -eq $text) { [Console]::Write('Clipboard has no plain text.') } else { [Console]::Write($text) }");
                #[cfg(not(windows))] let (executable, arguments) = (PathBuf::from("/usr/bin/osascript"), vec!["-e".into(), "try\nreturn the clipboard as text\non error\nreturn \"Clipboard has no plain text.\"\nend try".into()]);
                let result = run(&executable, &arguments, &crate::home_directory()).await?;
                if result.exit_code != 0 {
                    return Ok(process_result(result));
                }
                #[allow(unused_mut)]
                let mut content = String::from_utf8_lossy(&result.output).into_owned();
                #[cfg(not(windows))]
                {
                    if content.ends_with('\n') {
                        content.pop();
                    }
                }
                Ok(ToolResult::text(content))
            }
            Operation::WriteClipboard => {
                let value = text(&arguments, "text", true)?;
                #[cfg(windows)]
                let (executable, arguments) = crate::headless_process::shell_command(&format!(
                    "$ErrorActionPreference = 'Stop'; Set-Clipboard -Value '{}'",
                    value.replace('\'', "''")
                ));
                #[cfg(not(windows))]
                let (executable, arguments) = (
                    PathBuf::from("/usr/bin/osascript"),
                    vec![
                        "-e".into(),
                        format!(
                            "set the clipboard to \"{}\"",
                            value.replace('\\', "\\\\").replace('"', "\\\"")
                        ),
                    ],
                );
                let result = run(&executable, &arguments, &crate::home_directory()).await?;
                Ok(if result.exit_code == 0 && !result.timed_out {
                    ToolResult::text("Clipboard updated.")
                } else {
                    ToolResult::error("Could not write clipboard.")
                })
            }
            Operation::OpenUrl | Operation::OpenApplication => {
                let is_application = matches!(self.operation, Operation::OpenApplication);
                let destination = text(
                    &arguments,
                    if is_application { "application" } else { "url" },
                    false,
                )?;
                if !is_application && url::Url::parse(&destination).is_err() {
                    return Err("Provide an absolute URL.".into());
                }
                let activate = arguments["activate"].as_bool().unwrap_or(false);
                open_destination(&destination, activate, is_application).await?;
                Ok(ToolResult::text(format!(
                    "{} opened{}.",
                    if is_application { "Application" } else { "URL" },
                    if activate {
                        " in front"
                    } else {
                        " without requesting activation"
                    }
                )))
            }
        }
    }
    fn validate(&self, arguments: &Value) -> Result<(), String> {
        let values = arguments
            .as_object()
            .ok_or("Tool arguments must be a JSON object.")?;
        let properties = self.operation.properties();
        for (key, value) in values {
            let property = properties
                .get(key)
                .ok_or_else(|| format!("Unknown argument: {key}"))?;
            if value.as_str().is_some_and(|value| value.contains('\0')) {
                return Err(format!("{key} must not contain a null byte."));
            }
            if if property["type"] == "boolean" {
                !value.is_boolean()
            } else {
                !value.is_string()
            } {
                return Err(format!("Invalid type for {key}."));
            }
        }
        for key in self.operation.required() {
            if !values.contains_key(key) {
                return Err(format!("Missing required argument: {key}"));
            }
        }
        Ok(())
    }
}
fn text(arguments: &Value, key: &str, allow_empty: bool) -> Result<String, String> {
    arguments[key]
        .as_str()
        .filter(|value| allow_empty || !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("{key} must be a nonempty string."))
}
fn task_id(arguments: &Value) -> Result<Uuid, String> {
    Uuid::parse_str(&text(arguments, "task_id", false)?)
        .map_err(|_| "task_id must be a UUID.".into())
}
fn task_json(task: &BackgroundTask) -> Value {
    json!({"task_id":task.id,"kind":task.kind,"title":task.title,"status":task.status,"latest_activity":task.latest_activity,"working_directory":task.working_directory,"result":task.result})
}
fn json_result(value: Value) -> ToolResult {
    ToolResult::text(value.to_string())
}
async fn run(
    executable: &Path,
    arguments: &[String],
    directory: &Path,
) -> Result<HeadlessProcessResult, String> {
    HeadlessProcess::run(
        executable,
        arguments,
        directory,
        &AgentExecutableResolver::environment(),
        Duration::from_secs(30),
        256 * 1024,
    )
    .await
}
fn process_result(result: HeadlessProcessResult) -> ToolResult {
    let mut content = String::from_utf8_lossy(&result.output).into_owned();
    if result.output_was_truncated {
        content.push_str("\n[Output capped at 256 KiB.]");
    }
    if result.timed_out {
        content.push_str(if cfg!(windows) {
            "\n[Timed out after 30 seconds; the process tree was killed.]"
        } else {
            "\n[Timed out after 30 seconds; the process group was killed.]"
        });
    }
    content.push_str(&format!("\n[Exit code: {}]", result.exit_code));
    ToolResult {
        content,
        is_error: result.exit_code != 0 || result.timed_out,
        images: vec![],
    }
}
fn foreground_directory(path: Option<&str>) -> Result<PathBuf, String> {
    if let Some(path) = path {
        let expanded = crate::expanded_path(path);
        if !expanded.is_absolute() || !expanded.is_dir() {
            return Err("Working directory must be an existing absolute directory.".into());
        }
        Ok(expanded)
    } else {
        let directory =
            BackgroundTaskManager::default_workspace_directory().join(Uuid::new_v4().to_string());
        crate::create_private_directory(&directory)?;
        Ok(directory)
    }
}
async fn open_destination(
    destination: &str,
    activate: bool,
    is_application: bool,
) -> Result<(), String> {
    #[cfg(windows)]
    {
        use windows::{
            core::PCWSTR,
            Win32::{
                Foundation::RPC_E_CHANGED_MODE,
                System::Com::*,
                UI::{Shell::*, WindowsAndMessaging::*},
            },
        };
        let destination = if is_application {
            windows_application(destination)?
        } else {
            destination.into()
        };
        let wide: Vec<u16> = destination.encode_utf16().chain(Some(0)).collect();
        let mut execute = SHELLEXECUTEINFOW::default();
        execute.cbSize = std::mem::size_of_val(&execute) as u32;
        execute.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
        execute.lpFile = PCWSTR(wide.as_ptr());
        execute.nShow = if activate {
            SW_SHOWNORMAL.0
        } else {
            SW_SHOWNOACTIVATE.0
        };
        unsafe {
            let initialized =
                CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
            if initialized.is_err() && initialized != RPC_E_CHANGED_MODE {
                return Err(initialized.to_string());
            }
            let opened = ShellExecuteExW(&mut execute);
            if initialized.is_ok() {
                CoUninitialize();
            }
            opened.map_err(|error| error.to_string())?;
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let mut arguments: Vec<String> = Vec::new();
        if !activate {
            arguments.push("-g".into());
        }
        if is_application {
            arguments.extend(["-a".into(), destination.into()]);
        } else {
            arguments.extend(["--".into(), destination.into()]);
        }
        let result = run(
            Path::new("/usr/bin/open"),
            &arguments,
            &crate::home_directory(),
        )
        .await?;
        if result.exit_code == 0 && !result.timed_out {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&result.output).into_owned())
        }
    }
}

#[cfg(windows)]
fn windows_application(application: &str) -> Result<String, String> {
    if let Ok(path) = which::which(application) {
        return Ok(path.to_string_lossy().into_owned());
    }
    let requested_path = Path::new(application);
    if requested_path.is_absolute() {
        return if requested_path.is_file() {
            Ok(application.into())
        } else {
            Err(format!("Application not found: {application}"))
        };
    }
    fn shortcut_in(directory: &Path, name: &str) -> Option<PathBuf> {
        for entry in std::fs::read_dir(directory).ok()?.flatten() {
            let path = entry.path();
            let file_type = entry.file_type().ok()?;
            if file_type.is_dir() {
                if let Some(shortcut) = shortcut_in(&path, name) {
                    return Some(shortcut);
                }
            } else if path
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("lnk"))
                && path
                    .file_stem()
                    .is_some_and(|stem| stem.eq_ignore_ascii_case(name))
            {
                return Some(path);
            }
        }
        None
    }
    for variable in ["APPDATA", "PROGRAMDATA"] {
        if let Some(root) = std::env::var_os(variable) {
            if let Some(shortcut) = shortcut_in(
                &PathBuf::from(root).join("Microsoft/Windows/Start Menu/Programs"),
                application,
            ) {
                return Ok(shortcut.to_string_lossy().into_owned());
            }
        }
    }
    // ShellExecute also resolves applications registered in Windows' App Paths registry.
    if requested_path.components().count() == 1 {
        Ok(if requested_path.extension().is_none() {
            format!("{application}.exe")
        } else {
            application.into()
        })
    } else {
        Err(format!("Application not found: {application}"))
    }
}
