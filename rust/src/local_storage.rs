use crate::{
    atomic_file::{write as atomic_write, write_json as atomic_json},
    comic_queue::Options,
    local::LocalLibrary,
    local_operations::{join, name, saf, Files},
    script::Engine,
};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::Arc,
};

pub(crate) static FILES: tokio::sync::RwLock<()> = tokio::sync::RwLock::const_new(());

pub(crate) fn active(engine: &Engine, fallback: &str) -> String {
    engine
        .local_root
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_else(|| fallback.into())
}

fn set_active(engine: &Engine, path: &str) {
    *engine.local_root.write().unwrap_or_else(|e| e.into_inner()) = Some(path.into());
}

fn normalized(path: &str) -> String {
    path.trim_end_matches(['/', '\\']).replace('\\', "/")
}

pub(crate) fn member(root: &str, path: &str) -> Option<String> {
    let root = normalized(root);
    let path = normalized(path);
    let prefix = path.get(..root.len())?;
    let equal =
        prefix == root || (cfg!(windows) && !saf(&root) && root.eq_ignore_ascii_case(prefix));
    if !equal {
        return None;
    }
    path.get(root.len()..)?
        .strip_prefix('/')
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
}

fn contains(root: &str, path: &str) -> bool {
    if cfg!(windows) && !saf(root) {
        normalized(root).eq_ignore_ascii_case(&normalized(path)) || member(root, path).is_some()
    } else {
        normalized(root) == normalized(path) || member(root, path).is_some()
    }
}

fn identity(path: &str) -> Result<String> {
    if saf(path) {
        return Ok(normalized(path));
    }
    Ok(fs::canonicalize(path)?.to_string_lossy().into_owned())
}

fn pointer(data: &str) -> PathBuf {
    Path::new(data).join("local_path")
}
fn journal_path(data: &str) -> PathBuf {
    Path::new(data).join("storage_move.json")
}

fn read_optional(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(crate) async fn initialize(
    engine: Arc<Engine>,
    data: &str,
    default: &str,
    prefer_existing: bool,
    android: bool,
) -> Result<String> {
    let _guard = FILES.write().await;
    let files = Files::new(engine.clone());
    if let Err(error) = recover(&files, data).await {
        eprintln!("Storage migration needs cleanup: {error:#}");
    }
    let legacy = join(data, "local");
    let mut candidates = Vec::new();
    if let Some(saved) = read_optional(&pointer(data))? {
        if files.exists(&saved).await.unwrap_or(false) {
            candidates.push(saved);
        }
    }
    if prefer_existing && fs::read_dir(&legacy).is_ok_and(|mut entries| entries.next().is_some()) {
        candidates.push(legacy.clone());
    }
    candidates.extend([default.to_owned(), legacy]);
    let mut last_error = None;
    for path in candidates {
        match initialize_path(&files, &path, android).await {
            Ok(()) => {
                set_active(&engine, &path);
                return Ok(path);
            }
            Err(error) => last_error = Some(error.context(format!("Unable to use {path}"))),
        }
    }
    Err(last_error.context("No storage directory available")?)
}

async fn initialize_path(files: &Files, path: &str, android: bool) -> Result<()> {
    if !saf(path) {
        fs::create_dir_all(path)?;
    }
    ensure!(
        files.exists(path).await?,
        "Storage directory does not exist"
    );
    let test = join(path, &format!(".venera-probe-{}", uuid::Uuid::new_v4()));
    touch(files, &test).await?;
    remove_file(files, &test).await?;
    if android {
        nomedia(files, path).await?;
    }
    Ok(())
}

async fn nomedia(files: &Files, root: &str) -> Result<()> {
    let path = join(root, ".nomedia");
    if !files.exists(&path).await? {
        touch(files, &path).await?;
    }
    Ok(())
}

async fn touch(files: &Files, path: &str) -> Result<()> {
    if saf(path) {
        files.platform("touch", path, None).await?;
    } else {
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)?;
    }
    Ok(())
}

