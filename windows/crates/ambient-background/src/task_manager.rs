use crate::{
    headless_process::{shell_command, ProcessControl},
    AgentEventParser, AgentExecutableResolver, HeadlessProcess, HeadlessProcessEvent,
    HeadlessProcessResult,
};
use ambient_contracts::{
    ambient_data_directory, AgentFailure, BackgroundTask, BackgroundTaskKind, BackgroundTaskStatus,
    BackgroundTaskStore,
};
use async_trait::async_trait;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex},
};
use tokio::sync::{mpsc, watch};
use uuid::Uuid;

pub type InProcessAgent = Arc<
    dyn Fn(
            String,
            PathBuf,
            Arc<dyn Fn(String) + Send + Sync>,
        ) -> Pin<Box<dyn Future<Output = Result<String, AgentFailure>> + Send>>
        + Send
        + Sync,
>;

#[derive(Clone)]
pub struct BackgroundTaskManager {
    inner: Arc<ManagerInner>,
}
struct ManagerInner {
    storage_directory: PathBuf,
    workspace_directory: PathBuf,
    state: Mutex<ManagerState>,
    updates: watch::Sender<Vec<BackgroundTask>>,
}
#[derive(Default)]
struct ManagerState {
    records: HashMap<Uuid, PersistedBackgroundTask>,
    processes: HashMap<Uuid, Arc<ProcessControl>>,
    in_process_agents: HashMap<Uuid, tokio::task::AbortHandle>,
    completions: Vec<mpsc::UnboundedSender<BackgroundTask>>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedBackgroundTask {
    #[serde(flatten)]
    task: BackgroundTask,
    session_id: Option<String>,
    model: Option<String>,
    agent_failure: Option<String>,
}
impl PersistedBackgroundTask {
    fn new(
        kind: BackgroundTaskKind,
        title: String,
        directory: &Path,
        model: Option<String>,
    ) -> Self {
        Self {
            task: BackgroundTask {
                id: Uuid::new_v4(),
                kind,
                title,
                status: BackgroundTaskStatus::Running,
                working_directory: Some(directory.to_string_lossy().into_owned()),
                started_at: Utc::now(),
                finished_at: None,
                latest_activity: "Starting".into(),
                result: None,
            },
            session_id: None,
            model,
            agent_failure: None,
        }
    }
}
impl Drop for ManagerInner {
    fn drop(&mut self) {
        let state = self.state.get_mut().unwrap();
        for process in state.processes.values() {
            process.terminate(false);
        }
        for agent in state.in_process_agents.values() {
            agent.abort();
        }
    }
}
impl BackgroundTaskManager {
    pub fn default_storage_directory() -> PathBuf {
        ambient_data_directory().join("tasks")
    }
    pub fn default_workspace_directory() -> PathBuf {
        ambient_data_directory().join("workspaces")
    }
    pub fn new(
        storage_directory: Option<PathBuf>,
        workspace_directory: Option<PathBuf>,
    ) -> Result<Self, String> {
        let storage_directory = storage_directory.unwrap_or_else(Self::default_storage_directory);
        crate::create_private_directory(&storage_directory)?;
        let mut records = HashMap::new();
        for entry in std::fs::read_dir(&storage_directory).map_err(|error| error.to_string())? {
            let path = entry.map_err(|error| error.to_string())?.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
                continue;
            }
            let bytes = std::fs::read(&path).map_err(|error| error.to_string())?;
            let mut record: PersistedBackgroundTask = serde_json::from_slice(&bytes)
                .map_err(|error| format!("Could not read task {}: {error}", path.display()))?;
            if path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .and_then(|stem| Uuid::parse_str(stem).ok())
                != Some(record.task.id)
            {
                return Err(format!(
                    "Task id does not match its filename: {}",
                    path.display()
                ));
            }
            if record.task.status == BackgroundTaskStatus::Running {
                record.task.status = BackgroundTaskStatus::Failed;
                record.task.finished_at = Some(Utc::now());
                record.task.latest_activity = "Ambient restarted; the previous process is no longer supervised. Its completion could not be verified.".into();
                record.task.result = Some(record.task.latest_activity.clone());
                crate::private_append(
                    &storage_directory.join(format!("{}.log", record.task.id)),
                    &record.task.latest_activity,
                )?;
                crate::private_write(
                    &path,
                    &serde_json::to_vec(&record).map_err(|error| error.to_string())?,
                )?;
            }
            records.insert(record.task.id, record);
        }
        let (updates, _) = watch::channel(task_list(&records));
        Ok(Self {
            inner: Arc::new(ManagerInner {
                storage_directory,
                workspace_directory: workspace_directory
                    .unwrap_or_else(Self::default_workspace_directory),
                state: Mutex::new(ManagerState {
                    records,
                    ..Default::default()
                }),
                updates,
            }),
        })
    }
    pub fn completions(&self) -> mpsc::UnboundedReceiver<BackgroundTask> {
        let (sender, receiver) = mpsc::unbounded_channel();
        self.inner.state.lock().unwrap().completions.push(sender);
        receiver
    }
    pub async fn spawn_agent(
        &self,
        kind: BackgroundTaskKind,
        prompt: String,
        working_directory: Option<String>,
        title: String,
        model: Option<String>,
    ) -> Result<BackgroundTask, String> {
        if !matches!(
            kind,
            BackgroundTaskKind::CodexAgent | BackgroundTaskKind::ClaudeAgent
        ) {
            return Err("Choose codex or claude for an agent.".into());
        }
        let (executable, environment) =
            AgentExecutableResolver::resolve(if kind == BackgroundTaskKind::CodexAgent {
                "codex"
            } else {
                "claude"
            })
            .await?;
        let directory = self.prepare_directory(working_directory.as_deref())?;
        let record = PersistedBackgroundTask::new(kind, title, &directory, model);
        let arguments = agent_arguments(&record, &prompt, false);
        self.start(
            &mut self.inner.state.lock().unwrap(),
            record,
            &executable,
            &arguments,
            &environment,
            &prompt,
        )
    }
    pub fn spawn_in_process_agent(
        &self,
        prompt: String,
        working_directory: Option<String>,
        title: String,
        run: InProcessAgent,
    ) -> Result<BackgroundTask, String> {
        let directory = self.prepare_directory(working_directory.as_deref())?;
        let record =
            PersistedBackgroundTask::new(BackgroundTaskKind::AmbientAgent, title, &directory, None);
        let task = record.task.clone();
        let mut state = self.inner.state.lock().unwrap();
        state.records.insert(task.id, record);
        if let Err(error) = self
            .inner
            .append_transcript(task.id, &format!("\nUser: {prompt}\n"))
            .and_then(|_| self.inner.persist(&state, task.id))
        {
            self.inner.start_failed(&mut state, task.id, &error);
            return Err(error);
        }
        let weak_manager = Arc::downgrade(&self.inner);
        let report_manager = weak_manager.clone();
        let task_id = task.id;
        let report_activity: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |activity| {
            if let Some(inner) = report_manager.upgrade() {
                let mut state = inner.state.lock().unwrap();
                let Some(record) = state
                    .records
                    .get_mut(&task_id)
                    .filter(|record| record.task.status == BackgroundTaskStatus::Running)
                else {
                    return;
                };
                record.task.latest_activity = AgentEventParser::single_line(&activity);
                if let Err(error) = inner
                    .append_transcript(task_id, &activity)
                    .and_then(|_| inner.persist(&state, task_id))
                {
                    inner.storage_failure(&mut state, task_id, &error);
                }
                inner.publish(&state);
            }
        });
        let agent = tokio::spawn(async move {
            let outcome = run(prompt, directory, report_activity).await;
            if let Some(inner) = weak_manager.upgrade() {
                let mut state = inner.state.lock().unwrap();
                if state.in_process_agents.remove(&task_id).is_none() {
                    return;
                }
                let Some(record) = state
                    .records
                    .get_mut(&task_id)
                    .filter(|record| record.task.status == BackgroundTaskStatus::Running)
                else {
                    return;
                };
                match outcome {
                    Ok(answer) => {
                        record.task.status = BackgroundTaskStatus::Succeeded;
                        record.task.result = Some(answer);
                        record.task.latest_activity = "Finished".into();
                    }
                    Err(error) => {
                        record.task.status = BackgroundTaskStatus::Failed;
                        record.task.result = Some(error.to_string());
                        record.task.latest_activity = "Failed".into();
                    }
                }
                record.task.finished_at = Some(Utc::now());
                let answer = record.task.result.clone().unwrap_or_default();
                if let Err(error) = inner
                    .append_transcript(task_id, &answer)
                    .and_then(|_| inner.persist(&state, task_id))
                {
                    inner.storage_failure(&mut state, task_id, &error);
                }
                inner.publish_completion(&mut state, task_id);
            }
        });
        state
            .in_process_agents
            .insert(task.id, agent.abort_handle());
        self.inner.publish(&state);
        Ok(task)
    }
    pub async fn continue_agent(
        &self,
        task_id: Uuid,
        message: String,
    ) -> Result<BackgroundTask, String> {
        let previous = {
            let state = self.inner.state.lock().unwrap();
            let previous = state.records.get(&task_id).ok_or("Task not found.")?;
            if previous.task.status == BackgroundTaskStatus::Running {
                return Err("The agent is still running. Wait for it to finish first.".into());
            }
            if previous.session_id.is_none() {
                return Err("This task has no resumable agent session.".into());
            }
            previous.clone()
        };
        let (executable, environment) = AgentExecutableResolver::resolve(
            if previous.task.kind == BackgroundTaskKind::CodexAgent {
                "codex"
            } else {
                "claude"
            },
        )
        .await?;
        let mut state = self.inner.state.lock().unwrap();
        let mut record = state
            .records
            .get(&task_id)
            .ok_or("Task not found.")?
            .clone();
        if record.task.status == BackgroundTaskStatus::Running {
            return Err("The agent is already running.".into());
        }
        record.task.status = BackgroundTaskStatus::Running;
        record.task.finished_at = None;
        record.task.result = None;
        record.task.latest_activity = "Continuing agent".into();
        record.agent_failure = None;
        let arguments = agent_arguments(&record, &message, true);
        self.start(
            &mut state,
            record,
            &executable,
            &arguments,
            &environment,
            &message,
        )
    }
    pub async fn run_shell_command(
        &self,
        command: String,
        working_directory: Option<String>,
    ) -> Result<BackgroundTask, String> {
        let directory = self.prepare_directory(working_directory.as_deref())?;
        let record = PersistedBackgroundTask::new(
            BackgroundTaskKind::ShellCommand,
            AgentEventParser::single_line(&command),
            &directory,
            None,
        );
        let (executable, arguments) = shell_command(&command);
        self.start(
            &mut self.inner.state.lock().unwrap(),
            record,
            &executable,
            &arguments,
            &AgentExecutableResolver::environment(),
            &command,
        )
    }
    fn prepare_directory(&self, path: Option<&str>) -> Result<PathBuf, String> {
        if let Some(path) = path {
            let expanded = crate::expanded_path(path);
            if !expanded.is_absolute() {
                return Err("Working directory must be an absolute path.".into());
            }
            if !expanded.is_dir() {
                return Err(format!(
                    "Working directory does not exist: {}",
                    expanded.display()
                ));
            }
            return Ok(expanded);
        }
        let directory = self
            .inner
            .workspace_directory
            .join(Uuid::new_v4().to_string());
        crate::create_private_directory(&directory)?;
        Ok(directory)
    }
    fn start(
        &self,
        state: &mut ManagerState,
        record: PersistedBackgroundTask,
        executable: &Path,
        arguments: &[String],
        environment: &HashMap<String, String>,
        prompt: &str,
    ) -> Result<BackgroundTask, String> {
        let task = record.task.clone();
        state.records.insert(task.id, record);
        let started = self
            .inner
            .append_transcript(task.id, &format!("\nUser: {prompt}\n"))
            .and_then(|_| self.inner.persist(state, task.id))
            .and_then(|_| {
                HeadlessProcess::new(
                    executable,
                    arguments,
                    Path::new(task.working_directory.as_ref().unwrap()),
                    environment,
                    None,
                    256 * 1024,
                )
            });
        let mut process = match started {
            Ok(process) => process,
            Err(error) => {
                self.inner.start_failed(state, task.id, &error);
                return Err(error);
            }
        };
        state.processes.insert(task.id, process.control.clone());
        let weak_manager = Arc::downgrade(&self.inner);
        let task_id = task.id;
        tokio::spawn(async move {
            let mut partial_lines = [Vec::new(), Vec::new()];
            while let Some(event) = process.events.recv().await {
                let Some(inner) = weak_manager.upgrade() else {
                    process.terminate();
                    return;
                };
                let mut state = inner.state.lock().unwrap();
                if !state
                    .processes
                    .get(&task_id)
                    .is_some_and(|control| Arc::ptr_eq(control, &process.control))
                {
                    return;
                }
                match event {
                    HeadlessProcessEvent::Output {
                        data,
                        is_standard_error,
                    } => {
                        let partial = &mut partial_lines[usize::from(is_standard_error)];
                        partial.extend_from_slice(&data);
                        while let Some(newline) = partial.iter().position(|byte| *byte == b'\n') {
                            let line = String::from_utf8_lossy(&partial[..newline]).into_owned();
                            partial.drain(..=newline);
                            inner.receive(&mut state, task_id, &line, is_standard_error);
                        }
                        if partial.len() > 1024 * 1024 {
                            inner.receive(
                                &mut state,
                                task_id,
                                &String::from_utf8_lossy(partial),
                                is_standard_error,
                            );
                            partial.clear();
                        }
                    }
                    HeadlessProcessEvent::Finished(result) => {
                        for (channel, partial) in partial_lines.iter().enumerate() {
                            if !partial.is_empty() {
                                inner.receive(
                                    &mut state,
                                    task_id,
                                    &String::from_utf8_lossy(partial),
                                    channel == 1,
                                );
                            }
                        }
                        inner.finish(&mut state, task_id, result);
                    }
                }
            }
        });
        self.inner.publish(state);
        Ok(task)
    }
}
impl ManagerInner {
    fn record_path(&self, id: Uuid) -> PathBuf {
        self.storage_directory.join(format!("{id}.json"))
    }
    fn transcript_path(&self, id: Uuid) -> PathBuf {
        self.storage_directory.join(format!("{id}.log"))
    }
    fn append_transcript(&self, id: Uuid, text: &str) -> Result<(), String> {
        crate::private_append(&self.transcript_path(id), text)
    }
    fn persist(&self, state: &ManagerState, id: Uuid) -> Result<(), String> {
        crate::private_write(
            &self.record_path(id),
            &serde_json::to_vec(&state.records[&id]).map_err(|error| error.to_string())?,
        )
    }
    fn publish(&self, state: &ManagerState) {
        self.updates.send_replace(task_list(&state.records));
    }
    fn publish_completion(&self, state: &mut ManagerState, id: Uuid) {
        self.publish(state);
        if let Some(record) = state.records.get(&id) {
            state
                .completions
                .retain(|sender| sender.send(record.task.clone()).is_ok());
        }
    }
    fn storage_failure(&self, state: &mut ManagerState, id: Uuid, error: &str) {
        if let Some(record) = state.records.get_mut(&id) {
            record.task.latest_activity = format!("Could not save task: {error}");
        }
    }
    fn start_failed(&self, state: &mut ManagerState, id: Uuid, error: &str) {
        if let Some(record) = state.records.get_mut(&id) {
            record.task.status = BackgroundTaskStatus::Failed;
            record.task.finished_at = Some(Utc::now());
            record.task.latest_activity = format!("Could not start: {error}");
            record.task.result = Some(record.task.latest_activity.clone());
        }
        let _ = self.persist(state, id);
        self.publish_completion(state, id);
    }
    fn receive(&self, state: &mut ManagerState, id: Uuid, line: &str, is_standard_error: bool) {
        let Some(record) = state
            .records
            .get_mut(&id)
            .filter(|record| record.task.status == BackgroundTaskStatus::Running)
        else {
            return;
        };
        let event = if record.task.kind == BackgroundTaskKind::ShellCommand {
            crate::ParsedAgentEvent {
                activity: Some(AgentEventParser::single_line(line)),
                transcript: Some(line.into()),
                ..Default::default()
            }
        } else if is_standard_error {
            crate::ParsedAgentEvent {
                transcript: Some(line.into()),
                ..Default::default()
            }
        } else {
            AgentEventParser::parse(line, record.task.kind)
        };
        if event.session_id.is_some() {
            record.session_id = event.session_id;
        }
        if event.result.is_some() {
            record.task.result = event.result;
        }
        if event.failure.is_some() {
            record.agent_failure = event.failure;
        }
        if let Some(activity) = event.activity.filter(|activity| !activity.is_empty()) {
            record.task.latest_activity = AgentEventParser::single_line(&activity);
        }
        let saved = event
            .transcript
            .filter(|transcript| !transcript.is_empty())
            .map_or(Ok(()), |transcript| self.append_transcript(id, &transcript))
            .and_then(|_| self.persist(state, id));
        if let Err(error) = saved {
            self.storage_failure(state, id, &error);
        }
        self.publish(state);
    }
    fn finish(&self, state: &mut ManagerState, id: Uuid, result: HeadlessProcessResult) {
        state.processes.remove(&id);
        let Some(record) = state
            .records
            .get_mut(&id)
            .filter(|record| record.task.status == BackgroundTaskStatus::Running)
        else {
            return;
        };
        if record.task.kind != BackgroundTaskKind::ShellCommand
            && record.task.result.is_none()
            && record.agent_failure.is_none()
            && result.exit_code == 0
        {
            record.agent_failure = Some(
                "The CLI exited without a final answer. See the transcript for details.".into(),
            );
        }
        let succeeded = result.exit_code == 0 && record.agent_failure.is_none();
        record.task.status = if succeeded {
            BackgroundTaskStatus::Succeeded
        } else {
            BackgroundTaskStatus::Failed
        };
        record.task.finished_at = Some(Utc::now());
        if record.task.kind == BackgroundTaskKind::ShellCommand {
            let mut output = String::from_utf8_lossy(&result.output).into_owned();
            if result.output_was_truncated {
                output.push_str("\n[Result capped at 256 KiB; full output is in the transcript.]");
            }
            record.task.result = Some(output);
        } else if record.agent_failure.is_some() {
            record.task.result = record.agent_failure.clone();
        }
        if !succeeded && record.task.result.is_none() {
            let transcript = std::fs::read_to_string(self.transcript_path(id)).unwrap_or_default();
            record.task.result = Some(format!(
                "Process exited with code {}.\n{}",
                result.exit_code,
                crate::tail(&transcript, 4000)
            ));
        }
        record.task.latest_activity = if succeeded {
            "Finished".into()
        } else {
            format!("Failed (exit {})", result.exit_code)
        };
        if let Err(error) = self.persist(state, id) {
            self.storage_failure(state, id, &error);
        }
        self.publish_completion(state, id);
    }
}
fn task_list(records: &HashMap<Uuid, PersistedBackgroundTask>) -> Vec<BackgroundTask> {
    let mut tasks: Vec<_> = records.values().map(|record| record.task.clone()).collect();
    tasks.sort_by_key(|task| std::cmp::Reverse(task.started_at));
    tasks
}
#[async_trait]
impl BackgroundTaskStore for BackgroundTaskManager {
    async fn tasks(&self) -> Vec<BackgroundTask> {
        task_list(&self.inner.state.lock().unwrap().records)
    }
    fn updates(&self) -> watch::Receiver<Vec<BackgroundTask>> {
        self.inner.updates.subscribe()
    }
    async fn transcript(&self, task_id: Uuid) -> String {
        let state = self.inner.state.lock().unwrap();
        if !state.records.contains_key(&task_id) {
            return "Task not found.".into();
        }
        std::fs::read(self.inner.transcript_path(task_id))
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
            .unwrap_or_else(|error| format!("Could not read transcript: {error}"))
    }
    async fn cancel(&self, task_id: Uuid) {
        let mut state = self.inner.state.lock().unwrap();
        if !state
            .records
            .get(&task_id)
            .is_some_and(|record| record.task.status == BackgroundTaskStatus::Running)
        {
            return;
        }
        if let Some(process) = state.processes.remove(&task_id) {
            process.terminate(false);
        }
        if let Some(agent) = state.in_process_agents.remove(&task_id) {
            agent.abort();
        }
        let record = state.records.get_mut(&task_id).unwrap();
        record.task.status = BackgroundTaskStatus::Cancelled;
        record.task.finished_at = Some(Utc::now());
        record.task.latest_activity = "Cancelled".into();
        record.task.result = Some("Cancelled by the user.".into());
        if let Err(error) = self
            .inner
            .append_transcript(task_id, "Cancelled by the user.")
            .and_then(|_| self.inner.persist(&state, task_id))
        {
            self.inner.storage_failure(&mut state, task_id, &error);
        }
        self.inner.publish_completion(&mut state, task_id);
    }
    async fn dismiss(&self, task_id: Uuid) {
        let mut state = self.inner.state.lock().unwrap();
        if !state
            .records
            .get(&task_id)
            .is_some_and(|record| record.task.status != BackgroundTaskStatus::Running)
        {
            return;
        }
        let removed = std::fs::remove_file(self.inner.record_path(task_id)).and_then(|_| {
            let path = self.inner.transcript_path(task_id);
            if path.exists() {
                std::fs::remove_file(path)
            } else {
                Ok(())
            }
        });
        match removed {
            Ok(()) => {
                state.records.remove(&task_id);
            }
            Err(error) => self
                .inner
                .storage_failure(&mut state, task_id, &error.to_string()),
        }
        self.inner.publish(&state);
    }
}
fn agent_arguments(record: &PersistedBackgroundTask, prompt: &str, resuming: bool) -> Vec<String> {
    let codex = record.task.kind == BackgroundTaskKind::CodexAgent;
    let mut arguments: Vec<String> = if codex {
        let mut arguments = vec!["exec"];
        if resuming {
            arguments.push("resume");
        }
        arguments.extend([
            "--json",
            "--skip-git-repo-check",
            "-c",
            "approval_policy=\"never\"",
            "-c",
            "sandbox_mode=\"workspace-write\"",
        ]);
        arguments.into_iter().map(str::to_owned).collect()
    } else {
        let mut arguments: Vec<String> = [
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--permission-mode",
            "acceptEdits",
            "--permission-prompts",
            "none",
            "--no-chrome",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        if resuming {
            arguments.extend(["--resume".into(), record.session_id.clone().unwrap()]);
        }
        arguments
    };
    if let Some(model) = &record.model {
        arguments.extend(["--model".into(), model.clone()]);
    }
    if resuming && codex {
        arguments.push(record.session_id.clone().unwrap());
    }
    let computer = if cfg!(windows) { "PC" } else { "Mac" };
    arguments.extend(["--".into(), format!("You are running headlessly in Ambient while the person uses their {computer}. Do not open windows, launch\nGUI apps, or change focus unless the person's task explicitly asks to see something. Work through\nfiles and headless commands. Do not launch interactive permission or authentication flows; report\nmissing access in your final answer. The person's task follows:\n\n{prompt}")]);
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    fn manager(directory: &Path) -> BackgroundTaskManager {
        BackgroundTaskManager::new(
            Some(directory.join("tasks")),
            Some(directory.join("workspaces")),
        )
        .unwrap()
    }
    async fn recorded_process(
        kind: BackgroundTaskKind,
        lines: &[&str],
    ) -> (tempfile::TempDir, BackgroundTaskManager, BackgroundTask) {
        let directory = tempfile::tempdir().unwrap();
        let manager = manager(directory.path());
        let mut completed = manager.completions();
        let script = lines
            .iter()
            .map(|line| {
                if cfg!(windows) {
                    format!("[Console]::WriteLine('{}')", line.replace('\'', "''"))
                } else {
                    format!("printf '%s\\n' '{}'", line.replace('\'', "'\\''"))
                }
            })
            .collect::<Vec<_>>()
            .join("; ");
        let script = if script.is_empty() {
            "exit 0".into()
        } else {
            script
        };
        let (executable, arguments) = shell_command(&script);
        let record =
            PersistedBackgroundTask::new(kind, "Recorded CLI".into(), directory.path(), None);
        manager
            .start(
                &mut manager.inner.state.lock().unwrap(),
                record,
                &executable,
                &arguments,
                &AgentExecutableResolver::environment(),
                "task",
            )
            .unwrap();
        let completed = tokio::time::timeout(Duration::from_secs(15), completed.recv())
            .await
            .unwrap()
            .unwrap();
        (directory, manager, completed)
    }
    #[tokio::test]
    async fn recorded_cli_sessions_survive_relaunch() {
        for (kind, lines) in [
            (
                BackgroundTaskKind::CodexAgent,
                vec![
                    r#"{"type":"thread.started","thread_id":"session-123"}"#,
                    r#"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#,
                ],
            ),
            (
                BackgroundTaskKind::ClaudeAgent,
                vec![
                    r#"{"type":"system","session_id":"session-123"}"#,
                    r#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"session-123"}"#,
                ],
            ),
        ] {
            let (directory, original, finished) = recorded_process(kind, &lines).await;
            assert_eq!(finished.status, BackgroundTaskStatus::Succeeded);
            assert_eq!(finished.result.as_deref(), Some("done"));
            assert!(original.transcript(finished.id).await.contains("done"));
            let relaunched = manager(directory.path());
            let state = relaunched.inner.state.lock().unwrap();
            let record = &state.records[&finished.id];
            assert_eq!(record.session_id.as_deref(), Some("session-123"));
            let arguments = agent_arguments(record, "follow up", true);
            assert!(arguments.contains(&"session-123".into()));
            assert_eq!(record.task.working_directory, finished.working_directory);
        }
    }
    #[tokio::test]
    async fn cli_exit_zero_without_final_answer_is_failure() {
        let (_directory, _manager, task) =
            recorded_process(BackgroundTaskKind::CodexAgent, &[]).await;
        assert_eq!(task.status, BackgroundTaskStatus::Failed);
        assert_eq!(
            task.result.as_deref(),
            Some("The CLI exited without a final answer. See the transcript for details.")
        );
    }
    #[tokio::test]
    async fn structured_cli_failure_overrides_zero_exit_and_partial_answer() {
        let (_directory, _manager, task) = recorded_process(BackgroundTaskKind::CodexAgent, &[
            r#"{"type":"item.completed","item":{"type":"agent_message","text":"partial answer"}}"#,
            r#"{"type":"turn.failed","error":{"message":"Authentication required"}}"#,
        ]).await;
        assert_eq!(task.status, BackgroundTaskStatus::Failed);
        assert_eq!(task.result.as_deref(), Some("Authentication required"));
    }
    #[tokio::test]
    async fn failed_spawn_is_persisted_and_published_once() {
        let directory = tempfile::tempdir().unwrap();
        let manager = manager(directory.path());
        let mut completed = manager.completions();
        let record = PersistedBackgroundTask::new(
            BackgroundTaskKind::CodexAgent,
            "Missing".into(),
            directory.path(),
            None,
        );
        let id = record.task.id;
        assert!(manager
            .start(
                &mut manager.inner.state.lock().unwrap(),
                record,
                &directory.path().join("no-such-executable"),
                &[],
                &AgentExecutableResolver::environment(),
                "task"
            )
            .is_err());
        let failed = completed.recv().await.unwrap();
        assert_eq!(failed.id, id);
        assert_eq!(failed.status, BackgroundTaskStatus::Failed);
        assert!(completed.try_recv().is_err());
        assert_eq!(self::manager(directory.path()).tasks().await[0], failed);
    }
    #[test]
    fn cli_flags_models_and_headless_prompt_match_the_mac_contract() {
        let mut codex = PersistedBackgroundTask::new(
            BackgroundTaskKind::CodexAgent,
            "task".into(),
            Path::new("."),
            Some("requested-model".into()),
        );
        codex.session_id = Some("session-123".into());
        let arguments = agent_arguments(&codex, "person's task\nkeep context", false);
        assert_eq!(
            &arguments[..9],
            [
                "exec",
                "--json",
                "--skip-git-repo-check",
                "-c",
                "approval_policy=\"never\"",
                "-c",
                "sandbox_mode=\"workspace-write\"",
                "--model",
                "requested-model"
            ]
        );
        assert_eq!(arguments[9], "--");
        let prompt = arguments.last().unwrap();
        assert!(prompt.ends_with("The person's task follows:\n\nperson's task\nkeep context"));
        assert!(prompt.contains(if cfg!(windows) {
            "uses their PC"
        } else {
            "uses their Mac"
        }));
        let resumed = agent_arguments(&codex, "continue", true);
        assert_eq!(&resumed[..2], ["exec", "resume"]);
        assert_eq!(&resumed[10..12], ["session-123", "--"]);
        let mut claude = codex;
        claude.task.kind = BackgroundTaskKind::ClaudeAgent;
        claude.model = None;
        let arguments = agent_arguments(&claude, "task", true);
        assert_eq!(
            &arguments[..12],
            [
                "-p",
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-mode",
                "acceptEdits",
                "--permission-prompts",
                "none",
                "--no-chrome",
                "--resume",
                "session-123",
                "--"
            ]
        );
    }
}
