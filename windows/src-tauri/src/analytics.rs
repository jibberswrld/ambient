//! Anonymous funnel only: no account, request, screen or filesystem data enters an event.
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

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

    pub fn command_completed(&self, input: Input, ok: bool) {
        self.capture("ambient_command", json!({ "input": input, "ok": ok }));
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

    fn capture(&self, event: &'static str, mut properties: Value) {
        if !sending_allowed() {
            return;
        }
        let Some(client) = self.client.clone() else {
            return;
        };
        {
            let state = self.install.lock().unwrap();
            let Some(install) = state.as_ref().filter(|install| install.enabled) else {
                return;
            };
            properties["distinct_id"] = json!(install.distinct_id);
        }
        properties["platform"] = json!("windows");
        properties["app_version"] = json!(env!("CARGO_PKG_VERSION"));
        let analytics = self.clone();
        let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        tauri::async_runtime::spawn(async move {
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
        });
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
