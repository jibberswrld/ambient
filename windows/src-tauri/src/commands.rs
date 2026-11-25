//! Every command of the host contract (`windows/src/host/contract.ts`). Names and shapes must match that file exactly.
use std::sync::atomic::Ordering;

use ambient_contracts::{BackgroundTask, BackgroundTaskStore, ConnectorApp, ConnectorService, MemoryItem, SkillSummary};
use ambient_platform::push_to_talk::PushToTalkShortcut;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager, State, WebviewWindow};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;
use uuid::Uuid;

use crate::core::ApprovalRequest;
use crate::screen_tools::ScreenOverlay;
use crate::{windows, AppState};

type CommandResult<T> = Result<T, String>;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneralSettings {
    push_to_talk_shortcut: PushToTalkShortcut,
    dock_edge: String,
    speaks_replies: bool,
    runs_commands_without_asking: bool,
    launches_at_login: bool,
}

#[derive(Debug, Deserialize)]
pub struct LogicalRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn current_general_settings(app: &AppHandle, state: &AppState) -> CommandResult<GeneralSettings> {
    let runtime = state.runtime()?;
    let stored = runtime.settings.read();
    Ok(GeneralSettings {
        push_to_talk_shortcut: stored.push_to_talk_shortcut,
        dock_edge: stored.bar_placement.as_ref().and_then(|placement| placement["edge"].as_str()).unwrap_or("bottom").to_string(),
        speaks_replies: stored.speaks_replies,
        runs_commands_without_asking: runtime.approval_settings.allow_without_asking(),
        launches_at_login: app.autolaunch().is_enabled().unwrap_or(false),
    })
}

// ---------- The turn ----------

#[tauri::command]
pub fn get_runtime_phase(state: State<AppState>) -> Value {
    state.shell.phase().payload().unwrap_or_else(|| json!({ "kind": "idle" }))
}

#[tauri::command]
pub fn submit_text(state: State<AppState>, text: String) -> CommandResult<()> {
    state.runtime()?.submit_text(text);
    Ok(())
}

#[tauri::command]
pub fn cancel_turn(state: State<AppState>) -> CommandResult<()> {
    state.runtime()?.cancel_turn();
    Ok(())
}

// ---------- Approvals ----------

#[tauri::command]
pub fn get_pending_approval(state: State<AppState>) -> Option<ApprovalRequest> {
    state.shell.pending_approval()
}

#[tauri::command]
pub fn answer_approval(state: State<AppState>, request_id: Uuid, is_allowed: bool) {
    state.shell.answer_approval(request_id, is_allowed);
}

// ---------- Background tasks ----------

#[tauri::command]
pub async fn get_background_tasks(state: State<'_, AppState>) -> CommandResult<Vec<BackgroundTask>> {
    Ok(state.runtime()?.background_tasks.tasks().await)
}

#[tauri::command]
pub async fn cancel_background_task(state: State<'_, AppState>, task_id: Uuid) -> CommandResult<()> {
    state.runtime()?.background_tasks.cancel(task_id).await;
    Ok(())
}

#[tauri::command]
pub async fn dismiss_background_task(state: State<'_, AppState>, task_id: Uuid) -> CommandResult<()> {
    state.runtime()?.background_tasks.dismiss(task_id).await;
    Ok(())
}

#[tauri::command]
pub async fn get_background_task_transcript(state: State<'_, AppState>, task_id: Uuid) -> CommandResult<String> {
    Ok(state.runtime()?.background_tasks.transcript(task_id).await)
}

// ---------- Memory ----------

#[tauri::command]
pub async fn get_memory_items(state: State<'_, AppState>) -> CommandResult<Vec<MemoryItem>> {
    Ok(state.runtime()?.memory.items().await)
}

#[tauri::command]
pub async fn add_memory(state: State<'_, AppState>, text: String) -> CommandResult<()> {
    state.runtime()?.memory.add(&text).await;
    Ok(())
}

#[tauri::command]
pub async fn delete_memory(state: State<'_, AppState>, item_id: Uuid) -> CommandResult<()> {
    state.runtime()?.memory.delete(item_id).await;
    Ok(())
}

#[tauri::command]
pub async fn get_automatic_learning_enabled(state: State<'_, AppState>) -> CommandResult<bool> {
    Ok(state.runtime()?.memory.is_automatic_learning_enabled().await)
}

