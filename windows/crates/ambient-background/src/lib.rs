mod agent_event_parser;
mod headless_process;
mod task_manager;
mod tool_provider;
mod workspace_tool;

pub use agent_event_parser::{AgentEventParser, ParsedAgentEvent};
pub use headless_process::{AgentExecutableResolver, HeadlessProcess, HeadlessProcessEvent, HeadlessProcessResult};
pub use task_manager::{BackgroundTaskManager, InProcessAgent};
pub use tool_provider::{Approval, BackgroundApprovalSettings, BackgroundToolProvider};
pub use workspace_tool::AgentWorkspaceToolProvider;

use std::path::{Path, PathBuf};

pub type BackgroundExecutionError = String;

pub(crate) fn home_directory() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from).unwrap_or_default()
}

pub(crate) fn expanded_path(path: &str) -> PathBuf {
    if path == "~" { home_directory() }
    else if let Some(relative) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        home_directory().join(relative)
    } else { PathBuf::from(path) }
}

pub(crate) fn create_private_directory(path: &Path) -> Result<(), String> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)] {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path).map_err(|error| error.to_string())
}

pub(crate) fn private_append(path: &Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)] {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|error| error.to_string())?;
    writeln!(file, "{text}").map_err(|error| error.to_string())
}

pub(crate) fn private_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut temporary = tempfile::NamedTempFile::new_in(path.parent().ok_or("Missing parent directory.")?)
        .map_err(|error| error.to_string())?;
    temporary.write_all(bytes).and_then(|_| temporary.as_file().sync_all()).map_err(|error| error.to_string())?;
    temporary.persist(path).map_err(|error| error.error.to_string())?;
    Ok(())
}

pub(crate) fn tail(text: &str, limit: usize) -> String {
    text.chars().skip(text.chars().count().saturating_sub(limit)).collect()
}
