use ambient_contracts::*;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tokio::sync::watch;
use uuid::Uuid;

fn io<T>(result: std::io::Result<T>) -> Result<T, String> {
    result.map_err(|error| error.to_string())
}
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing parent directory.")?;
    io(fs::create_dir_all(parent))?;
    let mut temporary = io(tempfile::NamedTempFile::new_in(parent))?;
    use std::io::Write;
    io(temporary.write_all(bytes))?;
    io(temporary.as_file().sync_all())?;
    temporary.persist(path).map_err(|error| error.to_string())?;
    Ok(())
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    item: MemoryItem,
    last_confirmed_at: DateTime<Utc>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Document {
    is_automatic_learning_enabled: bool,
    memories: Vec<Record>,
}
struct MemoryState {
    document: Document,
    generation: u64,
}
#[derive(Clone)]
pub struct PersistentMemoryStore {
    state: Arc<Mutex<MemoryState>>,
    file: PathBuf,
    completion_service: Arc<dyn TextCompletionService>,
    updates: watch::Sender<Vec<MemoryItem>>,
    pending: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
}
impl PersistentMemoryStore {
    pub fn new(completion_service: Arc<dyn TextCompletionService>) -> Result<Self, String> {
        Self::with_directory(ambient_data_directory(), completion_service)
    }
    pub fn with_directory(
        directory: PathBuf,
        completion_service: Arc<dyn TextCompletionService>,
    ) -> Result<Self, String> {
        let file = directory.join("memories.json");
        let document = match fs::read(&file) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|error| error.to_string())?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Document {
                is_automatic_learning_enabled: true,
                memories: vec![],
            },
            Err(error) => return Err(error.to_string()),
        };
        let (updates, _) = watch::channel(Self::sorted(&document));
        Ok(Self {
            state: Arc::new(Mutex::new(MemoryState {
                document,
                generation: 0,
            })),
            file,
            completion_service,
            updates,
            pending: Default::default(),
        })
    }
    fn sorted(document: &Document) -> Vec<MemoryItem> {
        let mut records = document.memories.clone();
        records.sort_by(|left, right| right.last_confirmed_at.cmp(&left.last_confirmed_at));
        records.into_iter().map(|record| record.item).collect()
    }
    fn persist(&self, state: &mut MemoryState, document: Document) -> Result<(), String> {
        atomic_write(
            &self.file,
            &serde_json::to_vec_pretty(&document).map_err(|error| error.to_string())?,
        )?;
        self.updates.send_replace(Self::sorted(&document));
        state.document = document;
        Ok(())
    }
    pub async fn remember(&self, text: &str) -> Result<MemoryItem, String> {
        let text = text.trim();
        if text.is_empty() {
            return Err("A memory must contain text.".into());
        }
        let mut state = self.state.lock().unwrap();
        let mut document = state.document.clone();
        let now = Utc::now();
        let item = if let Some(record) = document
            .memories
            .iter_mut()
            .find(|record| record.item.text == text)
        {
            record.last_confirmed_at = now;
            record.item.was_learned_automatically = false;
            record.item.clone()
        } else {
            let item = MemoryItem {
                id: Uuid::new_v4(),
                text: text.into(),
                created_at: now,
                was_learned_automatically: false,
            };
            document.memories.push(Record {
                item: item.clone(),
                last_confirmed_at: now,
            });
            item
        };
        self.persist(&mut state, document)?;
        Ok(item)
    }
    pub async fn forget(&self, item_id: Uuid) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        let mut document = state.document.clone();
        if !document
            .memories
            .iter()
            .any(|record| record.item.id == item_id)
        {
            return Err("No memory exists with that ID.".into());
        }
        document.memories.retain(|record| record.item.id != item_id);
        self.persist(&mut state, document)
    }
    pub async fn finish_pending_learning(&self) {
        let pending = self.pending.lock().unwrap().take();
        if let Some(pending) = pending {
            let _ = pending.await;
        }
    }
    async fn extract(&self, user_text: String, assistant_text: String, generation: u64) {
        let snapshot = {
            let state = self.state.lock().unwrap();
            if !state.document.is_automatic_learning_enabled || state.generation != generation {
                return;
            }
            state.document.memories.clone()
        };
        let input = json!({"existing_memories": snapshot.iter().map(|record| json!({"id":record.item.id,"text":record.item.text})).collect::<Vec<_>>(), "exchange":{"user":user_text,"assistant":assistant_text}});
        let Ok(answer) = self
            .completion_service
            .complete(
                include_str!("extraction.txt"),
                &input.to_string(),
                ModelTier::Balanced,
            )
            .await
        else {
            return;
        };
        let answer = answer.trim();
        let lines: Vec<_> = answer.lines().collect();
        let answer = if lines.len() >= 3
            && (lines[0] == "```json" || lines[0] == "```")
            && lines.last() == Some(&"```")
        {
            lines[1..lines.len() - 1].join("\n")
        } else {
            answer.into()
        };
        #[derive(Deserialize)]
        struct Rewrite {
            id: Uuid,
            text: String,
        }
        #[derive(Deserialize)]
        struct Response {
            add: Vec<String>,
            rewrite: Vec<Rewrite>,
            remove: Vec<Uuid>,
        }
        let Ok(response) = serde_json::from_str::<Response>(&answer) else {
            return;
        };
        let changed: Vec<_> = response
            .rewrite
            .iter()
            .map(|rewrite| rewrite.id)
            .chain(response.remove.iter().copied())
            .collect();
        let unique: HashSet<_> = changed.iter().copied().collect();
        if unique.len() != changed.len()
            || changed
                .iter()
                .any(|id| !snapshot.iter().any(|record| record.item.id == *id))
            || response
                .add
                .iter()
                .chain(response.rewrite.iter().map(|rewrite| &rewrite.text))
                .any(|text| text.trim().is_empty())
        {
            return;
        }
        let mut state = self.state.lock().unwrap();
        if !state.document.is_automatic_learning_enabled || state.generation != generation {
            return;
        }
        if changed.iter().any(|id| {
            snapshot.iter().find(|record| record.item.id == *id)
                != state
                    .document
                    .memories
                    .iter()
                    .find(|record| record.item.id == *id)
        }) {
            return;
        }
        if response.add.is_empty() && changed.is_empty() {
            return;
        }
        let mut document = state.document.clone();
        let now = Utc::now();
        document
            .memories
            .retain(|record| !response.remove.contains(&record.item.id));
        for rewrite in response.rewrite {
            let record = document
                .memories
                .iter_mut()
                .find(|record| record.item.id == rewrite.id)
                .unwrap();
            record.item.text = rewrite.text.trim().into();
            record.last_confirmed_at = now;
        }
        for text in response.add {
            let text = text.trim().to_string();
            if let Some(record) = document
                .memories
                .iter_mut()
                .find(|record| record.item.text == text)
            {
                record.last_confirmed_at = now;
            } else {
                document.memories.push(Record {
                    item: MemoryItem {
                        id: Uuid::new_v4(),
                        text,
                        created_at: now,
                        was_learned_automatically: true,
                    },
                    last_confirmed_at: now,
                });
            }
        }
        let _ = self.persist(&mut state, document);
    }
}
#[async_trait]
impl MemoryStore for PersistentMemoryStore {
    async fn items(&self) -> Vec<MemoryItem> {
        Self::sorted(&self.state.lock().unwrap().document)
    }
    fn updates(&self) -> watch::Receiver<Vec<MemoryItem>> {
        self.updates.subscribe()
    }
    async fn add(&self, text: &str) {
        let _ = self.remember(text).await;
    }
    async fn delete(&self, item_id: Uuid) {
        let _ = self.forget(item_id).await;
    }
    async fn is_automatic_learning_enabled(&self) -> bool {
        self.state
            .lock()
            .unwrap()
            .document
            .is_automatic_learning_enabled
    }
    async fn set_automatic_learning_enabled(&self, is_enabled: bool) {
        let mut state = self.state.lock().unwrap();
        if state.document.is_automatic_learning_enabled == is_enabled {
            return;
        }
        state.generation += 1;
        let mut document = state.document.clone();
        document.is_automatic_learning_enabled = is_enabled;
        let _ = self.persist(&mut state, document);
    }
    async fn learn(&self, user_text: &str, assistant_text: &str) {
        let generation = {
            let state = self.state.lock().unwrap();
            if !state.document.is_automatic_learning_enabled {
                return;
            }
            state.generation
        };
        let mut pending = self.pending.lock().unwrap();
        let previous = pending.take();
        let store = self.clone();
        let user_text = user_text.into();
        let assistant_text = assistant_text.into();
        *pending = Some(tokio::spawn(async move {
            if let Some(previous) = previous {
                let _ = previous.await;
            }
            store.extract(user_text, assistant_text, generation).await;
        }));
    }
}
mod skills;
pub use skills::FileSkillStore;
mod tools;
pub use tools::{MemoryToolProvider, SkillToolProvider};
#[cfg(test)]
mod tests;