#[tauri::command]
pub async fn set_automatic_learning_enabled(state: State<'_, AppState>, is_enabled: bool) -> CommandResult<()> {
    state.runtime()?.memory.set_automatic_learning_enabled(is_enabled).await;
    Ok(())
}

// ---------- Skills ----------

#[tauri::command]
pub async fn get_skills(state: State<'_, AppState>) -> CommandResult<Vec<SkillSummary>> {
    Ok(state.runtime()?.skills.skills().await)
}

#[tauri::command]
pub async fn install_skill_from_folder(app: AppHandle, state: State<'_, AppState>) -> CommandResult<bool> {
    let runtime = state.runtime()?;
    let picked = tauri::async_runtime::spawn_blocking(move || {
        app.dialog().file().set_title("Choose a skill folder. It needs a SKILL.md file inside.").blocking_pick_folder()
    })
    .await
    .map_err(|error| error.to_string())?;
    let Some(folder) = picked.and_then(|folder| folder.into_path().ok()) else { return Ok(false) };
    runtime.skills.install(&folder).await?;
    Ok(true)
}

#[tauri::command]
pub async fn delete_skill(state: State<'_, AppState>, skill_name: String) -> CommandResult<()> {
    state.runtime()?.skills.delete(&skill_name).await
}

// ---------- Connectors ----------

#[tauri::command]
pub async fn get_connector_apps(state: State<'_, AppState>, query: String) -> CommandResult<Vec<ConnectorApp>> {
    state.runtime()?.connectors.apps(&query).await
}

#[tauri::command]
pub async fn authorize_connector(state: State<'_, AppState>, app_slug: String) -> CommandResult<()> {
    let authorization_url = state.runtime()?.connectors.authorization_url(&app_slug).await?;
    state.shell.open_in_browser(&authorization_url);
    Ok(())
}

#[tauri::command]
pub async fn disconnect_connector(state: State<'_, AppState>, app_slug: String) -> CommandResult<()> {
    state.runtime()?.connectors.disconnect(&app_slug).await
}

// ---------- Settings and placement ----------

#[tauri::command]
pub fn get_general_settings(app: AppHandle, state: State<AppState>) -> CommandResult<GeneralSettings> {
    current_general_settings(&app, &state)
}

#[tauri::command]
pub fn set_general_settings(app: AppHandle, state: State<AppState>, settings: GeneralSettings) -> CommandResult<GeneralSettings> {
    let runtime = state.runtime()?;
    let before = current_general_settings(&app, &state)?;
    runtime.settings.update(|stored| {
        stored.push_to_talk_shortcut = settings.push_to_talk_shortcut;
        stored.speaks_replies = settings.speaks_replies;
    });
    runtime.set_shortcut(settings.push_to_talk_shortcut);
    if !settings.speaks_replies {
        runtime.stop_playback();
    }
    runtime.approval_settings.set_allow_without_asking(settings.runs_commands_without_asking)?;
    if settings.launches_at_login != before.launches_at_login {
        let changed = if settings.launches_at_login { app.autolaunch().enable() } else { app.autolaunch().disable() };
        if changed.is_err() {
            runtime.report_failure(ambient_contracts::AgentFailure::Other { message: "Open at login could not be changed. Check Startup apps in Windows Settings.".into() });
        }
    }
    if settings.dock_edge != before.dock_edge {
        // Re-docked from Settings: the bar goes to the centre of that edge, on the display it is already on.
        let display_identifier = runtime.settings.read().bar_placement.map(|placement| placement["displayIdentifier"].clone()).unwrap_or(Value::Null);
        let placement = json!({ "displayIdentifier": display_identifier, "edge": settings.dock_edge, "positionAlongEdge": 0.5 });
        runtime.settings.update(|stored| stored.bar_placement = Some(placement.clone()));
        state.shell.emit("ambient:bar-placement", placement);
    }
    let applied = current_general_settings(&app, &state)?;
    state.shell.emit("ambient:general-settings", applied.clone());
    Ok(applied)
}

#[tauri::command]
pub fn get_bar_placement(state: State<AppState>) -> CommandResult<Option<Value>> {
    Ok(state.runtime()?.settings.read().bar_placement)
}

