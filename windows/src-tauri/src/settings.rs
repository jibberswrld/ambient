//! Ambient's own preferences, kept as one readable JSON file in the data directory (the Mac uses UserDefaults).
use std::path::PathBuf;
use std::sync::Mutex;

use ambient_platform::push_to_talk::PushToTalkShortcut;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct StoredSettings {
    pub push_to_talk_shortcut: PushToTalkShortcut,
    pub speaks_replies: bool,
    /// Missing from files written before sound cues existed; `default` above turns those on.
    pub plays_sound_effects: bool,
    /// The bar's placement exactly as the interface saved it; the core only reads its `edge`.
    pub bar_placement: Option<Value>,
    pub onboarding_completed: bool,
    /// The voice replies are spoken in. Not in Settings yet; edit settings.json to change it.
    pub spoken_voice: Option<String>,
}

impl Default for StoredSettings {
    fn default() -> Self {
        Self { push_to_talk_shortcut: PushToTalkShortcut::default(), speaks_replies: true, plays_sound_effects: true, bar_placement: None, onboarding_completed: false, spoken_voice: None }
    }
}

pub struct SettingsStore {
    path: PathBuf,
    current: Mutex<StoredSettings>,
}

impl SettingsStore {
    /// A settings file that exists but cannot be read is an error, never silently replaced with defaults.
    pub fn load() -> Result<Self, String> {
        let path = ambient_contracts::ambient_data_directory().join("settings.json");
        let current = match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).map_err(|error| format!("Ambient's settings file could not be read ({error}). Fix or remove {}.", path.display()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => StoredSettings::default(),
            Err(error) => return Err(format!("Ambient's settings file could not be opened: {error}")),
        };
        Ok(Self { path, current: Mutex::new(current) })
    }

    pub fn read(&self) -> StoredSettings {
        self.current.lock().unwrap().clone()
    }

    pub fn update(&self, change: impl FnOnce(&mut StoredSettings)) {
        let mut current = self.current.lock().unwrap();
        change(&mut current);
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        // Written beside the file and renamed over it, so a crash never leaves half a settings file.
        let temporary_path = self.path.with_extension("json.tmp");
        if std::fs::write(&temporary_path, serde_json::to_vec_pretty(&*current).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&temporary_path, &self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_settings_file_from_before_sound_effects_turns_them_on() {
        let stored: StoredSettings = serde_json::from_str(r#"{ "pushToTalkShortcut": "controlShift", "speaksReplies": false }"#).unwrap();
        assert!(stored.plays_sound_effects);
        assert!(!stored.speaks_replies);
        let written = serde_json::to_value(StoredSettings { plays_sound_effects: false, ..stored }).unwrap();
        assert_eq!(written["playsSoundEffects"], false);
    }
}