async fn remove_file(files: &Files, path: &str) -> Result<()> {
    if saf(path) {
        files.platform("removeFile", path, None).await?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

async fn remove_empty(files: &Files, path: &str) -> Result<()> {
    if files.exists(path).await? && files.list(path).await?.is_empty() {
        if saf(path) {
            files.platform("removeEmpty", path, None).await?;
        } else {
            fs::remove_dir(path)?;
        }
    }
    Ok(())
}

async fn digest(files: &Files, path: &str) -> Result<String> {
    if saf(path) {
        let bytes = files.platform("read", path, None).await?;
        return Ok(format!(
            "{:x}",
            Sha256::digest(crate::script_crypto::bytes(&bytes)?)
        ));
    }
    let path = path.to_owned();
    tokio::task::spawn_blocking(move || -> Result<String> {
        let mut hash = Sha256::new();
        let mut file = fs::File::open(&path)?;
        ensure!(
            fs::symlink_metadata(&path)?.is_file(),
            "Not an ordinary file: {path}"
        );
        let mut buffer = vec![0; 64 * 1024];
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            hash.update(&buffer[..n]);
        }
        Ok(format!("{:x}", hash.finalize()))
    })
    .await?
}

#[derive(Serialize, Deserialize)]
struct Item {
    relative: String,
    digest: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Move {
    old: String,
    new: String,
    token: String,
    entries: Vec<Item>,
    promoted: Vec<String>,
}

impl Move {
    fn stage(&self) -> String {
        join(&self.new, &format!(".venera-move-{}", self.token))
    }
}

async fn stage_copy(files: &Files, migration: &mut Move) -> Result<()> {
    let stage = migration.stage();
    let mut pending = vec![String::new()];
    while let Some(parent) = pending.pop() {
        let source = if parent.is_empty() {
            migration.old.clone()
        } else {
            join(&migration.old, &parent)
        };
        for entry in files.list(&source).await? {
            let leaf = name(&entry.path);
            ensure!(
                crate::archives::safe_relative(leaf)?.components().count() == 1,
                "Invalid storage entry"
            );
            let relative = if parent.is_empty() {
                leaf.to_owned()
            } else {
                join(&parent, leaf)
            };
            let input = join(&migration.old, &relative);
            let destination = join(&stage, &relative);
            let digest = if entry.is_dir {
                files.mkdir(&destination).await?;
                pending.push(relative.clone());
                None
            } else {
                files.copy(&input, &destination).await?;
                let copied = digest(files, &destination).await?;
                ensure!(
                    digest(files, &input).await? == copied,
                    "File changed during storage copy: {input}"
                );
                Some(copied)
            };
            migration.entries.push(Item { relative, digest });
        }
    }
    Ok(())
}

async fn promote(files: &Files, migration: &mut Move, journal: &Path) -> Result<()> {
    let staged = migration
        .entries
        .iter()
        .filter(|item| !item.relative.contains('/'))
        .map(|item| (item.relative.clone(), item.digest.is_none()))
        .collect::<Vec<_>>();
    for (relative, directory) in staged {
        let from = join(&migration.stage(), &relative);
        let to = join(&migration.new, &relative);
        ensure!(
            !files.exists(&to).await?,
            "Storage destination changed: {to}"
        );
        migration.promoted.push(relative.clone());
        atomic_json(journal, migration)?;
        if saf(&to) {
            // Some document providers implement a directory move as copy and
            // delete. Keep that operation in Rust so a successful receipt
            // cannot hide missing descendants.
            let prefix = format!("{relative}/");
            for item in &migration.entries {
                if item.relative == relative || item.relative.starts_with(&prefix) {
                    let target = join(&migration.new, &item.relative);
                    ensure!(
                        !files.exists(&target).await?,
                        "Storage destination changed: {target}"
                    );
                    if let Some(expected) = &item.digest {
                        files
                            .copy(&join(&migration.stage(), &item.relative), &target)
                            .await?;
                        ensure!(
                            digest(files, &target).await? == *expected,
                            "Storage copy verification failed: {target}"
                        );
                    } else {
                        files.mkdir(&target).await?;
                    }
                }
            }
        } else if directory {
            files.rename(&from, &to).await?;
        } else {
            if fs::hard_link(&from, &to).is_err() {
                files.copy(&from, &to).await?;
            }
            remove_file(files, &from).await?;
        }
    }
    Ok(())
}

pub(crate) async fn relocate(
    engine: Arc<Engine>,
    options: &Options,
    destination: &str,
    android: bool,
) -> Result<Vec<String>> {
    let _storage = crate::backup_storage::OPERATIONS.read().await;
    let _guard = FILES.write().await;
    let files = Files::new(engine.clone());
    recover(&files, &options.data_path).await?;
    let old = active(&engine, &options.local_path);
    let old_id = identity(&old)?;
    let new_id = identity(destination)?;
    if normalized(&old_id) == normalized(&new_id) {
        set_active(&engine, &old);
        return Ok(vec![]);
    }
    let data_id = identity(&options.data_path)?;
    ensure!(
        !contains(&old_id, &new_id) && !contains(&new_id, &old_id) && !contains(&new_id, &data_id),
        "Storage directories must not overlap"
    );
    ensure!(
        files.list(destination).await?.is_empty(),
        "Directory is not empty"
    );
    // A previously saved provider may have been unavailable at startup. Make
    // the active fallback explicit before using this path as the commit marker.
    if read_optional(&pointer(&options.data_path))?.as_deref() == Some(destination) {
        atomic_write(&pointer(&options.data_path), old.as_bytes())?;
    }
    let journal = journal_path(&options.data_path);
    let mut migration = Move {
        old,
        new: destination.into(),
        token: uuid::Uuid::new_v4().to_string(),
        entries: Vec::new(),
        promoted: Vec::new(),
    };
    atomic_json(&journal, &migration)?;
    let result = async {
        files.mkdir(&migration.stage()).await?;
        stage_copy(&files, &mut migration).await?;
        promote(&files, &mut migration, &journal).await?;
        LocalLibrary::open(&join(&options.data_path, "local.db"))?
            .relativize_storage(&migration.old)?;
        atomic_write(&pointer(&options.data_path), destination.as_bytes())?;
        Ok::<_, anyhow::Error>(())
    }
    .await;
    if result.is_ok() {
        set_active(&engine, destination);
    }
    let cleanup = recover(&files, &options.data_path).await;
    if let Err(error) = result {
        return Err(match cleanup {
            Ok(warnings) if warnings.is_empty() => error,
            Ok(warnings) => error.context(warnings.join("\n")),
            Err(recovery) => error.context(format!("Storage rollback pending: {recovery:#}")),
        });
    }
    let mut warnings = cleanup
        .unwrap_or_else(|error| vec![format!("Previous directory cleanup pending: {error:#}")]);
    if android {
        if let Err(error) = nomedia(&files, destination).await {
            warnings.push(format!("{error:#}"));
        }
    }
    Ok(warnings)
}

async fn recover(files: &Files, data: &str) -> Result<Vec<String>> {
    let journal = journal_path(data);
    let Some(contents) = read_optional(&journal)? else {
        return Ok(vec![]);
    };
    let migration: Move = serde_json::from_str(&contents)?;
    uuid::Uuid::parse_str(&migration.token).context("Invalid storage move token")?;
    let committed = read_optional(&pointer(data))?.as_deref() == Some(&migration.new);
    // Before commit remove verified copies only. After commit retain files with
    // external edits and leave them in the old root for the user to reconcile.
    let (remove_root, keep_root) = if committed {
        (&migration.old, &migration.new)
    } else {
        (&migration.new, &migration.old)
    };
    let mut warnings = Vec::new();
    for item in migration.entries.iter().rev() {
        crate::archives::safe_relative(&item.relative)?;
        let root_entry = item.relative.split('/').next().unwrap_or_default();
        if !committed && !migration.promoted.iter().any(|name| name == root_entry) {
            continue;
        }
        let path = join(remove_root, &item.relative);
        if let Some(expected) = &item.digest {
            let kept = join(keep_root, &item.relative);
            if files.exists(&path).await? {
                if files.exists(&kept).await?
                    && digest(files, &path).await? == *expected
                    && digest(files, &kept).await? == *expected
                {
                    remove_file(files, &path).await?;
                } else {
                    warnings.push(format!("Kept changed or unverified file: {path}"));
                }
            }
        } else {
            remove_empty(files, &path).await?;
        }
    }
    files.remove(&migration.stage()).await?;
    fs::remove_file(journal).context("Cannot finalize storage move journal")?;
    Ok(warnings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn interrupted_moves_only_remove_verified_duplicates() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let root = directory.path().to_string_lossy();
        let old = join(&root, "old");
        let new = join(&root, "new");
        for path in [&old, &new] {
            fs::create_dir(path)?;
            fs::write(join(path, "same.jpg"), b"verified")?;
        }
        fs::write(join(&old, "changed.jpg"), b"verified")?;
        fs::write(join(&new, "changed.jpg"), b"user edits")?;
        let engine = Arc::new(Engine::open(serde_json::from_value(json!({
            "data_path": root, "version": "1.6.3", "locale": "en_US", "platform": "windows",
            "user_agent": "test", "http": {
                "proxy": null, "dns_overrides": {}, "tls_sni": true, "verify_certificates": true,
                "connect_timeout_ms": 1000, "receive_timeout_ms": 1000, "max_redirects": 5
            }
        }))?)?);
        let files = Files::new(engine);
        let migration = Move {
            old: old.clone(),
            new: new.clone(),
            token: uuid::Uuid::new_v4().to_string(),
            entries: ["same.jpg", "changed.jpg"]
                .into_iter()
                .map(|name| Item {
                    relative: name.to_owned(),
                    digest: Some(format!("{:x}", Sha256::digest(b"verified"))),
                })
                .collect(),
            promoted: vec!["same.jpg".into(), "changed.jpg".into()],
        };
        fs::create_dir(migration.stage())?;
        atomic_json(&journal_path(&root), &migration)?;
        assert_eq!(recover(&files, &root).await?.len(), 1);
        assert!(Path::new(&join(&old, "same.jpg")).is_file());
        assert!(!Path::new(&join(&new, "same.jpg")).exists());
        assert_eq!(fs::read(join(&new, "changed.jpg"))?, b"user edits");
        assert!(!Path::new(&migration.stage()).exists());

        fs::write(join(&new, "same.jpg"), b"verified")?;
        atomic_json(&journal_path(&root), &migration)?;
        atomic_write(&pointer(&root), new.as_bytes())?;
        assert_eq!(recover(&files, &root).await?.len(), 1);
        assert!(!Path::new(&join(&old, "same.jpg")).exists());
        assert!(Path::new(&join(&old, "changed.jpg")).is_file());
        assert!(Path::new(&join(&new, "same.jpg")).is_file());
        Ok(())
    }
}
