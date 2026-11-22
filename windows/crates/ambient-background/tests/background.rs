use ambient_background::*;
use ambient_contracts::{
    AmbientTool, BackgroundTask, BackgroundTaskKind as Kind, BackgroundTaskStatus as Status,
    BackgroundTaskStore, ToolProvider,
};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tempfile::TempDir;
use uuid::Uuid;

fn manager(directory: &Path) -> Arc<BackgroundTaskManager> {
    Arc::new(
        BackgroundTaskManager::new(
            Some(directory.join("tasks")),
            Some(directory.join("workspaces")),
        )
        .unwrap(),
    )
}
fn command(unix: &str, windows: &str) -> String {
    if cfg!(windows) { windows } else { unix }.into()
}
fn shell(command: &str) -> (PathBuf, Vec<String>) {
    if cfg!(windows) {
        (
            "powershell.exe".into(),
            vec![
                "-NoLogo".into(),
                "-NoProfile".into(),
                "-NonInteractive".into(),
                "-ExecutionPolicy".into(),
                "Bypass".into(),
                "-Command".into(),
                command.into(),
            ],
        )
    } else {
        (
            if Path::new("/bin/zsh").exists() {
                "/bin/zsh"
            } else {
                "/bin/sh"
            }
            .into(),
            vec!["-c".into(), command.into()],
        )
    }
}
async fn execute(
    command: &str,
    directory: &Path,
    timeout: Duration,
    limit: usize,
) -> HeadlessProcessResult {
    let (executable, arguments) = shell(command);
    HeadlessProcess::run(
        &executable,
        &arguments,
        directory,
        &AgentExecutableResolver::environment(),
        timeout,
        limit,
    )
    .await
    .unwrap()
}
async fn completion(
    receiver: &mut tokio::sync::mpsc::UnboundedReceiver<BackgroundTask>,
) -> BackgroundTask {
    tokio::time::timeout(Duration::from_secs(15), receiver.recv())
        .await
        .unwrap()
        .unwrap()
}
fn provider(
    directory: &Path,
    approve: Approval,
    ambient_agent: Option<InProcessAgent>,
) -> BackgroundToolProvider {
    BackgroundToolProvider::new(
        manager(directory),
        Arc::new(BackgroundApprovalSettings::new(Some(directory.join("approval.json"))).unwrap()),
        ambient_agent,
        approve,
    )
}
async fn tool(provider: &BackgroundToolProvider, name: &str) -> Arc<dyn AmbientTool> {
    provider
        .tools()
        .await
        .into_iter()
        .find(|tool| tool.definition().name == name)
        .unwrap()
}
fn approval(answer: bool) -> Approval {
    Arc::new(move |_, _| Box::pin(async move { answer }))
}

