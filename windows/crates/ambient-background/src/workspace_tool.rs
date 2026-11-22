use crate::{AgentEventParser, AgentExecutableResolver, HeadlessProcess};
use ambient_contracts::{AmbientTool, ToolDefinition, ToolProvider, ToolResult};
use async_trait::async_trait;
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

pub struct AgentWorkspaceToolProvider {
    working_directory: PathBuf,
}
impl AgentWorkspaceToolProvider {
    pub fn new(working_directory: PathBuf) -> Self {
        Self { working_directory }
    }
}
#[async_trait]
impl ToolProvider for AgentWorkspaceToolProvider {
    async fn tools(&self) -> Vec<Arc<dyn AmbientTool>> {
        vec![Arc::new(AgentShellTool {
            working_directory: self.working_directory.clone(),
        })]
    }
    async fn system_prompt_section(&self) -> Option<String> {
        let shell = if cfg!(windows) { "PowerShell" } else { "zsh" };
        let computer = if cfg!(windows) { "PC" } else { "Mac" };
        let edit_method = if cfg!(windows) {
            "a here-string"
        } else {
            "a heredoc"
        };
        let denied = if cfg!(windows) {
            "access denied"
        } else {
            "operation not permitted"
        };
        Some(format!("Your working directory is {}. run_shell_command runs {shell} there. Use it to read\nand search files, write them ({edit_method} or a short script works well for edits), and run builds, tests\nand git. Commands can read the whole {computer} and use the network, and can write only inside the working\ndirectory and temporary folders; a write anywhere else fails with \"{denied}\", which is\nnot something to work around. Each command is limited to five minutes and 256 KiB of output.", self.working_directory.display()))
    }
}
struct AgentShellTool {
    working_directory: PathBuf,
}
#[async_trait]
impl AmbientTool for AgentShellTool {
    fn definition(&self) -> ToolDefinition {
        let shell = if cfg!(windows) { "PowerShell" } else { "zsh" };
        ToolDefinition { name: "run_shell_command".into(), description: format!("Run a {shell} command in the working directory and return its combined output and exit code."),
            parameters_json_schema: json!({"type":"object","properties":{"command":{"type":"string","description":format!("The exact {shell} command to execute.")}},"required":["command"],"additionalProperties":false}) }
    }
    fn activity_label(&self, arguments: &Value) -> Option<String> {
        arguments["command"]
            .as_str()
            .map(|command| format!("Running {}", AgentEventParser::single_line(command)))
    }
    async fn run(&self, arguments: Value) -> ToolResult {
        let Some(command) = arguments["command"]
            .as_str()
            .filter(|command| !command.is_empty() && !command.contains('\0'))
        else {
            return ToolResult::error("command must be a nonempty string.");
        };
        let result = run_workspace_command(&self.working_directory, command).await;
        match result {
            Ok(result) => {
                let mut content = String::from_utf8_lossy(&result.output).into_owned();
                if result.output_was_truncated {
                    content.push_str("\n[Output capped at 256 KiB.]");
                }
                if result.timed_out {
                    content.push_str(if cfg!(windows) {
                        "\n[Timed out after five minutes; the process tree was killed.]"
                    } else {
                        "\n[Timed out after five minutes; the process group was killed.]"
                    });
                }
                content.push_str(&format!("\n[Exit code: {}]", result.exit_code));
                ToolResult {
                    content,
                    is_error: result.exit_code != 0 || result.timed_out,
                    images: vec![],
                }
            }
            Err(error) => ToolResult::error(error),
        }
    }
}
async fn run_workspace_command(
    directory: &Path,
    command: &str,
) -> Result<crate::HeadlessProcessResult, String> {
    let environment = AgentExecutableResolver::environment();
    #[cfg(windows)]
    {
        let canonical_directory =
            std::fs::canonicalize(directory).map_err(|error| error.to_string())?;
        let canonical_home =
            std::fs::canonicalize(crate::home_directory()).map_err(|error| error.to_string())?;
        if canonical_directory.parent().is_none()
            || canonical_home.starts_with(&canonical_directory)
        {
            return Err("The confined working directory must not be the user profile or one of its parent directories.".into());
        }
        let temporary_directory = tempfile::Builder::new()
            .prefix("ambient-agent-")
            .tempdir()
            .map_err(|error| error.to_string())?;
        for writable_directory in [directory, temporary_directory.path()] {
            let arguments = vec![
                writable_directory.to_string_lossy().into_owned(),
                "/setintegritylevel".into(),
                "(OI)(CI)Low".into(),
                "/T".into(),
                "/Q".into(),
                "/L".into(),
            ];
            let result = HeadlessProcess::run(
                Path::new("icacls.exe"),
                &arguments,
                directory,
                &environment,
                Duration::from_secs(30),
                256 * 1024,
            )
            .await?;
            if result.exit_code != 0 || result.timed_out {
                return Err(format!(
                    "Could not confine the agent workspace: {}",
                    String::from_utf8_lossy(&result.output)
                ));
            }
        }
        let mut environment = environment;
        environment
            .retain(|key, _| !key.eq_ignore_ascii_case("TEMP") && !key.eq_ignore_ascii_case("TMP"));
        environment.insert(
            "TEMP".into(),
            temporary_directory.path().to_string_lossy().into_owned(),
        );
        environment.insert(
            "TMP".into(),
            temporary_directory.path().to_string_lossy().into_owned(),
        );
        // PowerShell normally treats file-write errors as non-terminating; surface them as failures.
        let (executable, arguments) = crate::headless_process::shell_command(&format!(
            "$ErrorActionPreference = 'Stop'; {command}"
        ));
        HeadlessProcess::run_confined(
            &executable,
            &arguments,
            directory,
            &environment,
            Duration::from_secs(300),
            256 * 1024,
            true,
        )
        .await
    }
    #[cfg(target_os = "macos")]
    {
        HeadlessProcess::run(
            Path::new("/usr/bin/sandbox-exec"),
            &[
                "-p".into(),
                sandbox_profile(directory)?,
                "/bin/zsh".into(),
                "-c".into(),
                command.into(),
            ],
            directory,
            &environment,
            Duration::from_secs(300),
            256 * 1024,
        )
        .await
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = (directory, command, environment);
        Err("Workspace confinement is not available on this operating system.".into())
    }
}
#[cfg(target_os = "macos")]
fn sandbox_profile(working_directory: &Path) -> Result<String, String> {
    let home = std::fs::canonicalize(crate::home_directory()).map_err(|error| error.to_string())?;
    let directory = std::fs::canonicalize(working_directory).map_err(|error| error.to_string())?;
    fn quoted(path: &Path) -> String {
        format!(
            "\"{}\"",
            path.to_string_lossy()
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
        )
    }
    let writable = [
        directory,
        home.join("Library/Caches"),
        home.join(".cache"),
        home.join(".npm"),
    ];
    Ok(format!(
        "(version 1)(allow default)(deny file-write* (subpath {}))(allow file-write* {})",
        quoted(&home),
        writable
            .iter()
            .map(|path| format!("(subpath {})", quoted(path)))
            .collect::<String>()
    ))
}
