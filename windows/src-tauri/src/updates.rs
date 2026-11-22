//! Self-update through publik's feed (`latest.json` of the published release), signed with Ambient's own key.
//! Checks at launch and once a day, downloads in the background, and asks before restarting.
use tauri::AppHandle;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_updater::UpdaterExt;

use crate::log_line;

async fn tell(app: &AppHandle, message: &'static str) {
    let app = app.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || app.dialog().message(message).title("Ambient").blocking_show()).await;
}

/// `asked_by_person` is true for Check for Updates…: then "up to date" and failures are said, not only logged.
pub async fn check_for_updates(app: &AppHandle, asked_by_person: bool) {
    let update = match app.updater() {
        Ok(updater) => updater.check().await,
        Err(error) => Err(error),
    };
    match update {
        Ok(Some(update)) => {
            log_line(&format!("update {} found; downloading", update.version));
            if let Err(error) = update.download_and_install(|_, _| {}, || {}).await {
                log_line(&format!("the update could not be installed: {error}"));
                if asked_by_person {
                    tell(app, "The update could not be installed. Ambient will try again later.").await;
                }
                return;
            }
            let asking_app = app.clone();
            let restart_now = tauri::async_runtime::spawn_blocking(move || {
                asking_app.dialog().message("A new version of Ambient is installed. Restart now?").title("Ambient")
                    .buttons(MessageDialogButtons::OkCancelCustom("Restart now".into(), "Later".into())).blocking_show()
            })
            .await
            .unwrap_or(false);
            if restart_now {
                app.restart();
            }
        }
        Ok(None) => {
            if asked_by_person {
                tell(app, "Ambient is up to date.").await;
            }
        }
        Err(error) => {
            log_line(&format!("the update check failed: {error}"));
            if asked_by_person {
                tell(app, "Ambient could not check for updates. Check your connection and try again.").await;
            }
        }
    }
}

pub fn check_daily(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            check_for_updates(&app, false).await;
            tokio::time::sleep(std::time::Duration::from_secs(86_400)).await;
        }
    });
}