#[test]
fn recorded_codex_events() {
    let start = AgentEventParser::parse(
        r#"{"type":"thread.started","thread_id":"01a1f15d-62fe-7f33-8408-14d5a32cca45"}"#,
        Kind::CodexAgent,
    );
    assert_eq!(
        start.session_id.as_deref(),
        Some("01a1f15d-62fe-7f33-8408-14d5a32cca45")
    );
    let answer = AgentEventParser::parse(
        r#"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"done"}}"#,
        Kind::CodexAgent,
    );
    assert_eq!(answer.result.as_deref(), Some("done"));
    assert_eq!(answer.activity.as_deref(), Some("done"));
    assert!(AgentEventParser::parse(
        r#"{"type":"turn.completed","usage":{"input_tokens":31051,"output_tokens":5}}"#,
        Kind::CodexAgent
    )
    .failure
    .is_none());
}
#[test]
fn recorded_claude_events() {
    let assistant = AgentEventParser::parse(
        r#"{"type":"assistant","message":{"model":"claude-fable-5-2","role":"assistant","content":[{"type":"text","text":"done"}]},"session_id":"e4cd7206-656e-4110-9b40-a45d60bcc6ce","parent_tool_use_id":null}"#,
        Kind::ClaudeAgent,
    );
    assert_eq!(assistant.transcript.as_deref(), Some("done"));
    assert!(assistant.result.is_none());
    let result = AgentEventParser::parse(
        r#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"e4cd7206-656e-4110-9b40-a45d60bcc6ce"}"#,
        Kind::ClaudeAgent,
    );
    assert_eq!(result.result.as_deref(), Some("done"));
    assert_eq!(
        result.session_id.as_deref(),
        Some("e4cd7206-656e-4110-9b40-a45d60bcc6ce")
    );
    assert!(result.failure.is_none());
}
#[test]
fn command_file_tool_and_search_progress() {
    let result = AgentEventParser::parse(
        r#"{"type":"item.completed","item":{"type":"command_execution","command":"swift test\n--filter Example","aggregated_output":"passed\n","exit_code":0}}"#,
        Kind::CodexAgent,
    );
    assert_eq!(
        result.activity.as_deref(),
        Some("Running: swift test --filter Example")
    );
    assert!(result.transcript.unwrap().contains("passed"));
    let edit = AgentEventParser::parse(
        r#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"hello.txt","kind":"add"}]}}"#,
        Kind::CodexAgent,
    );
    assert_eq!(edit.activity.as_deref(), Some("Editing hello.txt"));
    let tool = AgentEventParser::parse(
        r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"hello.txt","content":"ok"}}]}}"#,
        Kind::ClaudeAgent,
    );
    assert_eq!(tool.activity.as_deref(), Some("Write: hello.txt"));
    let output = AgentEventParser::parse(
        r#"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"File created"}]}]}}"#,
        Kind::ClaudeAgent,
    );
    assert_eq!(output.transcript.as_deref(), Some("File created"));
    assert_eq!(AgentEventParser::parse(r#"{"type":"item.started","item":{"type":"mcp_tool_call","server":"files","tool":"read"}}"#, Kind::CodexAgent).activity.as_deref(), Some("Using files.read"));
    assert_eq!(
        AgentEventParser::parse(
            r#"{"type":"item.started","item":{"type":"web_search"}}"#,
            Kind::CodexAgent
        )
        .activity
        .as_deref(),
        Some("Searching the web")
    );
}
#[test]
fn failures_unrecognized_output_and_unicode_activity_limit() {
    for (line, kind, expected) in [
        (
            r#"{"type":"turn.failed","error":{"message":"Authentication required"}}"#,
            Kind::CodexAgent,
            "Authentication required",
        ),
        (
            r#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Not logged in"]}"#,
            Kind::ClaudeAgent,
            "Not logged in",
        ),
    ] {
        assert_eq!(
            AgentEventParser::parse(line, kind).failure.as_deref(),
            Some(expected)
        );
    }
    assert_eq!(
        AgentEventParser::parse("fatal: CLI missing", Kind::CodexAgent)
            .transcript
            .as_deref(),
        Some("fatal: CLI missing")
    );
    assert!(
        AgentEventParser::parse(r#"{"type":"future_event"}"#, Kind::CodexAgent)
            .failure
            .is_none()
    );
    assert_eq!(AgentEventParser::parse(r#"{"type":"item.completed","item":{"type":"error","message":"Configuration warning"}}"#, Kind::CodexAgent).transcript.as_deref(), Some("Configuration warning"));
    assert_eq!(
        AgentEventParser::single_line("  editing\n\tfile  "),
        "editing file"
    );
    assert_eq!(
        AgentEventParser::single_line(&"🦀".repeat(300))
            .chars()
            .count(),
        240
    );
    assert_eq!(
        AgentEventParser::single_line(&"e\u{301}".repeat(300)),
        "e\u{301}".repeat(240)
    );
}

#[tokio::test]
async fn lifecycle_updates_independent_completions_persistence_and_dismissal() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let mut updates = manager.updates();
    assert!(updates.borrow().is_empty());
    let mut first = manager.completions();
    let mut second = manager.completions();
    let task = manager.run_shell_command(command("printf 'hello\\n'; sleep 0.1; printf 'done\\n'", "[Console]::Write(\"hello`n\"); Start-Sleep -Milliseconds 100; [Console]::Write(\"done`n\")"), Some(directory.path().to_string_lossy().into())).await.unwrap();
    updates.changed().await.unwrap();
    assert_eq!(updates.borrow()[0].id, task.id);
    let finished = completion(&mut first).await;
    assert_eq!(finished.status, Status::Succeeded);
    assert_eq!(finished.result.as_deref(), Some("hello\ndone\n"));
    assert!(finished.finished_at.is_some());
    assert_eq!(completion(&mut second).await, finished);
    assert!(first.try_recv().is_err());
    let transcript = manager.transcript(task.id).await;
    assert!(transcript.contains("hello\ndone"));
    let recovered = self::manager(directory.path());
    assert_eq!(recovered.tasks().await, vec![finished]);
    assert_eq!(recovered.transcript(task.id).await, transcript);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(directory.path().join(format!("tasks/{}.json", task.id)))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    recovered.dismiss(task.id).await;
    assert!(recovered.tasks().await.is_empty());
    assert!(!directory
        .path()
        .join(format!("tasks/{}.log", task.id))
        .exists());
    assert_eq!(recovered.transcript(task.id).await, "Task not found.");
}
#[tokio::test]
async fn relaunch_marks_interrupted_work_failed_and_corrupt_journal_is_preserved() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let task = manager
        .run_shell_command(
            command("sleep 30", "Start-Sleep -Seconds 30"),
            Some(directory.path().to_string_lossy().into()),
        )
        .await
        .unwrap();
    let record_path = directory.path().join(format!("tasks/{}.json", task.id));
    let interrupted = std::fs::read(&record_path).unwrap();
    manager.cancel(task.id).await;
    std::fs::write(&record_path, interrupted).unwrap();
    let recovered = self::manager(directory.path());
    assert_eq!(recovered.tasks().await[0].status, Status::Failed);
    assert!(recovered.tasks().await[0]
        .result
        .as_ref()
        .unwrap()
        .contains("could not be verified"));
    assert!(recovered
        .transcript(task.id)
        .await
        .contains("Ambient restarted"));
    std::fs::write(&record_path, b"broken json").unwrap();
    assert!(BackgroundTaskManager::new(Some(directory.path().join("tasks")), None).is_err());
    assert_eq!(std::fs::read(record_path).unwrap(), b"broken json");
}
#[tokio::test]
async fn failure_fresh_workspace_and_directory_validation() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let mut completed = manager.completions();
    let task = manager
        .run_shell_command(
            command(
                "printf 'bad\\n' >&2; exit 7",
                "[Console]::Error.WriteLine('bad'); exit 7",
            ),
            None,
        )
        .await
        .unwrap();
    assert!(Path::new(task.working_directory.as_ref().unwrap())
        .starts_with(directory.path().join("workspaces")));
    let finished = completion(&mut completed).await;
    assert_eq!(finished.status, Status::Failed);
    assert!(finished.result.unwrap().contains("bad"));
    assert!(finished.latest_activity.contains('7'));
    assert!(manager
        .run_shell_command(
            "exit 0".into(),
            Some(directory.path().join("missing").to_string_lossy().into())
        )
        .await
        .unwrap_err()
        .contains("does not exist"));
    assert!(manager
        .run_shell_command("exit 0".into(), Some("relative".into()))
        .await
        .unwrap_err()
        .contains("absolute"));
}
#[tokio::test]
async fn concurrent_processes_have_independent_pipes_and_cancel_is_idempotent() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let mut completions = manager.completions();
    let long = manager
        .run_shell_command(
            command("sleep 30", "Start-Sleep -Seconds 30"),
            Some(directory.path().to_string_lossy().into()),
        )
        .await
        .unwrap();
    manager.dismiss(long.id).await;
    assert_eq!(manager.tasks().await[0].status, Status::Running);
    let short = manager
        .run_shell_command(
            command("printf short", "[Console]::Write('short')"),
            Some(directory.path().to_string_lossy().into()),
        )
        .await
        .unwrap();
    assert_eq!(
        completion(&mut completions).await.result.as_deref(),
        Some("short")
    );
    assert_eq!(
        manager
            .tasks()
            .await
            .iter()
            .map(|task| task.id)
            .collect::<Vec<_>>(),
        vec![short.id, long.id]
    );
    manager.cancel(long.id).await;
    let cancelled = completion(&mut completions).await;
    assert_eq!(cancelled.status, Status::Cancelled);
    manager.cancel(long.id).await;
    assert!(completions.try_recv().is_err());
    assert_eq!(manager.tasks().await[1], cancelled);
}
#[tokio::test]
async fn output_is_capped_and_stderr_cannot_corrupt_json() {
    let directory = TempDir::new().unwrap();
    let result = execute(
        &command(
            "head -c 400000 /dev/zero | tr '\\0' x",
            "[Console]::Write('x' * 400000)",
        ),
        directory.path(),
        Duration::from_secs(15),
        256 * 1024,
    )
    .await;
    assert_eq!(result.exit_code, 0);
    assert_eq!(result.output.len(), 256 * 1024);
    assert!(result.output_was_truncated);
    let script = command("(head -c 100000 /dev/zero | tr '\\0' x >&2) & printf '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}\\n'; wait", "[Console]::Error.Write('x' * 100000); [Console]::WriteLine('{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}')");
    let (executable, arguments) = shell(&script);
    let mut process = HeadlessProcess::new(
        &executable,
        &arguments,
        directory.path(),
        &AgentExecutableResolver::environment(),
        Some(Duration::from_secs(15)),
        256 * 1024,
    )
    .unwrap();
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    while let Some(event) = process.events.recv().await {
        if let HeadlessProcessEvent::Output {
            data,
            is_standard_error,
        } = event
        {
            if is_standard_error {
                stderr.extend(data);
            } else {
                stdout.extend(data);
            }
        }
    }
    assert_eq!(stderr.len(), 100000);
    assert_eq!(
        AgentEventParser::parse(&String::from_utf8_lossy(&stdout), Kind::CodexAgent)
            .result
            .as_deref(),
        Some("done")
    );
}
#[tokio::test]
async fn headless_process_has_closed_input_and_correct_directory() {
    let directory = TempDir::new().unwrap();
    let result = execute(&command("test ! -t 0 && test ! -t 1 && test ! -t 2 && ! read reply && pwd", "if ($null -ne [Console]::ReadLine()) { exit 9 }; [Console]::Write((Get-Location).Path)"), directory.path(), Duration::from_secs(15), 256 * 1024).await;
    assert_eq!(result.exit_code, 0);
    let output = String::from_utf8_lossy(&result.output);
    assert_eq!(
        std::fs::canonicalize(output.trim()).unwrap(),
        std::fs::canonicalize(directory.path()).unwrap()
    );
}
#[tokio::test]
async fn in_process_agent_reports_and_cancels_without_duplicate_completions() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let mut finished = manager.completions();
    let run: InProcessAgent = Arc::new(|prompt, directory, report| {
        Box::pin(async move {
            assert_eq!(prompt, "work");
            assert!(directory.is_dir());
            report("editing\na file".into());
            Ok("done".into())
        })
    });
    let task = manager
        .spawn_in_process_agent("work".into(), None, "Agent".into(), run)
        .unwrap();
    assert_eq!(
        completion(&mut finished).await.result.as_deref(),
        Some("done")
    );
    assert!(manager
        .transcript(task.id)
        .await
        .contains("editing\na file"));
    assert!(manager
        .continue_agent(task.id, "again".into())
        .await
        .unwrap_err()
        .contains("no resumable"));
    let run: InProcessAgent = Arc::new(|_, _, _| Box::pin(std::future::pending()));
    let task = manager
        .spawn_in_process_agent("wait".into(), None, "Waiting".into(), run)
        .unwrap();
    manager.cancel(task.id).await;
    assert_eq!(completion(&mut finished).await.status, Status::Cancelled);
    assert!(finished.try_recv().is_err());
    let run: InProcessAgent = Arc::new(|_, _, _| {
        Box::pin(async {
            Err(ambient_contracts::AgentFailure::Other {
                message: "Agent failed".into(),
            })
        })
    });
    manager
        .spawn_in_process_agent("fail".into(), None, "Failure".into(), run)
        .unwrap();
    assert_eq!(
        completion(&mut finished).await.result.as_deref(),
        Some("Agent failed")
    );
}

