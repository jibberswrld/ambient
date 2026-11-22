use std::{
    collections::HashMap,
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::mpsc;
#[cfg(windows)]
#[path = "windows_process.rs"]
mod platform;

// Parse only npm's quoted, shim-relative entry point followed by literal argument forwarding.
// Keeping this independent of filesystem/Windows APIs lets every platform test real shim samples.
#[cfg(any(windows, test))]
fn npm_shim_entry(shim: &str) -> Option<String> {
    for line in shim.lines() {
        let Some(invocation) = line.trim().strip_suffix("%*") else {
            continue;
        };
        let Some(before_closing_quote) = invocation.trim_end().strip_suffix('"') else {
            continue;
        };
        let Some((launcher, entry)) = before_closing_quote.rsplit_once('"') else {
            continue;
        };
        let lowercase_entry = entry.to_ascii_lowercase();
        let prefix_length = if lowercase_entry.starts_with("%dp0%") {
            5
        } else if lowercase_entry.starts_with("%~dp0") {
            5
        } else {
            continue;
        };
        let relative = entry[prefix_length..].trim_start_matches(['\\', '/']);
        if relative.is_empty() || relative.contains(['%', '\0', ':']) {
            continue;
        }
        let launcher = launcher.trim_end().to_ascii_lowercase();
        let is_executable = lowercase_entry.ends_with(".exe");
        let is_javascript = [".js", ".cjs", ".mjs"]
            .iter()
            .any(|extension| lowercase_entry.ends_with(extension));
        let node_launcher = launcher.ends_with("\"%_prog%\"")
            || launcher.ends_with("\"%~dp0\\node.exe\"")
            || launcher.ends_with("\"%~dp0node.exe\"")
            || launcher.ends_with("\"%dp0%\\node.exe\"")
            || launcher.trim_start_matches('@').trim() == "node"
            || launcher.trim_start_matches('@').trim() == "node.exe";
        if (is_javascript && node_launcher)
            || (is_executable && (node_launcher || launcher.trim_start_matches('@').is_empty()))
        {
            return Some(relative.into());
        }
    }
    None
}

#[derive(Debug, Clone)]
pub struct HeadlessProcessResult {
    pub exit_code: i32,
    pub output: Vec<u8>,
    pub timed_out: bool,
    pub output_was_truncated: bool,
}
#[derive(Debug)]
pub enum HeadlessProcessEvent {
    Output {
        data: Vec<u8>,
        is_standard_error: bool,
    },
    Finished(HeadlessProcessResult),
}
pub struct HeadlessProcess {
    pub events: mpsc::UnboundedReceiver<HeadlessProcessEvent>,
    pub process_identifier: u32,
    pub(crate) control: Arc<ProcessControl>,
}
pub(crate) struct ProcessControl {
    state: Mutex<ProcessState>,
    #[cfg(unix)]
    identifier: i32,
    #[cfg(windows)]
    job: platform::Job,
}
#[derive(Default)]
struct ProcessState {
    finished: bool,
    timed_out: bool,
}
impl ProcessControl {
    pub(crate) fn terminate(&self, timed_out: bool) {
        let mut state = self.state.lock().unwrap();
        if state.finished {
            return;
        }
        state.timed_out |= timed_out;
        self.kill_tree();
    }
    fn kill_tree(&self) {
        #[cfg(unix)]
        unsafe {
            libc::kill(-self.identifier, libc::SIGKILL);
        }
        #[cfg(windows)]
        self.job.terminate();
    }
}
impl Drop for HeadlessProcess {
    fn drop(&mut self) {
        self.control.terminate(false);
    }
}
impl HeadlessProcess {
    pub fn new(
        executable: &Path,
        arguments: &[String],
        directory: &Path,
        environment: &HashMap<String, String>,
        timeout: Option<Duration>,
        output_limit: usize,
    ) -> Result<Self, String> {
        Self::spawn(
            executable,
            arguments,
            directory,
            environment,
            timeout,
            output_limit,
            false,
        )
    }
    pub(crate) fn spawn(
        executable: &Path,
        arguments: &[String],
        directory: &Path,
        environment: &HashMap<String, String>,
        timeout: Option<Duration>,
        output_limit: usize,
        low_integrity: bool,
    ) -> Result<Self, String> {
        if arguments.iter().any(|argument| argument.contains('\0'))
            || environment
                .iter()
                .any(|(key, value)| key.contains('\0') || value.contains('\0'))
        {
            return Err("Process arguments and environment must not contain a null byte.".into());
        }
        #[cfg(windows)]
        let (identifier, control, stdout, stderr, wait) =
            platform::spawn(executable, arguments, directory, environment, low_integrity)?;
        #[cfg(unix)]
        let (identifier, control, stdout, stderr, wait) = {
            use std::os::unix::process::CommandExt;
            use std::process::{Command, Stdio};
            if low_integrity {
                return Err("Low integrity processes are only supported on Windows.".into());
            }
            let mut child = Command::new(executable)
                .args(arguments)
                .current_dir(directory)
                .env_clear()
                .envs(environment)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .process_group(0)
                .spawn()
                .map_err(|error| error.to_string())?;
            let identifier = child.id();
            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();
            let control = Arc::new(ProcessControl {
                state: Mutex::new(ProcessState::default()),
                identifier: identifier as i32,
            });
            let wait = move || {
                let mut child = child;
                use std::os::unix::process::ExitStatusExt;
                child
                    .wait()
                    .map(|status| {
                        status
                            .code()
                            .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
                    })
                    .unwrap_or(-1)
            };
            (identifier, control, stdout, stderr, wait)
        };
        let (sender, events) = mpsc::unbounded_channel();
        let captured = Arc::new(Mutex::new((Vec::new(), false)));
        fn read_output(
            mut reader: impl Read + Send + 'static,
            is_standard_error: bool,
            sender: mpsc::UnboundedSender<HeadlessProcessEvent>,
            captured: Arc<Mutex<(Vec<u8>, bool)>>,
            limit: usize,
        ) -> std::thread::JoinHandle<()> {
            std::thread::spawn(move || {
                let mut buffer = [0u8; 8192];
                loop {
                    let count = match reader.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(count) => count,
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    };
                    {
                        let mut captured = captured.lock().unwrap();
                        let remaining = limit.saturating_sub(captured.0.len());
                        captured
                            .0
                            .extend_from_slice(&buffer[..count.min(remaining)]);
                        captured.1 |= count > remaining;
                    }
                    let _ = sender.send(HeadlessProcessEvent::Output {
                        data: buffer[..count].to_vec(),
                        is_standard_error,
                    });
                }
            })
        }
        let stdout_reader = read_output(
            stdout,
            false,
            sender.clone(),
            captured.clone(),
            output_limit,
        );
        let stderr_reader =
            read_output(stderr, true, sender.clone(), captured.clone(), output_limit);
        let wait_control = control.clone();
        std::thread::spawn(move || {
            let exit_code = wait();
            let timed_out = {
                let mut state = wait_control.state.lock().unwrap();
                state.finished = true;
                // A shell can exit leaving descendants holding its output pipes.
                wait_control.kill_tree();
                state.timed_out
            };
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            let (output, output_was_truncated) = captured.lock().unwrap().clone();
            let _ = sender.send(HeadlessProcessEvent::Finished(HeadlessProcessResult {
                exit_code,
                output,
                timed_out,
                output_was_truncated,
            }));
        });
        if let Some(timeout) = timeout {
            let weak_control = Arc::downgrade(&control);
            tokio::spawn(async move {
                tokio::time::sleep(timeout).await;
                if let Some(control) = weak_control.upgrade() {
                    control.terminate(true);
                }
            });
        }
        Ok(Self {
            events,
            process_identifier: identifier,
            control,
        })
    }
    pub fn terminate(&self) {
        self.control.terminate(false);
    }
    pub async fn run(
        executable: &Path,
        arguments: &[String],
        directory: &Path,
        environment: &HashMap<String, String>,
        timeout: Duration,
        output_limit: usize,
    ) -> Result<HeadlessProcessResult, String> {
        Self::run_confined(
            executable,
            arguments,
            directory,
            environment,
            timeout,
            output_limit,
            false,
        )
        .await
    }
    pub(crate) async fn run_confined(
        executable: &Path,
        arguments: &[String],
        directory: &Path,
        environment: &HashMap<String, String>,
        timeout: Duration,
        output_limit: usize,
        low_integrity: bool,
    ) -> Result<HeadlessProcessResult, String> {
        let mut process = Self::spawn(
            executable,
            arguments,
            directory,
            environment,
            Some(timeout),
            output_limit,
            low_integrity,
        )?;
        while let Some(event) = process.events.recv().await {
            if let HeadlessProcessEvent::Finished(result) = event {
                return Ok(result);
            }
        }
        Err("Cancelled.".into())
    }
}
pub struct AgentExecutableResolver;
impl AgentExecutableResolver {
    pub fn environment() -> HashMap<String, String> {
        #[cfg(windows)]
        let mut environment: HashMap<_, _> = std::env::vars()
            .map(|(key, value)| (key.to_ascii_uppercase(), value))
            .collect();
        #[cfg(not(windows))]
        let mut environment: HashMap<_, _> = std::env::vars().collect();
        #[cfg(not(windows))]
        {
            let home = crate::home_directory();
            let mut paths = vec![
                home.join(".local/bin"),
                home.join(".npm-global/bin"),
                PathBuf::from("/opt/homebrew/bin"),
                PathBuf::from("/usr/local/bin"),
                PathBuf::from("/usr/bin"),
                PathBuf::from("/bin"),
                PathBuf::from("/usr/sbin"),
                PathBuf::from("/sbin"),
            ];
            if let Some(path) = environment.get("PATH") {
                paths.extend(std::env::split_paths(path));
            }
            let mut unique = Vec::new();
            for path in paths {
                if !path.as_os_str().is_empty() && !unique.contains(&path) {
                    unique.push(path);
                }
            }
            if let Ok(paths) = std::env::join_paths(unique) {
                environment.insert("PATH".into(), paths.to_string_lossy().into_owned());
            }
        }
        #[cfg(windows)]
        {
            if let Some(npm_directory) = std::env::var_os("APPDATA")
                .map(PathBuf::from)
                .map(|path| path.join("npm"))
            {
                let mut paths: Vec<_> = environment
                    .get("PATH")
                    .map(|path| std::env::split_paths(path).collect())
                    .unwrap_or_default();
                if !paths.contains(&npm_directory) {
                    paths.push(npm_directory);
                }
                if let Ok(paths) = std::env::join_paths(paths) {
                    environment.insert("PATH".into(), paths.to_string_lossy().into_owned());
                }
            }
        }
        environment.insert("TERM".into(), "dumb".into());
        environment.insert("NO_COLOR".into(), "1".into());
        environment.retain(|key, _| !key.eq_ignore_ascii_case("CLAUDECODE"));
        environment
    }
    pub async fn resolve(name: &str) -> Result<(PathBuf, HashMap<String, String>), String> {
        if name != "codex" && name != "claude" {
            return Err("Choose codex or claude for an agent.".into());
        }
        #[allow(unused_mut)]
        let mut environment = Self::environment();
        let common_candidate =
            which::which_in(name, environment.get("PATH"), crate::home_directory()).ok();
        #[cfg(not(windows))]
        {
            let shell = std::env::var_os("SHELL")
                .map(PathBuf::from)
                .unwrap_or_else(|| shell_command("").0);
            let lookup = format!("printf '\\nAMBIENT_EXECUTABLE='; command -v {name}; printf '\\nAMBIENT_PATH=%s\\n' \"$PATH\"");
            if let Ok(result) = HeadlessProcess::run(
                &shell,
                &["-lc".into(), lookup],
                &crate::home_directory(),
                &environment,
                Duration::from_secs(5),
                32 * 1024,
            )
            .await
            {
                let output = String::from_utf8_lossy(&result.output);
                if let Some(path) = output
                    .lines()
                    .find_map(|line| line.strip_prefix("AMBIENT_PATH="))
                {
                    environment.insert(
                        "PATH".into(),
                        format!(
                            "{path}:{}",
                            environment.get("PATH").map(String::as_str).unwrap_or("")
                        ),
                    );
                }
                if let Some(candidate) = common_candidate {
                    return Ok((candidate, environment));
                }
                if let Some(candidate) = output
                    .lines()
                    .find_map(|line| line.strip_prefix("AMBIENT_EXECUTABLE=/"))
                {
                    let candidate = PathBuf::from(format!("/{candidate}"));
                    if which::which(&candidate).is_ok() {
                        return Ok((candidate, environment));
                    }
                }
            }
        }
        if let Some(candidate) = common_candidate {
            return Ok((candidate, environment));
        }
        Err(format!("{} is not installed or could not be found. Install it and sign in before starting an agent.", if name == "codex" { "Codex CLI" } else { "Claude Code CLI" }))
    }
}
pub(crate) fn shell_command(command: &str) -> (PathBuf, Vec<String>) {
    #[cfg(windows)]
    {
        (
            PathBuf::from("powershell.exe"),
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
    }
    #[cfg(not(windows))]
    {
        (
            PathBuf::from(if Path::new("/bin/zsh").exists() {
                "/bin/zsh"
            } else {
                "/bin/sh"
            }),
            vec!["-c".into(), command.into()],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::npm_shim_entry;

    #[test]
    fn parses_modern_npm_cmd_shim() {
        let shim = r#"@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0
IF EXIST "%dp0%\node.exe" (
  SET "_prog=%dp0%\node.exe"
) ELSE (
  SET "_prog=node"
)
endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & set PATHEXT=%PATHEXT:;.JS;=;% & "%_prog%"  "%dp0%\node_modules\@openai\codex\bin\codex.js" %*
"#;
        assert_eq!(
            npm_shim_entry(&shim.replace('\n', "\r\n")).as_deref(),
            Some(r"node_modules\@openai\codex\bin\codex.js")
        );
    }

    #[test]
    fn parses_older_npm_cmd_shim() {
        let shim = r#"@IF EXIST "%~dp0\node.exe" (
  "%~dp0\node.exe" "%~dp0\node_modules\@anthropic-ai\claude-code\cli.js" %*
) ELSE (
  @SETLOCAL
  @SET PATHEXT=%PATHEXT:;.JS;=;%
  node "%~dp0\node_modules\@anthropic-ai\claude-code\cli.js" %*
)
"#;
        assert_eq!(
            npm_shim_entry(shim).as_deref(),
            Some(r"node_modules\@anthropic-ai\claude-code\cli.js")
        );
        assert_eq!(
            npm_shim_entry(r#"node "%~dp0node_modules\cli.cjs" %*"#).as_deref(),
            Some(r"node_modules\cli.cjs")
        );
    }

    #[test]
    fn parses_native_npm_cmd_shim() {
        for prefix in ["%dp0%\\", "%~dp0"] {
            let shim = format!("@ECHO off\r\n\"{prefix}node_modules\\cli\\bin.exe\" %*\r\n");
            assert_eq!(
                npm_shim_entry(&shim).as_deref(),
                Some(r"node_modules\cli\bin.exe")
            );
        }
    }

    #[test]
    fn unrecognized_shims_do_not_guess_an_entry_point() {
        for shim in [
            "@echo off\r\necho %*",
            r#"powershell.exe "%~dp0echo.ps1" %*"#,
            r#"node --custom-flag "%~dp0cli.js" %*"#,
            r#"node "%~dp0%OTHER%\cli.js" %*"#,
            r#"node "%~dp0cli.js" %* & echo something-else"#,
        ] {
            assert_eq!(npm_shim_entry(shim), None, "{shim}");
        }
    }
}
