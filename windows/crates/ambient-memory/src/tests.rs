use super::*;
use std::collections::VecDeque;
#[derive(Default)]
struct Completion {
    replies: Mutex<VecDeque<String>>,
    calls: Mutex<Vec<(String, String, ModelTier)>>,
}
#[async_trait]
impl TextCompletionService for Completion {
    async fn complete(
        &self,
        system: &str,
        user: &str,
        tier: ModelTier,
    ) -> Result<String, AgentFailure> {
        self.calls
            .lock()
            .unwrap()
            .push((system.into(), user.into(), tier));
        Ok(self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| json!({"add":[],"rewrite":[],"remove":[]}).to_string()))
    }
}
impl Completion {
    fn reply(&self, value: Value) {
        self.replies.lock().unwrap().push_back(value.to_string());
    }
}
fn markdown(name: &str) -> String {
    format!("---\nname: {name}\ndescription: Useful routine.\n---\nRun the checks.\n")
}
async fn call(provider: &dyn ToolProvider, name: &str, args: Value) -> ToolResult {
    provider
        .tools()
        .await
        .into_iter()
        .find(|tool| tool.definition().name == name)
        .unwrap()
        .run(args)
        .await
}
#[tokio::test]
async fn persistence_settings_deduplication_and_updates() {
    let directory = tempfile::tempdir().unwrap();
    let service = Arc::new(Completion::default());
    let store =
        PersistentMemoryStore::with_directory(directory.path().into(), service.clone()).unwrap();
    let mut updates = store.updates();
    assert!(updates.borrow_and_update().is_empty());
    let item = store.remember("  Concise replies.  ").await.unwrap();
    updates.changed().await.unwrap();
    assert_eq!(*updates.borrow_and_update(), vec![item.clone()]);
    assert_eq!(store.remember(&item.text).await.unwrap().id, item.id);
    store.set_automatic_learning_enabled(false).await;
    let reopened = PersistentMemoryStore::with_directory(directory.path().into(), service).unwrap();
    assert_eq!(reopened.items().await, vec![item.clone()]);
    assert!(!reopened.is_automatic_learning_enabled().await);
    assert!(fs::read_to_string(directory.path().join("memories.json"))
        .unwrap()
        .contains('\n'));
    reopened.forget(item.id).await.unwrap();
    assert!(reopened.items().await.is_empty());
    assert!(reopened.forget(item.id).await.is_err());
    assert!(store.remember(" ").await.is_err());
}
#[test]
fn corrupt_store_is_preserved() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("memories.json");
    fs::write(&path, "bad data").unwrap();
    assert!(PersistentMemoryStore::with_directory(
        directory.path().into(),
        Arc::new(Completion::default())
    )
    .is_err());
    assert_eq!(fs::read_to_string(path).unwrap(), "bad data");
}
#[tokio::test]
async fn learning_add_rewrite_remove_and_malformed_transactions() {
    let directory = tempfile::tempdir().unwrap();
    let service = Arc::new(Completion::default());
    let store =
        PersistentMemoryStore::with_directory(directory.path().into(), service.clone()).unwrap();
    let item = store.remember("Harbor uses Swift.").await.unwrap();
    service.reply(
        json!({"add":["Prefers clear replies.","Prefers clear replies."],"rewrite":[],"remove":[]}),
    );
    store.learn("Skip the preamble.", "Okay.").await;
    store.finish_pending_learning().await;
    assert_eq!(store.items().await.len(), 2);
    assert_eq!(service.calls.lock().unwrap()[0].2, ModelTier::Balanced);
    assert!(service.calls.lock().unwrap()[0]
        .0
        .contains("Never store secrets"));
    assert!(service.calls.lock().unwrap()[0].1.contains(&item.text));
    service
        .reply(json!({"add":[],"rewrite":[{"id":item.id,"text":"Harbor uses Rust."}],"remove":[]}));
    store.learn("Correction.", "Okay.").await;
    store.finish_pending_learning().await;
    let changed = store
        .items()
        .await
        .into_iter()
        .find(|entry| entry.id == item.id)
        .unwrap();
    assert_eq!(changed.created_at, item.created_at);
    assert!(!changed.was_learned_automatically);
    let snapshot = store.items().await;
    for invalid in [
        "not JSON".into(),
        "Here is the result: {}".into(),
        json!({"add":["Wrong"]}).to_string(),
        json!({"add":[42],"rewrite":[],"remove":[]}).to_string(),
        json!({"add":["Wrong"],"rewrite":[],"remove":[Uuid::new_v4()]}).to_string(),
        json!({"add":[],"rewrite":[{"id":item.id,"text":"Wrong"}],"remove":[item.id]}).to_string(),
        json!({"add":[" "],"rewrite":[],"remove":[]}).to_string(),
    ] {
        service.replies.lock().unwrap().push_back(invalid);
        store.learn("x", "y").await;
        store.finish_pending_learning().await;
        assert_eq!(store.items().await, snapshot);
    }
    service.replies.lock().unwrap().push_back(
        "```json\n{\"add\":[\"Fenced fact.\"],\"rewrite\":[],\"remove\":[]}\n```".into(),
    );
    store.learn("x", "y").await;
    store.finish_pending_learning().await;
    assert_eq!(store.items().await.len(), 3);
    service.reply(json!({"add":[],"rewrite":[],"remove":[item.id]}));
    store.learn("x", "y").await;
    store.finish_pending_learning().await;
    assert!(!store.items().await.iter().any(|entry| entry.id == item.id));
    store.set_automatic_learning_enabled(false).await;
    let count = service.calls.lock().unwrap().len();
    store.learn("x", "y").await;
    store.finish_pending_learning().await;
    assert_eq!(service.calls.lock().unwrap().len(), count);
}
struct Suspended {
    started: tokio::sync::Notify,
    finish: tokio::sync::Notify,
    answer: Mutex<String>,
}
#[async_trait]
impl TextCompletionService for Suspended {
    async fn complete(&self, _: &str, _: &str, _: ModelTier) -> Result<String, AgentFailure> {
        self.started.notify_one();
        self.finish.notified().await;
        Ok(self.answer.lock().unwrap().clone())
    }
}
#[tokio::test]
async fn learning_is_background_and_manual_deletion_and_disable_win() {
    for disable in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let service = Arc::new(Suspended {
            started: Default::default(),
            finish: Default::default(),
            answer: Default::default(),
        });
        let store = PersistentMemoryStore::with_directory(directory.path().into(), service.clone())
            .unwrap();
        let item = store.remember("Original.").await.unwrap();
        *service.answer.lock().unwrap() =
            json!({"add":[],"rewrite":[{"id":item.id,"text":"Stale."}],"remove":[]}).to_string();
        store.learn("Correction.", "Okay.").await;
        service.started.notified().await;
        if disable {
            store.set_automatic_learning_enabled(false).await;
            store.set_automatic_learning_enabled(true).await;
        } else {
            store.forget(item.id).await.unwrap();
        }
        service.finish.notify_one();
        store.finish_pending_learning().await;
        assert!(!store
            .items()
            .await
            .iter()
            .any(|entry| entry.text == "Stale."));
    }
}
#[test]
fn frontmatter_validation_and_quoted_multiline_fields() {
    use super::skills::SkillDocument;
    for invalid in [
        "No header".into(),
        "---\nname: missing-end".into(),
        markdown("../escape"),
        markdown("Uppercase"),
        markdown("bad--name"),
        "---\nname: test\ndescription: [not, text]\n---\nAct.".into(),
        "---\nname: test\nname: other\ndescription: Desc\n---\nAct.".into(),
        "---\nname: test\ndescription: ''\n---\nAct.".into(),
    ] {
        assert!(SkillDocument::parse(&invalid).is_err(), "{invalid}");
    }
    assert_eq!(
        SkillDocument::parse(
            "---\nname: 'quoted-skill'\ndescription: \"A colon: here.\"\n---\nAct."
        )
        .unwrap()
        .description,
        "A colon: here."
    );
    assert_eq!(
        SkillDocument::parse(
            "---\nname: folded-skill\ndescription: >-\n  First line\n  second line.\n---\nAct."
        )
        .unwrap()
        .description,
        "First line second line."
    );
    assert_eq!(
        SkillDocument::parse(
            "---\r\nname: literal-skill\r\ndescription: |\r\n  First\r\n  second\r\n---\r\nAct."
        )
        .unwrap()
        .description,
        "First\nsecond"
    );
}
#[tokio::test]
async fn skill_tools_create_update_load_read_and_override() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(FileSkillStore::with_directory(directory.path().join("skills")).unwrap());
    let provider = SkillToolProvider::new(store.clone());
    let catalog = store.skills().await;
    assert_eq!(catalog.len(), 4);
    assert!(catalog.iter().all(|skill| skill.is_built_in));
    let prompt = provider.system_prompt_section().await.unwrap();
    for skill in catalog {
        let (instructions, files) = store.load(&skill.name).await.unwrap();
        assert!(files.contains(&"SKILL.md".into()));
        assert!(prompt.contains(&skill.description));
        assert!(!prompt.contains(&instructions));
    }
    assert!(!call(&provider,"create_skill",json!({"markdown":markdown("test-routine"),"files":{"references/checks.md":"Run cargo test."}})).await.is_error);
    assert!(
        call(
            &provider,
            "create_skill",
            json!({"markdown":markdown("test-routine")})
        )
        .await
        .is_error
    );
    assert!(!call(&provider,"update_skill",json!({"name":"test-routine","markdown":markdown("test-routine").replace("Run the checks.","Report results.")})).await.is_error);
    assert!(
        call(&provider, "load_skill", json!({"name":"test-routine"}))
            .await
            .content
            .contains("references/checks.md")
    );
    assert_eq!(
        call(
            &provider,
            "read_skill_file",
            json!({"name":"test-routine","path":"references/checks.md"})
        )
        .await
        .content,
        "Run cargo test."
    );
    for path in [
        "../SKILL.md",
        "/etc/passwd",
        "references/../../escape",
        "C:/escape",
        "references\\escape",
        "notes.txt.",
        "CON",
        "LPT1.txt",
        "notes.txt:stream",
    ] {
        assert!(
            call(
                &provider,
                "read_skill_file",
                json!({"name":"test-routine","path":path})
            )
            .await
            .is_error
        );
    }
    assert!(
        call(
            &provider,
            "create_skill",
            json!({"markdown":markdown("escape"),"files":{"../escape":"Bad"}})
        )
        .await
        .is_error
    );
    assert_eq!(store.skills().await.len(), 5);
    assert!(
        !call(
            &provider,
            "update_skill",
            json!({"name":"daily-brief","markdown":markdown("daily-brief")})
        )
        .await
        .is_error
    );
    assert!(!store.skills().await[0].is_built_in);
    assert!(
        call(
            &provider,
            "update_skill",
            json!({"name":"daily-brief","markdown":markdown("renamed")})
        )
        .await
        .is_error
    );
    store.delete("daily-brief").await.unwrap();
    assert!(store.skills().await[0].is_built_in);
    assert!(store.delete("daily-brief").await.is_err());
    assert!(
        FileSkillStore::with_directory(directory.path().join("skills"))
            .unwrap()
            .load("test-routine")
            .await
            .unwrap()
            .0
            .contains("Report results.")
    );
}
#[tokio::test]
async fn skill_install_copies_files_and_rejects_symlinks() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("SKILL.md"), markdown("daily-brief")).unwrap();
    fs::write(source.join("notes.txt"), "Personal.").unwrap();
    let store = FileSkillStore::with_directory(directory.path().join("skills")).unwrap();
    store.install(&source).await.unwrap();
    fs::remove_file(source.join("notes.txt")).unwrap();
    assert_eq!(
        store.read_file("daily-brief", "notes.txt").await.unwrap(),
        "Personal."
    );
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(directory.path(), source.join("outside")).unwrap();
        assert!(store.install(&source).await.is_err());
    }
}
#[tokio::test]
async fn watcher_detects_addition_nested_edits_and_removal() {
    let directory = tempfile::tempdir().unwrap();
    let personal = directory.path().join("skills");
    let store = FileSkillStore::with_directory(personal.clone()).unwrap();
    let mut updates = store.updates();
    updates.borrow_and_update();
    let folder = personal.join("test-routine");
    fs::create_dir(&folder).unwrap();
    fs::write(folder.join("SKILL.md"), markdown("test-routine")).unwrap();
    async fn wait(updates: &mut watch::Receiver<Vec<SkillSummary>>, present: bool) {
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            loop {
                updates.changed().await.unwrap();
                if updates
                    .borrow_and_update()
                    .iter()
                    .any(|skill| skill.name == "test-routine")
                    == present
                {
                    break;
                }
            }
        })
        .await
        .unwrap();
    }
    wait(&mut updates, true).await;
    fs::write(folder.join("notes.txt"), "Supporting text.").unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), updates.changed())
        .await
        .unwrap()
        .unwrap();
    updates.borrow_and_update();
    fs::write(
        folder.join("SKILL.md"),
        markdown("test-routine").replace("Useful routine.", "Changed by hand."),
    )
    .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            updates.changed().await.unwrap();
            if updates
                .borrow_and_update()
                .iter()
                .any(|skill| skill.description == "Changed by hand.")
            {
                break;
            }
        }
    })
    .await
    .unwrap();
    fs::remove_dir_all(folder).unwrap();
    wait(&mut updates, false).await;
}
#[tokio::test]
async fn memory_tools_pagination_forget_and_prompt_budget() {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(
        PersistentMemoryStore::with_directory(
            directory.path().into(),
            Arc::new(Completion::default()),
        )
        .unwrap(),
    );
    let provider = MemoryToolProvider::new(store.clone());
    assert!(
        !call(&provider, "remember", json!({"text":"Harbor uses Swift."}))
            .await
            .is_error
    );
    let item = store.items().await[0].clone();
    assert!(call(
        &provider,
        "search_memories",
        json!({"query":"harbor swift"})
    )
    .await
    .content
    .contains(&item.id.to_string()));
    assert!(
        call(&provider, "forget", json!({"id":"not-an-id"}))
            .await
            .is_error
    );
    assert!(
        !call(&provider, "forget", json!({"id":item.id}))
            .await
            .is_error
    );
    for index in 0..30 {
        store
            .remember(&format!(
                "Preference {index} with a moderately long explanation."
            ))
            .await
            .unwrap();
    }
    let prompt = MemoryToolProvider::with_prompt_character_budget(store.clone(), 700)
        .system_prompt_section()
        .await
        .unwrap();
    assert!(prompt.chars().count() <= 700);
    assert!(prompt.contains("Only recently confirmed"));
    let full = provider.system_prompt_section().await.unwrap();
    assert!(!full.contains("Only recently confirmed"));
    for item in store.items().await {
        assert!(full.contains(&item.text));
    }
    let result = call(&provider, "search_memories", json!({"query":"","offset":0})).await;
    let result: Value = serde_json::from_str(&result.content).unwrap();
    assert_eq!(result["memories"].as_array().unwrap().len(), 20);
    assert_eq!(result["next_offset"], 20);
    assert!(
        call(
            &provider,
            "search_memories",
            json!({"query":"","offset":-1})
        )
        .await
        .is_error
    );
}

