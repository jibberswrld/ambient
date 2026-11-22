use super::*;
pub(crate) struct SkillDocument {
    pub name: String,
    pub description: String,
    pub instructions: String,
}
pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !name.starts_with('-')
        && !name.ends_with('-')
        && !name.contains("--")
}
impl SkillDocument {
    pub fn parse(markdown: &str) -> Result<Self, String> {
        let normalized = markdown.replace("\r\n", "\n");
        let lines: Vec<_> = normalized.split('\n').collect();
        let closing = lines
            .iter()
            .enumerate()
            .skip(1)
            .find(|(_, line)| **line == "---")
            .map(|(index, _)| index);
        if lines.first() != Some(&"---") || closing.is_none() {
            return Err("SKILL.md must begin with YAML frontmatter between --- lines.".into());
        }
        let closing = closing.unwrap();
        let mut fields = BTreeMap::new();
        let mut index = 1;
        while index < closing {
            let line = lines[index];
            index += 1;
            if line.starts_with([' ', '\t']) {
                continue;
            }
            let Some((key, raw)) = line.split_once(':') else {
                continue;
            };
            let key = key.trim();
            let raw = raw.trim();
            if key != "name" && key != "description" {
                continue;
            }
            if fields.contains_key(key) {
                return Err(format!("Duplicate {key} in skill frontmatter."));
            }
            let value = if [">", ">-", ">+", "|", "|-", "|+"].contains(&raw) {
                let mut block = vec![];
                while index < closing
                    && (lines[index].is_empty() || lines[index].starts_with([' ', '\t']))
                {
                    block.push(lines[index].trim());
                    index += 1;
                }
                block.join(if raw.starts_with('>') { " " } else { "\n" })
            } else if raw.starts_with('"') {
                serde_json::from_str::<String>(raw)
                    .map_err(|_| format!("Invalid quoted {key} in skill frontmatter."))?
            } else if raw.starts_with('\'') {
                if raw.len() < 2 || !raw.ends_with('\'') {
                    return Err("Unclosed quote in skill frontmatter.".into());
                }
                raw[1..raw.len() - 1].replace("''", "'")
            } else {
                if raw.starts_with(['[', '{', '&', '*']) {
                    return Err(format!("Skill {key} must be text."));
                }
                raw.split(" #").next().unwrap_or(raw).into()
            };
            fields.insert(key, value);
        }
        let name = fields
            .get("name")
            .map(|value| value.trim())
            .unwrap_or("")
            .to_string();
        if !valid_name(&name) {
            return Err("Skill name must be 1–64 lowercase letters, digits or single hyphens, beginning and ending with a letter or digit.".into());
        }
        let description = fields
            .get("description")
            .map(|value| value.trim())
            .unwrap_or("")
            .to_string();
        let instructions = lines[closing + 1..].join("\n").trim().to_string();
        if description.is_empty() || instructions.is_empty() {
            return Err("SKILL.md needs a nonempty description and instructions.".into());
        }
        Ok(Self {
            name,
            description,
            instructions,
        })
    }
}
pub(crate) fn files(folder: &Path) -> Result<Vec<String>, String> {
    fn visit(root: &Path, folder: &Path, paths: &mut Vec<String>) -> Result<(), String> {
        let metadata = io(fs::symlink_metadata(folder))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err("A skill must be a real folder, not a symbolic link.".into());
        }
        for entry in io(fs::read_dir(folder))? {
            let path = io(entry)?.path();
            let metadata = io(fs::symlink_metadata(&path))?;
            if metadata.file_type().is_symlink() || (!metadata.is_dir() && !metadata.is_file()) {
                return Err("Skills may contain only regular files and folders; symbolic links are not allowed.".into());
            }
            if metadata.is_dir() {
                visit(root, &path, paths)?;
            } else {
                paths.push(
                    path.strip_prefix(root)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/"),
                );
            }
        }
        Ok(())
    }
    let mut paths = vec![];
    visit(folder, folder, &mut paths)?;
    paths.sort();
    Ok(paths)
}
pub(crate) fn document(folder: &Path) -> Result<SkillDocument, String> {
    files(folder)?;
    SkillDocument::parse(&io(fs::read_to_string(folder.join("SKILL.md")))?)
}
pub(crate) fn contained(folder: &Path, path: &str) -> Result<PathBuf, String> {
    if path.is_empty()
        || path.contains(['\\', ':'])
        || path.split('/').any(|part| {
            let stem = part
                .split('.')
                .next()
                .unwrap_or_default()
                .to_ascii_uppercase();
            part.is_empty()
                || part == "."
                || part == ".."
                || part.ends_with([' ', '.'])
                || part
                    .chars()
                    .any(|character| character.is_control() || "<>\"|?*".contains(character))
                || ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
                || ((stem.starts_with("COM") || stem.starts_with("LPT"))
                    && stem.len() == 4
                    && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        })
    {
        return Err(
            "Use a relative file path inside the skill folder, without . or .. components.".into(),
        );
    }
    let mut candidate = folder.to_path_buf();
    for part in path.split('/') {
        candidate.push(part);
        if let Ok(metadata) = fs::symlink_metadata(&candidate) {
            if metadata.file_type().is_symlink() {
                return Err("The requested file is outside the skill folder.".into());
            }
        }
    }
    Ok(candidate)
}
pub(crate) fn copy_folder(source: &Path, destination: &Path) -> Result<(), String> {
    let paths = files(source)?;
    io(fs::create_dir_all(destination))?;
    for relative in paths {
        let target = destination.join(&relative);
        io(fs::create_dir_all(target.parent().unwrap()))?;
        io(fs::copy(source.join(relative), target))?;
    }
    Ok(())
}
pub struct FileSkillStore {
    directory: PathBuf,
    built_in_directory: PathBuf,
    updates: watch::Sender<Vec<SkillSummary>>,
    fingerprint: Mutex<Vec<u8>>,
    mutation: Mutex<()>,
}
impl FileSkillStore {
    pub fn new() -> Result<Self, String> {
        Self::with_directory(ambient_data_directory().join("skills"))
    }
    pub fn with_directory(directory: PathBuf) -> Result<Self, String> {
        let built_in_directory = directory
            .parent()
            .ok_or("Missing parent directory.")?
            .join("built-in-skills");
        for (name, markdown) in [
            (
                "daily-brief",
                include_str!("../BuiltInSkills/daily-brief/SKILL.md"),
            ),
            (
                "delegate-coding-task",
                include_str!("../BuiltInSkills/delegate-coding-task/SKILL.md"),
            ),
            (
                "inbox-triage",
                include_str!("../BuiltInSkills/inbox-triage/SKILL.md"),
            ),
            (
                "meeting-prep",
                include_str!("../BuiltInSkills/meeting-prep/SKILL.md"),
            ),
        ] {
            atomic_write(
                &built_in_directory.join(name).join("SKILL.md"),
                markdown.as_bytes(),
            )?;
        }
        io(fs::create_dir_all(&directory))?;
        let (updates, _) = watch::channel(vec![]);
        let store = Self {
            directory,
            built_in_directory,
            updates,
            fingerprint: Default::default(),
            mutation: Default::default(),
        };
        store.refresh();
        Ok(store)
    }
    fn refresh(&self) {
        let mut catalog = BTreeMap::new();
        let mut fingerprint = vec![];
        for (root, is_built_in) in [(&self.built_in_directory, true), (&self.directory, false)] {
            let Ok(entries) = fs::read_dir(root) else {
                continue;
            };
            let mut paths: Vec<_> = entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .collect();
            paths.sort();
            for folder in paths {
                if folder
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .starts_with('.')
                {
                    continue;
                }
                let Ok(document) = document(&folder) else {
                    continue;
                };
                if folder.file_name().unwrap_or_default() != document.name.as_str() {
                    continue;
                }
                for relative in files(&folder).unwrap_or_default() {
                    fingerprint.extend_from_slice(relative.as_bytes());
                    fingerprint.extend(fs::read(folder.join(relative)).unwrap_or_default());
                }
                catalog.insert(
                    document.name.clone(),
                    SkillSummary {
                        name: document.name,
                        description: document.description,
                        is_built_in,
                        directory: folder,
                    },
                );
            }
        }
        let catalog: Vec<_> = catalog.into_values().collect();
        let mut previous = self.fingerprint.lock().unwrap();
        if *previous != fingerprint || *self.updates.borrow() != catalog {
            *previous = fingerprint;
            self.updates.send_replace(catalog);
        }
    }
    fn find(&self, name: &str) -> Result<SkillSummary, String> {
        self.refresh();
        self.updates
            .borrow()
            .iter()
            .find(|skill| skill.name == name && valid_name(name))
            .cloned()
            .ok_or_else(|| format!("No skill named {name} is available."))
    }
    pub async fn load(&self, skill_name: &str) -> Result<(String, Vec<String>), String> {
        let skill = self.find(skill_name)?;
        Ok((
            document(&skill.directory)?.instructions,
            files(&skill.directory)?,
        ))
    }
    pub async fn read_file(&self, skill_name: &str, relative_path: &str) -> Result<String, String> {
        let skill = self.find(skill_name)?;
        io(fs::read_to_string(contained(
            &skill.directory,
            relative_path,
        )?))
    }
    pub async fn write_skill(
        &self,
        markdown: &str,
        supporting_files: &BTreeMap<String, String>,
        updating: Option<&str>,
    ) -> Result<(), String> {
        super::tools::write_skill(self, markdown, supporting_files, updating).await
    }
}
#[async_trait]
impl SkillStore for FileSkillStore {
    async fn skills(&self) -> Vec<SkillSummary> {
        self.refresh();
        self.updates.borrow().clone()
    }
    fn updates(&self) -> watch::Receiver<Vec<SkillSummary>> {
        // A rescan observes nested edits and atomic folder replacements on both platforms.
        let receiver = self.updates.subscribe();
        let directory = self.directory.clone();
        let built_in_directory = self.built_in_directory.clone();
        let updates = self.updates.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let scanner = FileSkillStore {
                    directory,
                    built_in_directory,
                    updates,
                    fingerprint: Default::default(),
                    mutation: Default::default(),
                };
                while scanner.updates.receiver_count() > 0 {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    scanner.refresh();
                }
            });
        }
        receiver
    }
    async fn install(&self, source: &Path) -> Result<(), String> {
        let _guard = self.mutation.lock().unwrap();
        let metadata = document(source)?;
        let staging = io(tempfile::Builder::new()
            .prefix(".install-")
            .tempdir_in(&self.directory))?;
        copy_folder(source, staging.path())?;
        document(staging.path())?;
        let destination = self.directory.join(metadata.name);
        let backup = self.directory.join(format!(".backup-{}", Uuid::new_v4()));
        let existed = destination.exists();
        if existed {
            io(fs::rename(&destination, &backup))?;
        }
        if let Err(error) = fs::rename(staging.path(), &destination) {
            if existed {
                let _ = fs::rename(&backup, &destination);
            }
            return Err(error.to_string());
        }
        if existed {
            let _ = fs::remove_dir_all(backup);
        }
        self.refresh();
        Ok(())
    }
    async fn delete(&self, skill_name: &str) -> Result<(), String> {
        let _guard = self.mutation.lock().unwrap();
        let skill = self.find(skill_name)?;
        if skill.is_built_in {
            return Err(format!("{skill_name} is built in and cannot be deleted. A personal skill with the same name can override it."));
        }
        io(fs::remove_dir_all(skill.directory))?;
        self.refresh();
        Ok(())
    }
}