#[tauri::command]
pub fn set_bar_placement(app: AppHandle, state: State<AppState>, placement: Value) -> CommandResult<()> {
    state.runtime()?.settings.update(|stored| stored.bar_placement = Some(placement.clone()));
    state.shell.emit("ambient:bar-placement", placement);
    state.shell.emit("ambient:general-settings", current_general_settings(&app, &state)?);
    Ok(())
}

#[tauri::command]
pub fn get_account_summary(state: State<AppState>) -> Option<Value> {
    state.shell.account_summary.lock().unwrap().clone()
}

#[tauri::command]
pub fn get_settings_navigation(state: State<AppState>) -> Value {
    state.shell.settings_navigation.lock().unwrap().clone()
}

// ---------- Permissions and onboarding ----------

#[tauri::command]
pub fn get_permission_statuses(state: State<AppState>) -> Value {
    state.shell.permission_statuses()
}

fn open_system_microphone_settings(state: &AppState) {
    state.shell.open_in_browser(if cfg!(windows) { "ms-settings:privacy-microphone" } else { "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" });
}

#[tauri::command]
pub async fn request_microphone_permission(state: State<'_, AppState>) -> CommandResult<()> {
    // Windows never asks a desktop app; the first use tells us, and a refusal is changed in Settings.
    state.shell.refresh_microphone_access().await;
    if !state.shell.is_microphone_usable() {
        open_system_microphone_settings(&state);
    }
    Ok(())
}

#[tauri::command]
pub fn open_microphone_settings(state: State<AppState>) {
    open_system_microphone_settings(&state);
}

#[tauri::command]
pub fn finish_permissions_step(app: AppHandle, state: State<AppState>) -> CommandResult<()> {
    let is_completed = state.runtime()?.settings.read().onboarding_completed;
    windows::close_onboarding(&app);
    if !is_completed {
        state.shell.show_bar();
        windows::start_tour(&app);
    }
    Ok(())
}

#[tauri::command]
pub fn get_onboarding_completed(state: State<AppState>) -> CommandResult<bool> {
    Ok(state.runtime()?.settings.read().onboarding_completed)
}

#[tauri::command]
pub fn set_onboarding_completed(state: State<AppState>, is_completed: bool) -> CommandResult<()> {
    state.runtime()?.settings.update(|stored| stored.onboarding_completed = is_completed);
    Ok(())
}

#[tauri::command]
pub fn get_gate_screen(state: State<AppState>) -> Option<Value> {
    state.shell.gate_screen.lock().unwrap().clone()
}

#[tauri::command]
pub fn answer_gate(app: AppHandle, state: State<AppState>, action: String) {
    // The only screen without the sign-in module behind it: Ambient could not start, and its one button quits.
    if state.runtime().is_err() && action == "quit" {
        app.exit(0);
        return;
    }
    if let Some(answers) = state.shell.gate_answers.lock().unwrap().as_ref() {
        let _ = answers.send(action);
    }
}

// ---------- App ----------

/// Shared by the command, the tray and the bar's menu. Before sign-in there are no settings to show: the gate is shown instead.
pub fn open_settings_window(app: &AppHandle, section: Option<String>, task_id: Option<Uuid>) {
    let state = app.state::<AppState>();
    let Ok(runtime) = state.runtime().ok().filter(|runtime| runtime.is_ready()).ok_or(()) else {
        windows::show_onboarding(app);
        return;
    };
    let navigation = {
        let mut navigation = state.shell.settings_navigation.lock().unwrap();
        if let Some(section) = section {
            navigation["section"] = json!(section);
        }
        navigation["taskId"] = json!(task_id);
        navigation.clone()
    };
    windows::show_settings(app);
    state.shell.emit("ambient:settings-navigate", navigation);
    tauri::async_runtime::spawn(async move { runtime.refresh_account_summary().await });
}

#[tauri::command]
pub async fn open_settings(app: AppHandle, section: Option<String>, task_id: Option<Uuid>) {
    open_settings_window(&app, section, task_id);
}

#[tauri::command]
pub fn open_url(state: State<AppState>, url: String) -> CommandResult<()> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("Only web links can be opened.".into());
    }
    state.shell.open_in_browser(&url);
    Ok(())
}

#[tauri::command]
pub async fn check_for_updates(app: AppHandle) {
    crate::updates::check_for_updates(&app, true).await;
}

