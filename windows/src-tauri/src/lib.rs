//! Ambient for Windows: the Tauri shell. It composes the subsystem crates, runs the one agent pipeline (`core`),
//! and implements the interface's host contract (`commands`). The Mac app's equivalents are `Ambient/*.swift`.
mod analytics;
mod commands;
mod core;
mod focus;
mod screen_tools;
mod settings;
mod updates;
mod windows;

use std::io::Write;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use ambient_agent::publik;
use ambient_contracts::{AgentFailure, BackgroundTaskStore};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager, RunEvent};
use tauri_plugin_deep_link::DeepLinkExt;

use crate::core::{automation_text, Runtime, Shell, WindowGate};

pub struct AppState {
    pub shell: Arc<Shell>,
    runtime: OnceLock<Arc<Runtime>>,
}

impl AppState {
    /// The runtime exists unless Ambient's own files could not be opened at launch.
    pub fn runtime(&self) -> Result<Arc<Runtime>, String> {
        self.runtime.get().cloned().ok_or_else(|| "Ambient could not start.".to_string())
    }
}

/// One line to stderr and to `ambient.log` in the data directory. These lines contain conversation text and stay on
/// this computer; never pass credentials or raw tool payloads.
pub fn log_line(message: &str) {
    let line = format!("{} Ambient {message}", chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"));
    eprintln!("{line}");
    let log_path = ambient_contracts::ambient_data_directory().join("ambient.log");
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(log_path) {
        let _ = writeln!(file, "{line}");
    }
}

/// The log starts again when it has grown past a megabyte, so it never fills the disk.
fn start_log() {
    let data_directory = ambient_contracts::ambient_data_directory();
    let _ = std::fs::create_dir_all(&data_directory);
    let log_path = data_directory.join("ambient.log");
    if std::fs::metadata(&log_path).is_ok_and(|metadata| metadata.len() > 1_000_000) {
        let _ = std::fs::remove_file(&log_path);
    }
}

/// `ambient://ask?text=...` links from the command line, a second launch, or the system.
fn handle_links(app: &AppHandle, links: impl IntoIterator<Item = String>) {
    let state = app.state::<AppState>();
    let Ok(runtime) = state.runtime() else { return };
    for link in links {
        if let Some(text) = automation_text(&link) {
            runtime.submit_text(text);
        }
    }
}

/// Sends every change of a store's list to the windows, for as long as the store lives.
fn forward_updates<Item: serde::Serialize + Clone + Send + Sync + 'static>(shell: Arc<Shell>, event_name: &'static str, mut updates: tokio::sync::watch::Receiver<Vec<Item>>) {
    tauri::async_runtime::spawn(async move {
        while updates.changed().await.is_ok() {
            let items = updates.borrow_and_update().clone();
            shell.emit(event_name, items);
        }
    });
}

async fn start_runtime(app: AppHandle, shell: Arc<Shell>, runtime: Arc<Runtime>) {
    // Subscribed before sign-in can enable any tools, so even short tasks surface.
    let mut completions = runtime.background_tasks.completions();
    tauri::async_runtime::spawn(async move {
        while let Some(task) = completions.recv().await {
            log_line(&format!("background completion: {} — {:?}", task.title, task.status));
        }
    });
    forward_updates(shell.clone(), "ambient:background-tasks", runtime.background_tasks.updates());
    forward_updates(shell.clone(), "ambient:memory-items", runtime.memory.updates());
    forward_updates(shell.clone(), "ambient:skills", runtime.skills.updates());

    // A request on the command line waits for sign-in like any other.
    handle_links(&app, std::env::args().skip(1));

    let gate_shell = shell.clone();
    let signed_in = tauri::async_runtime::spawn_blocking(move || {
        publik::ensure_signed_in(&mut WindowGate { shell: gate_shell });
    })
    .await;
    if signed_in.is_err() || runtime.credential_source.credential().await.is_none() {
        runtime.report_failure(AgentFailure::NotSignedIn);
        return;
    }
    shell.analytics.reached(analytics::Step::SignedIn);
    *shell.gate_screen.lock().unwrap() = None;
    *shell.gate_answers.lock().unwrap() = None;
    shell.emit("ambient:gate-screen", Value::Null);

    shell.refresh_microphone_access().await;
    runtime.start_shortcut_monitor();
    if !runtime.settings.read().onboarding_completed || !shell.is_microphone_usable() {
        // With no gate screen to draw, the onboarding window shows the permissions step.
        shell.analytics.reached(analytics::Step::PermissionsShown);
        windows::show_onboarding(&app);
        let (watching_app, watching_shell) = (app.clone(), shell.clone());
        tauri::async_runtime::spawn(async move {
            // Only while the step is open and the microphone is refused: each check opens the microphone briefly.
            while watching_app.get_webview_window("onboarding").is_some() && !watching_shell.is_microphone_usable() {
                tokio::time::sleep(Duration::from_millis(1500)).await;
                watching_shell.refresh_microphone_access().await;
            }
        });
    } else {
        windows::close_onboarding(&app);
    }
    shell.show_bar();
    runtime.became_ready();
    updates::check_daily(app);
}