#[tokio::test]
async fn approvals_are_exact_and_denial_starts_nothing() {
    let directory = TempDir::new().unwrap();
    let prompts = Arc::new(Mutex::new(Vec::new()));
    let recorded = prompts.clone();
    let approve: Approval = Arc::new(move |title, _| {
        recorded.lock().unwrap().push(title);
        Box::pin(async { false })
    });
    let ambient: InProcessAgent =
        Arc::new(|_, _, _| Box::pin(async { panic!("denied agent ran") }));
    let provider = provider(directory.path(), approve, Some(ambient));
    for (name, arguments) in [
        (
            "spawn_agent",
            json!({"kind":"codex","prompt":"Do not run","title":"Denied"}),
        ),
        (
            "spawn_agent",
            json!({"kind":"claude","prompt":"Do not run","title":"Denied"}),
        ),
        (
            "spawn_agent",
            json!({"prompt":"Do not run","title":"Denied"}),
        ),
        (
            "continue_agent",
            json!({"task_id":Uuid::new_v4(),"message":"Do not resume"}),
        ),
        ("run_shell_command", json!({"command":"exit 99"})),
        (
            "run_applescript",
            json!({"source":"error \"should never run\""}),
        ),
    ] {
        let result = tool(&provider, name).await.run(arguments).await;
        assert!(!result.is_error);
        assert!(result.content.contains("denied"));
    }
    assert!(provider.manager.tasks().await.is_empty());
    assert_eq!(
        *prompts.lock().unwrap(),
        [
            "Start Codex agent?",
            "Start Claude agent?",
            "Start agent?",
            "Continue agent?",
            "Run shell command?",
            "Run AppleScript?"
        ]
    );
}
#[test]
fn approval_settings_persist_and_never_overwrite_corrupt_data() {
    let directory = TempDir::new().unwrap();
    let path = directory.path().join("approval.json");
    let first = BackgroundApprovalSettings::new(Some(path.clone())).unwrap();
    assert!(!first.allow_without_asking());
    first.set_allow_without_asking(true).unwrap();
    let second = BackgroundApprovalSettings::new(Some(path.clone())).unwrap();
    assert!(second.allow_without_asking());
    second.set_allow_without_asking(false).unwrap();
    assert!(!first.allow_without_asking());
    std::fs::write(&path, "corrupt").unwrap();
    assert!(!first.allow_without_asking());
    assert!(first.set_allow_without_asking(true).is_err());
    assert!(BackgroundApprovalSettings::new(Some(path.clone())).is_err());
    assert_eq!(std::fs::read_to_string(path).unwrap(), "corrupt");
}
#[tokio::test]
async fn schemas_labels_invalid_arguments_and_foreground_bypass() {
    let directory = TempDir::new().unwrap();
    let provider = provider(
        directory.path(),
        Arc::new(|_, _| Box::pin(async { panic!("should not approve") })),
        None,
    );
    let tools = provider.tools().await;
    assert_eq!(tools.len(), 11);
    for tool in &tools {
        let definition = tool.definition();
        assert_eq!(definition.parameters_json_schema["type"], "object");
        assert_eq!(
            definition.parameters_json_schema["additionalProperties"],
            false
        );
        assert!(tool.activity_label(&json!({})).is_some());
    }
    let shell = tool(&provider, "run_shell_command").await;
    for arguments in [
        json!([]),
        json!({}),
        json!({"command":3}),
        json!({"command":"true","run_in_background":"yes"}),
        json!({"command":"true","extra":true}),
        json!({"command":"bad\u{0000}"}),
    ] {
        assert!(shell.run(arguments).await.is_error);
    }
    assert!(
        tool(&provider, "spawn_agent")
            .await
            .run(json!({"kind":"other","prompt":"hello","title":"test"}))
            .await
            .is_error
    );
    let open = tool(&provider, "open_url").await;
    assert_eq!(
        open.definition().parameters_json_schema["properties"]["activate"]["default"],
        false
    );
    assert!(open.run(json!({"url":"relative-path"})).await.is_error);
    provider
        .approval_settings
        .set_allow_without_asking(true)
        .unwrap();
    let result = shell.run(json!({"command":command("printf ok", "[Console]::Write('ok')"),"working_directory":directory.path()})).await;
    assert!(!result.is_error, "{}", result.content);
    assert!(result.content.starts_with("ok"));
    assert!(result.content.contains("Exit code: 0"));
}
#[tokio::test]
async fn tools_start_background_work_and_retrieve_results() {
    let directory = TempDir::new().unwrap();
    let provider = provider(directory.path(), approval(true), None);
    let mut completed = provider.manager.completions();
    let response = tool(&provider, "run_shell_command").await.run(json!({"command":command("printf 'background ok'", "[Console]::Write('background ok')"),"run_in_background":true})).await;
    assert!(!response.is_error, "{}", response.content);
    let response: Value = serde_json::from_str(&response.content).unwrap();
    completion(&mut completed).await;
    let result_tool = tool(&provider, "get_task_result").await;
    let result = result_tool
        .run(json!({"task_id":response["task_id"]}))
        .await;
    let result: Value = serde_json::from_str(&result.content).unwrap();
    assert_eq!(result["status"], "succeeded");
    assert_eq!(result["result"], "background ok");
    assert!(result["transcript_tail"]
        .as_str()
        .unwrap()
        .contains("background ok"));
    assert!(
        result_tool
            .run(json!({"task_id":Uuid::new_v4()}))
            .await
            .is_error
    );
}
#[cfg(target_os = "macos")]
#[tokio::test]
async fn applescript_runs_headlessly() {
    let directory = TempDir::new().unwrap();
    let provider = provider(directory.path(), approval(true), None);
    let result = tool(&provider, "run_applescript")
        .await
        .run(json!({"source":"return \"ambient ok\""}))
        .await;
    assert!(!result.is_error, "{}", result.content);
    assert!(result.content.contains("ambient ok"));
}
#[cfg(any(windows, target_os = "macos"))]
#[tokio::test]
async fn workspace_can_write_inside_but_cannot_write_to_user_profile() {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap();
    let directory = tempfile::Builder::new()
        .prefix("ambient-workspace-test-")
        .tempdir_in(Path::new(&home))
        .unwrap();
    let outside_file =
        Path::new(&home).join(format!("ambient-agent-escape-{}.txt", Uuid::new_v4()));
    let provider = AgentWorkspaceToolProvider::new(directory.path().into());
    let shell = provider.tools().await.remove(0);
    let inside = shell.run(json!({"command":command("echo ok > note.txt && cat note.txt", "Set-Content -Path note.txt -Value ok; Get-Content note.txt")})).await;
    assert!(!inside.is_error, "{}", inside.content);
    assert!(inside.content.starts_with("ok"));
    assert_eq!(
        std::fs::read_to_string(directory.path().join("note.txt"))
            .unwrap()
            .trim(),
        "ok"
    );
    let path = outside_file.to_string_lossy().replace('\'', "''");
    let outside = shell.run(json!({"command":command(&format!("echo no > '{path}'"), &format!("Set-Content -LiteralPath '{path}' -Value no"))})).await;
    assert!(outside.is_error, "{}", outside.content);
    assert!(!outside_file.exists());
}

