//! Ambient's windows and tray menu. Every window loads the same page and picks its surface from its label.
use std::sync::atomic::Ordering;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::{log_line, AppState};

/// The tray's Show Bar / Hide Bar item, kept so its words can follow the bar.
pub struct TrayItems {
    bar_visibility: MenuItem<tauri::Wry>,
}

/// Screenshots must not contain Ambient's own windows. CI turns this off so its screenshots can show them.
fn hides_from_screen_capture() -> bool {
    std::env::var_os("AMBIENT_SHOW_WINDOWS_IN_CAPTURES").is_none()
}

/// A frameless, see-through window that floats over everything and never takes focus from the person's work.
fn floating_window(app: &AppHandle, label: &str, width: f64, height: f64) -> Option<WebviewWindow> {
    if let Some(existing) = app.get_webview_window(label) {
        return Some(existing);
    }
    let built = WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
        .title("Ambient")
        .inner_size(width, height)
        .transparent(true)
        .decorations(false)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focusable(false)
        .visible(false)
        .content_protected(hides_from_screen_capture())
        .build();
    match built {
        Ok(window) => Some(window),
        Err(error) => {
            log_line(&format!("the {label} window could not be created: {error}"));
            None
        }
    }
}

/// Created hidden; the bar shows itself once its page has placed it (`set_window_frame`).
pub fn create_bar(app: &AppHandle) {
    floating_window(app, "bar", 420.0, 80.0);
}

/// Created at launch so its page is loaded before the first pointer arrives; shown only while it has content.
pub fn create_overlay(app: &AppHandle) {
    if let Some(overlay) = floating_window(app, "overlay", 400.0, 300.0) {
        let _ = overlay.set_ignore_cursor_events(true);
    }
}

pub fn start_tour(app: &AppHandle) {
    end_tour(app);
    if floating_window(app, "tour", 380.0, 260.0).is_some() {
        app.state::<crate::AppState>().shell.analytics.reached(crate::analytics::Step::TourStarted);
    }
}

pub fn end_tour(app: &AppHandle) {
    if let Some(tour) = app.get_webview_window("tour") {
        let _ = tour.destroy();
    }
}

fn ordinary_window(app: &AppHandle, label: &str, title: &str, width: f64, height: f64, is_resizable: bool) {
    if let Some(existing) = app.get_webview_window(label) {
        let _ = existing.unminimize();
        let _ = existing.show();
        let _ = existing.set_focus();
        return;
    }
    let built = WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
        .title(title)
        .inner_size(width, height)
        .min_inner_size(width.min(780.0), height.min(560.0))
        .resizable(is_resizable)
        .maximizable(is_resizable)
        .minimizable(is_resizable)
        .center()
        .build();
    if let Err(error) = built {
        log_line(&format!("the {label} window could not be created: {error}"));
    }
}

/// The sign-in gate and the permissions step share this window.
pub fn show_onboarding(app: &AppHandle) {
    ordinary_window(app, "onboarding", "Ambient", 600.0, 530.0, false);
}

pub fn close_onboarding(app: &AppHandle) {
    if let Some(onboarding) = app.get_webview_window("onboarding") {
        let _ = onboarding.destroy();
    }
}

pub fn show_settings(app: &AppHandle) {
    ordinary_window(app, "settings", "Ambient Settings", 820.0, 580.0, true);
}

pub fn bar_visibility_changed(app: &AppHandle, is_visible: bool) {
    if let Some(items) = app.try_state::<TrayItems>() {
        let _ = items.bar_visibility.set_text(if is_visible { "Hide Bar" } else { "Show Bar" });
    }
}

pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open_settings = MenuItem::with_id(app, "open_settings", "Open Settings", true, None::<&str>)?;
    let bar_visibility = MenuItem::with_id(app, "toggle_bar", "Show Bar", true, None::<&str>)?;
    let replay_tour = MenuItem::with_id(app, "replay_tour", "Replay the Tour", true, None::<&str>)?;
    let clear_drawing = MenuItem::with_id(app, "clear_drawing", "Clear Drawing", true, None::<&str>)?;
    let check_for_updates = MenuItem::with_id(app, "check_for_updates", "Check for Updates…", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Ambient", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open_settings, &bar_visibility, &replay_tour, &clear_drawing, &check_for_updates, &PredefinedMenuItem::separator(app)?, &quit])?;
    app.manage(TrayItems { bar_visibility });
    let mut tray = TrayIconBuilder::with_id("ambient").tooltip("Ambient").menu(&menu).show_menu_on_left_click(true);
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.on_menu_event(|app, event| {
        let state = app.state::<AppState>();
        match event.id().as_ref() {
            "open_settings" => crate::commands::open_settings_window(app, None, None),
            "toggle_bar" => {
                if state.shell.bar_should_be_visible.load(Ordering::SeqCst) { state.shell.hide_bar() } else { state.shell.show_bar() }
            }
            "replay_tour" => {
                if state.runtime().is_ok_and(|runtime| runtime.is_ready()) {
                    state.shell.show_bar();
                    start_tour(app);
                }
            }
            "clear_drawing" => {
                use crate::screen_tools::ScreenOverlay;
                if state.shell.clear_drawing() { state.shell.analytics.drawing_cleared("menu"); }
            }
            "check_for_updates" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move { crate::updates::check_for_updates(&app, true).await });
            }
            "quit" => app.exit(0),
            _ => {}
        }
    })
    .build(app)?;
    Ok(())
}