fn start(app: &AppHandle) {
    start_log();
    let shell = Shell::new(app.clone());
    shell.analytics.launched();
    app.manage(AppState { shell: shell.clone(), runtime: OnceLock::new() });
    if let Err(error) = windows::build_tray(app) {
        log_line(&format!("the tray icon could not be created: {error}"));
    }
    windows::create_bar(app);
    windows::create_overlay(app);
    match Runtime::new(shell.clone()) {
        Ok(runtime) => {
            let _ = app.state::<AppState>().runtime.set(runtime.clone());
            let link_app = app.clone();
            app.deep_link().on_open_url(move |event| handle_links(&link_app, event.urls().into_iter().map(|url| url.to_string())));
            tauri::async_runtime::spawn(start_runtime(app.clone(), shell, runtime));
        }
        Err(message) => {
            // Ambient's own files could not be opened. Say so and offer the only thing left to do.
            log_line(&format!("could not start: {message}"));
            *shell.gate_screen.lock().unwrap() = Some(json!({
                "id": "could_not_start", "title": "Ambient could not start", "body": message, "note": null, "isWaiting": false,
                "buttons": [{ "action": "quit", "label": "Quit Ambient", "prominence": "primary" }]
            }));
            windows::show_onboarding(app);
        }
    }
}

pub fn run() {
    #[cfg(debug_assertions)]
    if std::env::args().any(|argument| argument == "--analytics-smoke-test") {
        // Run the real capture client without windows, microphone access or sound.
        let analytics = analytics::Analytics::new();
        analytics.launched();
        analytics.launched();
        tauri::async_runtime::block_on(async { tokio::time::sleep(Duration::from_secs(7)).await });
        return;
    }
    let app = tauri::Builder::default()
        // A second launch (or a link opened while running) hands its arguments to the running app and exits.
        .plugin(tauri_plugin_single_instance::init(|app, arguments, _working_directory| handle_links(app, arguments)))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .invoke_handler(tauri::generate_handler![
            commands::get_runtime_phase, commands::submit_text, commands::cancel_turn,
            commands::get_pending_approval, commands::answer_approval,
            commands::get_background_tasks, commands::cancel_background_task, commands::dismiss_background_task, commands::get_background_task_transcript,
            commands::get_memory_items, commands::add_memory, commands::delete_memory, commands::get_automatic_learning_enabled, commands::set_automatic_learning_enabled,
            commands::get_skills, commands::install_skill_from_folder, commands::delete_skill,
            commands::get_connector_apps, commands::authorize_connector, commands::disconnect_connector,
            commands::get_general_settings, commands::set_general_settings, commands::get_bar_placement, commands::set_bar_placement,
            commands::get_account_summary, commands::get_settings_navigation,
            commands::get_permission_statuses, commands::request_microphone_permission, commands::open_microphone_settings, commands::finish_permissions_step,
            commands::get_onboarding_completed, commands::set_onboarding_completed, commands::get_gate_screen, commands::answer_gate,
            commands::open_settings, commands::open_url, commands::check_for_updates, commands::quit, commands::show_bar, commands::hide_bar,
            commands::start_tour, commands::end_tour, commands::clear_drawing, commands::save_text_file,
            commands::set_window_frame, commands::set_bar_accepts_keyboard, commands::get_overlay_drawing, commands::overlay_content_changed,
        ])
        .setup(|app| {
            start(app.handle());
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Ambient could not start its window system.");
    app.run(|app, event| match event {
        // Closing Settings or onboarding must not end Ambient: it lives in the tray. Only Quit ends it.
        RunEvent::ExitRequested { api, code, .. } if code.is_none() => api.prevent_exit(),
        RunEvent::Exit => {
            if let Ok(runtime) = app.state::<AppState>().runtime() {
                runtime.stop();
            }
        }
        _ => {}
    });
}