fn process_is_running(identifier: u32) -> bool {
    #[cfg(unix)]
    {
        unsafe { libc::kill(identifier as i32, 0) == 0 }
    }
    #[cfg(windows)]
    {
        use windows::Win32::{Foundation::CloseHandle, System::Threading::*};
        unsafe {
            let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, identifier)
            else {
                return false;
            };
            let mut exit_code = 0;
            let running = GetExitCodeProcess(process, &mut exit_code).is_ok() && exit_code == 259;
            let _ = CloseHandle(process);
            running
        }
    }
}
fn process_tree_command() -> String {
    command("sleep 60 & child=$!; echo $child > child.pid; wait", "$child = Start-Process -FilePath powershell.exe -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru; Set-Content -Path child.pid -Value $child.Id; $child.WaitForExit()")
}
async fn read_child_pid(path: &Path) -> u32 {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Ok(contents) = std::fs::read_to_string(path) {
                if let Ok(identifier) = contents.trim().parse() {
                    break identifier;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap()
}
async fn assert_process_stopped(identifier: u32) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while process_is_running(identifier) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("Grandchild survived cancellation");
}
#[tokio::test]
async fn cancellation_kills_the_whole_process_tree() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let task = manager
        .run_shell_command(
            process_tree_command(),
            Some(directory.path().to_string_lossy().into()),
        )
        .await
        .unwrap();
    let identifier = read_child_pid(&directory.path().join("child.pid")).await;
    assert!(process_is_running(identifier));
    manager.cancel(task.id).await;
    assert_process_stopped(identifier).await;
    assert_eq!(manager.tasks().await[0].status, Status::Cancelled);
}
#[tokio::test]
async fn timeout_kills_the_whole_process_tree() {
    let directory = TempDir::new().unwrap();
    let timeout = if cfg!(windows) {
        Duration::from_secs(4)
    } else {
        Duration::from_millis(150)
    };
    let result = execute(
        &process_tree_command(),
        directory.path(),
        timeout,
        256 * 1024,
    )
    .await;
    assert!(result.timed_out);
    assert_ne!(result.exit_code, 0);
    let identifier = read_child_pid(&directory.path().join("child.pid")).await;
    assert_process_stopped(identifier).await;
}
#[tokio::test]
async fn dropping_manager_stops_owned_processes_and_in_process_agents() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    manager
        .run_shell_command(
            process_tree_command(),
            Some(directory.path().to_string_lossy().into()),
        )
        .await
        .unwrap();
    let identifier = read_child_pid(&directory.path().join("child.pid")).await;
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let sender = Arc::new(Mutex::new(Some(sender)));
    struct OnDrop(Option<tokio::sync::oneshot::Sender<()>>);
    impl Drop for OnDrop {
        fn drop(&mut self) {
            if let Some(sender) = self.0.take() {
                let _ = sender.send(());
            }
        }
    }
    let (started, ready) = tokio::sync::oneshot::channel();
    let started = Arc::new(Mutex::new(Some(started)));
    let run: InProcessAgent = Arc::new(move |_, _, _| {
        let guard = OnDrop(sender.lock().unwrap().take());
        let started = started.lock().unwrap().take();
        Box::pin(async move {
            let _guard = guard;
            let _ = started.unwrap().send(());
            std::future::pending().await
        })
    });
    manager
        .spawn_in_process_agent("pending".into(), None, "Pending".into(), run)
        .unwrap();
    ready.await.unwrap();
    drop(manager);
    tokio::time::timeout(Duration::from_secs(5), receiver)
        .await
        .unwrap()
        .unwrap();
    assert_process_stopped(identifier).await;
}
#[tokio::test]
async fn shell_result_is_bounded_but_transcript_keeps_full_output() {
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let mut completions = manager.completions();
    let task = manager
        .run_shell_command(
            command(
                "head -c 400000 /dev/zero | tr '\\0' x",
                "[Console]::Write('x' * 400000)",
            ),
            None,
        )
        .await
        .unwrap();
    let completed = completion(&mut completions).await;
    let result = completed.result.unwrap();
    assert!(result.contains("Result capped at 256 KiB"));
    assert!(result.len() < 263000);
    assert!(manager.transcript(task.id).await.len() >= 400000);
}
#[cfg(windows)]
#[tokio::test]
async fn cmd_shim_preserves_literal_arguments_without_command_injection() {
    let directory = TempDir::new().unwrap();
    let shim = directory.path().join("fake cli.cmd");
    let script = directory.path().join("echo.ps1");
    std::fs::write(&script, "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); [Console]::Write((ConvertTo-Json -InputObject $args -Compress))").unwrap();
    std::fs::write(&shim, "@echo off\r\npowershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"%~dp0echo.ps1\" %*\r\n").unwrap();
    let arguments = vec![
        "a space".into(),
        "quotes \"and\" backslash\\".into(),
        "& echo injected > escaped.txt".into(),
        "%PATH% !VAR! ^ (x)".into(),
        "first\nsecond".into(),
    ];
    let result = HeadlessProcess::run(
        &shim,
        &arguments,
        directory.path(),
        &AgentExecutableResolver::environment(),
        Duration::from_secs(15),
        256 * 1024,
    )
    .await
    .unwrap();
    assert_eq!(
        result.exit_code,
        0,
        "{}",
        String::from_utf8_lossy(&result.output)
    );
    let echoed: Vec<String> = serde_json::from_slice(&result.output).unwrap();
    assert_eq!(echoed, arguments);
    assert!(!directory.path().join("escaped.txt").exists());
}
#[tokio::test]
#[ignore = "Spends the signed-in user's Codex CLI quota; set AMBIENT_RUN_LIVE_AGENTS=1 and run ignored tests explicitly."]
async fn live_codex_spawn_and_resume() {
    live_agent(Kind::CodexAgent, true).await;
}
#[tokio::test]
#[ignore = "Spends the signed-in user's Claude CLI quota; set AMBIENT_RUN_LIVE_AGENTS=1 and run ignored tests explicitly."]
async fn live_claude_spawn() {
    live_agent(Kind::ClaudeAgent, false).await;
}
async fn live_agent(kind: Kind, resume: bool) {
    assert_eq!(std::env::var("AMBIENT_RUN_LIVE_AGENTS").as_deref(), Ok("1"));
    let directory = TempDir::new().unwrap();
    let manager = manager(directory.path());
    let mut completed = manager.completions();
    let task = manager
        .spawn_agent(
            kind,
            "Create hello.txt containing the word ok, then reply done. Do not use subagents."
                .into(),
            Some(directory.path().to_string_lossy().into()),
            "Live CLI verification".into(),
            None,
        )
        .await
        .unwrap();
    let finished = tokio::time::timeout(Duration::from_secs(120), completed.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(finished.status, Status::Succeeded, "{:?}", finished.result);
    assert!(finished.result.unwrap().to_lowercase().contains("done"));
    assert_eq!(
        std::fs::read_to_string(directory.path().join("hello.txt"))
            .unwrap()
            .trim(),
        "ok"
    );
    if resume {
        let relaunched = self::manager(directory.path());
        let mut completed = relaunched.completions();
        let continued = relaunched.continue_agent(task.id, "Read hello.txt, create continued.txt containing the same word, then reply resumed. Do not use subagents.".into()).await.unwrap();
        assert_eq!(continued.id, task.id);
        let finished = tokio::time::timeout(Duration::from_secs(120), completed.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(finished.status, Status::Succeeded, "{:?}", finished.result);
        assert_eq!(
            std::fs::read_to_string(directory.path().join("continued.txt"))
                .unwrap()
                .trim(),
            "ok"
        );
    }
}

#[tokio::test]
async fn null_process_arguments_are_rejected_before_launch() {
    let directory = TempDir::new().unwrap();
    let (executable, arguments) = shell("not a command\0and must not execute");
    let result = HeadlessProcess::run(
        &executable,
        &arguments,
        directory.path(),
        &AgentExecutableResolver::environment(),
        Duration::from_secs(1),
        256 * 1024,
    )
    .await;
    assert!(result.unwrap_err().contains("null byte"));
}
#[cfg(any(windows, target_os = "macos"))]
#[tokio::test]
async fn workspace_confinement_setup_failure_never_runs_the_command() {
    let directory = TempDir::new().unwrap();
    let missing_directory = directory.path().join("does-not-exist");
    let sentinel = directory.path().join("must-not-exist.txt");
    let provider = AgentWorkspaceToolProvider::new(missing_directory);
    let shell = provider.tools().await.remove(0);
    let sentinel_path = sentinel.to_string_lossy().replace('\'', "''");
    let command = command(
        &format!("echo escaped > '{sentinel_path}'"),
        &format!("Set-Content -LiteralPath '{sentinel_path}' -Value escaped"),
    );
    let result = shell.run(json!({"command":command})).await;
    assert!(result.is_error);
    assert!(!sentinel.exists());
}
