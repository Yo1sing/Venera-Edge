use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{fs, path::Path};
const DATABASES: &[&str] = &["history.db", "local_favorite.db", "cookie.db"];

pub fn export(directory: &str, cache: &str, sync: bool) -> Result<String> {
    export_with_data(directory, cache, sync, None)
}

pub fn export_with_data(
    directory: &str,
    cache: &str,
    sync: bool,
    data: Option<&Value>,
) -> Result<String> {
    fs::create_dir_all(cache)?;
    let staging = tempfile::tempdir_in(cache)?;
    let source = Path::new(directory);
    for name in DATABASES {
        let path = source.join(name);
        if path.exists() {
            let db = rusqlite::Connection::open_with_flags(
                path,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )?;
            db.busy_timeout(std::time::Duration::from_secs(10))?;
            db.execute(
                "VACUUM main INTO ?1",
                [staging.path().join(name).to_string_lossy().as_ref()],
            )?;
        }
    }
    let output = Path::new(cache).join(format!("{}.venera", uuid::Uuid::new_v4()));
    crate::archives::write_zip(&output, |zip| {
        for name in DATABASES {
            let path = staging.path().join(name);
            if path.exists() {
                crate::archives::add_file(zip, name, &path)?;
            }
        }
        let settings_path = if let Some(data) = data {
            let path = staging.path().join("appdata.json");
            fs::write(&path, serde_json::to_vec(data)?)?;
            path
        } else {
            source.join(if sync {
                "syncdata.json"
            } else {
                "appdata.json"
            })
        };
        crate::archives::add_file(zip, "appdata.json", &settings_path)?;
        let sources = source.join("comic_source");
        if sources.exists() {
            for entry in fs::read_dir(sources)? {
                let entry = entry?;
                if entry.file_type()?.is_file() {
                    crate::archives::add_file(
                        zip,
                        &format!("comic_source/{}", entry.file_name().to_string_lossy()),
                        &entry.path(),
                    )?;
                }
            }
        }
        Ok(())
    })?;
    Ok(output.to_string_lossy().into_owned())
}

// A version read on the same SQLite connection detects commits in WAL and
// rollback-journal mode. Close these monitors before the Windows file swap.
pub struct LocalState {
    files: std::collections::BTreeMap<std::path::PathBuf, [u8; 32]>,
    databases: Vec<(String, Option<(rusqlite::Connection, i64)>)>,
    revision: Option<i64>,
}

impl LocalState {
    pub fn capture(directory: &str) -> Result<Self> {
        crate::backup_storage::exclusive(|| {
            let root = Path::new(directory);
            let databases = DATABASES
                .iter()
                .map(|name| {
                    let path = root.join(name);
                    let version = if path.exists() {
                        let db = rusqlite::Connection::open_with_flags(
                            path,
                            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
                        )?;
                        db.busy_timeout(std::time::Duration::from_secs(10))?;
                        let version = db.query_row("PRAGMA data_version", [], |row| row.get(0))?;
                        Some((db, version))
                    } else {
                        None
                    };
                    Ok(((*name).to_owned(), version))
                })
                .collect::<Result<_>>()?;
            Ok(Self {
                files: local_files(root)?,
                databases,
                revision: crate::settings::load(directory)?["settings"]["dataVersion"].as_i64(),
            })
        })
    }

    pub fn revision(&self) -> Option<i64> {
        self.revision
    }

    fn unchanged(&self, root: &Path) -> Result<bool> {
        if local_files(root)? != self.files {
            return Ok(false);
        }
        for (name, version) in &self.databases {
            let current = match version {
                Some((db, _)) => {
                    Some(db.query_row("PRAGMA data_version", [], |row| row.get::<_, i64>(0))?)
                }
                None => {
                    if root.join(name).exists() {
                        return Ok(false);
                    }
                    None
                }
            };
            if current != version.as_ref().map(|(_, version)| *version) {
                return Ok(false);
            }
        }
        Ok(true)
    }
}