struct FailedCompletion;
#[async_trait]
impl TextCompletionService for FailedCompletion {
    async fn complete(&self, _: &str, _: &str, _: ModelTier) -> Result<String, AgentFailure> {
        Err(AgentFailure::Other {
            message: "Offline.".into(),
        })
    }
}
#[tokio::test]
async fn outages_and_surrounding_fence_commentary_leave_memory_unchanged() {
    let directory = tempfile::tempdir().unwrap();
    let failed = PersistentMemoryStore::with_directory(
        directory.path().join("failed"),
        Arc::new(FailedCompletion),
    )
    .unwrap();
    let item = failed.remember("Durable fact.").await.unwrap();
    failed.learn("Thanks!", "Okay.").await;
    failed.finish_pending_learning().await;
    assert_eq!(failed.items().await, vec![item]);
    let service = Arc::new(Completion::default());
    service.replies.lock().unwrap().push_back(
        "```json\n{\"add\":[\"Wrong.\"],\"rewrite\":[],\"remove\":[]}\n```\nExtra commentary"
            .into(),
    );
    let store =
        PersistentMemoryStore::with_directory(directory.path().join("fenced"), service).unwrap();
    store.learn("x", "y").await;
    store.finish_pending_learning().await;
    assert!(store.items().await.is_empty());
}