#[tauri::command]
pub fn quit(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub fn show_bar(state: State<AppState>) {
    state.shell.show_bar();
}

#[tauri::command]
pub fn hide_bar(state: State<AppState>) {
    state.shell.hide_bar();
}

#[tauri::command]
pub async fn start_tour(app: AppHandle, state: State<'_, AppState>) -> CommandResult<()> {
    state.shell.show_bar();
    windows::start_tour(&app);
    Ok(())
}

#[tauri::command]
pub async fn end_tour(app: AppHandle) {
    windows::end_tour(&app);
}

#[tauri::command]
pub fn clear_drawing(state: State<AppState>) {
    state.shell.clear_drawing();
}

#[tauri::command]
pub async fn save_text_file(app: AppHandle, suggested_name: String, text: String) -> CommandResult<bool> {
    let documents_directory = app.path().document_dir().ok();
    let picked = tauri::async_runtime::spawn_blocking(move || {
        let mut dialog = app.dialog().file().set_file_name(suggested_name);
        if let Some(documents_directory) = documents_directory {
            dialog = dialog.set_directory(documents_directory);
        }
        dialog.blocking_save_file()
    })
    .await
    .map_err(|error| error.to_string())?;
    let Some(destination) = picked.and_then(|destination| destination.into_path().ok()) else { return Ok(false) };
    std::fs::write(&destination, text).map_err(|error| format!("The file could not be saved: {error}"))?;
    Ok(true)
}

// ---------- Windows ----------

/// The contract's geometry is in logical desktop pixels: each monitor's physical position and size divided by its
/// own scale factor. The monitor that holds the frame's centre decides the scale used to convert back.
#[tauri::command]
pub fn set_window_frame(window: WebviewWindow, state: State<AppState>, frame: LogicalRect) -> CommandResult<()> {
    let (centre_x, centre_y) = (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0);
    let monitors = window.available_monitors().map_err(|error| error.to_string())?;
    let scale_factor = monitors.iter()
        .find(|monitor| {
            let scale_factor = monitor.scale_factor();
            let (left, top) = (f64::from(monitor.position().x) / scale_factor, f64::from(monitor.position().y) / scale_factor);
            let (width, height) = (f64::from(monitor.size().width) / scale_factor, f64::from(monitor.size().height) / scale_factor);
            centre_x >= left && centre_x < left + width && centre_y >= top && centre_y < top + height
        })
        .or(monitors.first())
        .map(|monitor| monitor.scale_factor())
        .unwrap_or(1.0);
    let physical_size = tauri::PhysicalSize::new((frame.width * scale_factor).round().max(1.0) as u32, (frame.height * scale_factor).round().max(1.0) as u32);
    let physical_position = tauri::PhysicalPosition::new((frame.x * scale_factor).round() as i32, (frame.y * scale_factor).round() as i32);
    window.set_size(physical_size).map_err(|error| error.to_string())?;
    window.set_position(physical_position).map_err(|error| error.to_string())?;
    // Floating windows are created hidden and appear only once they are where they belong.
    match window.label() {
        "bar" => {
            state.shell.bar_has_been_placed.store(true, Ordering::SeqCst);
            if state.shell.bar_should_be_visible.load(Ordering::SeqCst) && !window.is_visible().unwrap_or(true) {
                let _ = window.show();
            }
        }
        "tour" => {
            if !window.is_visible().unwrap_or(true) {
                let _ = window.show();
            }
        }
        _ => {}
    }
    Ok(())
}

#[tauri::command]
pub fn set_bar_accepts_keyboard(window: WebviewWindow, accepts_keyboard: bool) -> CommandResult<()> {
    if accepts_keyboard {
        crate::focus::remember_foreground_window();
        window.set_focusable(true).map_err(|error| error.to_string())?;
        window.set_focus().map_err(|error| error.to_string())?;
    } else {
        window.set_focusable(false).map_err(|error| error.to_string())?;
        crate::focus::restore_foreground_window();
    }
    Ok(())
}

#[tauri::command]
pub fn get_overlay_drawing(state: State<AppState>) -> Option<Value> {
    state.shell.overlay_drawing.lock().unwrap().clone()
}

#[tauri::command]
pub fn overlay_content_changed(app: AppHandle, has_content: bool) {
    if !has_content {
        if let Some(overlay) = app.get_webview_window("overlay") {
            let _ = overlay.hide();
        }
    }
}