fn local_files(root: &Path) -> Result<std::collections::BTreeMap<std::path::PathBuf, [u8; 32]>> {
    use sha2::{Digest, Sha256};
    let mut files = std::collections::BTreeMap::new();
    let mut paths = vec![root.join("appdata.json")];
    match fs::read_dir(root.join("comic_source")) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                if entry.file_type()?.is_file() {
                    paths.push(entry.path());
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    for path in paths {
        match fs::read(&path) {
            Ok(bytes) => {
                files.insert(path, Sha256::digest(bytes).into());
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(files)
}

pub struct Prepared {
    pub staging: tempfile::TempDir,
    pub data: Option<Value>,
}
pub fn prepare(input: &str, cache: &str, current_version: Option<i64>) -> Result<Option<Prepared>> {
    fs::create_dir_all(cache)?;
    let staging = tempfile::tempdir_in(cache)?;
    crate::archives::extract(Path::new(input), staging.path())?;
    let data = if staging.path().join("appdata.json").exists() {
        let data: Value = serde_json::from_slice(&fs::read(staging.path().join("appdata.json"))?)?;
        ensure!(
            data["settings"].is_object() && data["searchHistory"].is_array(),
            "Invalid backup settings"
        );
        if current_version
            .zip(data["settings"]["dataVersion"].as_i64())
            .is_some_and(|(current, incoming)| incoming <= current)
        {
            return Ok(None);
        }
        Some(data)
    } else {
        None
    };
    for name in DATABASES {
        let path = staging.path().join(name);
        if path.exists() {
            let db = rusqlite::Connection::open_with_flags(
                path,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )?;
            let check: String = db.query_row("PRAGMA quick_check", [], |r| r.get(0))?;
            ensure!(check == "ok", "Corrupt database in backup: {name}");
        }
    }
    ensure!(
        data.is_some() || DATABASES.iter().any(|n| staging.path().join(n).exists()),
        "Empty or invalid backup"
    );
    Ok(Some(Prepared { staging, data }))
}
fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    if from.is_dir() {
        fs::create_dir_all(to)?;
        for entry in fs::read_dir(from)? {
            let entry = entry?;
            ensure!(!entry.file_type()?.is_symlink(), "Backup symlink rejected");
            copy_tree(&entry.path(), &to.join(entry.file_name()))?;
        }
    } else {
        fs::copy(from, to)?;
    }
    Ok(())
}
impl Prepared {
    pub fn apply_checked(&self, directory: &str, local: Option<LocalState>) -> Result<String> {
        let root = Path::new(directory);
        fs::create_dir_all(root)?;
        let staging = tempfile::tempdir_in(root)?;
        let rollback = tempfile::tempdir_in(root)?;
        let mut names = Vec::new();
        for name in DATABASES
            .iter()
            .copied()
            .chain(std::iter::once("comic_source"))
        {
            let source = self.staging.path().join(name);
            if source.exists() {
                copy_tree(&source, &staging.path().join(name))?;
                names.push(name.to_owned());
            }
        }
        crate::backup_storage::exclusive(|| {
            if let Some(local) = local {
                ensure!(
                    local.unchanged(root)?,
                    "Local data changed while the backup was being prepared; the backup was not applied"
                );
            }
            let mut current = crate::settings::load(directory)?;
            if let Some(data) = &self.data {
                let revision = current["settings"]["dataVersion"].as_u64().unwrap_or(0);
                current = crate::settings::merge(current, data.clone())?;
                if current["settings"]["dataVersion"].as_u64().unwrap_or(0) < revision {
                    current["settings"]["dataVersion"] = revision.into();
                }
                crate::settings::save(
                    staging.path().to_str().context("Invalid backup path")?,
                    current.clone(),
                )?;
                names.extend(["appdata.json".into(), "syncdata.json".into()]);
            }
            crate::backup_storage::disconnect(root)?;
            let mut installed = Vec::new();
            let mut saved = Vec::new();
            let result = (|| -> Result<()> {
                // Include SQLite sidecars in rollback after all live handles are disconnected.
                for name in &names {
                    for candidate in std::iter::once(name.clone()).chain(if name.ends_with(".db") {
                        vec![
                            format!("{name}-wal"),
                            format!("{name}-shm"),
                            format!("{name}-journal"),
                        ]
                    } else {
                        vec![]
                    }) {
                        if root.join(&candidate).exists() {
                            fs::rename(root.join(&candidate), rollback.path().join(&candidate))?;
                            saved.push(candidate);
                        }
                    }
                    fs::rename(staging.path().join(name), root.join(name))?;
                    installed.push(name.clone());
                }
                Ok(())
            })();
            if let Err(error) = result {
                let recovery = (|| -> Result<()> {
                    for name in installed.iter().rev() {
                        let path = root.join(name);
                        if path.is_dir() {
                            fs::remove_dir_all(path)?;
                        } else {
                            fs::remove_file(path)?;
                        }
                    }
                    for name in saved.iter().rev() {
                        fs::rename(rollback.path().join(name), root.join(name))?;
                    }
                    Ok(())
                })();
                if let Err(recovery_error) = recovery {
                    let retained = rollback.keep();
                    anyhow::bail!("Restore failed: {error:#}; rollback failed: {recovery_error:#}. Original files retained at {}",retained.display());
                }
                return Err(error);
            }
            Ok(
                json!({"data":current,"sourcesChanged":names.iter().any(|n|n=="comic_source")})
                    .to_string(),
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_live_sqlite_edits_and_reopens_existing_handles() -> Result<()> {
        let root = tempfile::tempdir()?;
        let cache = tempfile::tempdir()?;
        let path = root.path().to_str().unwrap();
        crate::settings::save(
            path,
            json!({"settings":{"dataVersion":2},"searchHistory":[]}),
        )?;
        let cookies = crate::api::cookies::CookieStore::open(
            root.path().join("cookie.db").to_string_lossy().into_owned(),
        )?;
        let url = "https://example.test/".to_owned();
        cookies.save_headers(url.clone(), vec!["session=from-backup".into()])?;
        let backup = export(path, cache.path().to_str().unwrap(), false)?;
        let local = LocalState::capture(path)?;
        cookies.save_headers(url.clone(), vec!["session=local-edit".into()])?;
        let prepared = prepare(&backup, cache.path().to_str().unwrap(), None)?.unwrap();
        let error = prepared.apply_checked(path, Some(local)).unwrap_err();
        assert!(error.to_string().contains("Local data changed"));
        assert_eq!(cookies.header(url.clone())?, "session=local-edit");

        let old_generation = cookies.generation()?;
        prepared.apply_checked(path, None)?;
        assert_ne!(cookies.generation()?, old_generation);
        cookies.save_response(
            &url,
            vec!["session=stale-response".into()],
            None,
            old_generation,
        )?;
        assert_eq!(cookies.header(url)?, "session=from-backup");
        Ok(())
    }

    #[cfg(windows)]
    #[test]
    fn restore_rolls_back_database_when_settings_file_cannot_be_replaced() -> Result<()> {
        use std::os::windows::fs::OpenOptionsExt;
        let root = tempfile::tempdir()?;
        let cache = tempfile::tempdir()?;
        let path = root.path().to_str().unwrap();
        crate::settings::save(
            path,
            json!({"settings":{"dataVersion":2},"searchHistory":["backup"]}),
        )?;
        let cookies = crate::api::cookies::CookieStore::open(
            root.path().join("cookie.db").to_string_lossy().into_owned(),
        )?;
        let url = "https://example.test/".to_owned();
        cookies.save_headers(url.clone(), vec!["session=from-backup".into()])?;
        let backup = export(path, cache.path().to_str().unwrap(), false)?;
        cookies.save_headers(url.clone(), vec!["session=local-edit".into()])?;
        crate::settings::save(
            path,
            json!({"settings":{"dataVersion":3},"searchHistory":["local"]}),
        )?;
        let _lock = fs::OpenOptions::new()
            .read(true)
            .share_mode(0x1 | 0x2) // Permit reading/writing the live file, but deny replacing it.
            .open(root.path().join("appdata.json"))?;
        let prepared = prepare(&backup, cache.path().to_str().unwrap(), None)?.unwrap();
        assert!(prepared.apply_checked(path, None).is_err());
        assert_eq!(cookies.header(url)?, "session=local-edit");
        assert_eq!(
            crate::settings::load(path)?["searchHistory"],
            json!(["local"])
        );
        Ok(())
    }

    #[test]
    fn backup_snapshots_live_sqlite_and_restores_settings() -> Result<()> {
        let root = tempfile::tempdir()?;
        let cache = tempfile::tempdir()?;
        let path = root.path().to_str().unwrap();
        let db = rusqlite::Connection::open(root.path().join("history.db"))?;
        db.execute_batch("PRAGMA journal_mode=WAL;CREATE TABLE test(value TEXT);INSERT INTO test VALUES ('原始');")?;
        crate::settings::save(
            path,
            json!({"settings":{"dataVersion":2,"proxy":"local"},"searchHistory":["漫画"]}),
        )?;
        let backup = export(path, cache.path().to_str().unwrap(), false)?;
        db.execute("UPDATE test SET value='changed'", [])?;
        drop(db);
        let prepared = prepare(&backup, cache.path().to_str().unwrap(), Some(1))?.unwrap();
        prepared.apply_checked(path, None)?;
        let db = rusqlite::Connection::open(root.path().join("history.db"))?;
        assert_eq!(
            db.query_row("SELECT value FROM test", [], |r| r.get::<_, String>(0))?,
            "原始"
        );
        assert!(prepare(&backup, cache.path().to_str().unwrap(), Some(2))?.is_none());
        Ok(())
    }
}
