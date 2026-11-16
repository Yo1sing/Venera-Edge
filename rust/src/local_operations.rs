use crate::{
    api::http::HttpCancellation,
    favorites::{Favorite, Favorites, Key},
    local::{LocalComic, LocalLibrary},
    script::Engine,
};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    path::Path,
    sync::Arc,
};

#[derive(Clone, Deserialize)]
pub struct Options {
    pub data_path: String,
    pub cache_path: String,
    pub local_path: String,
    #[serde(default)]
    pub traditional: bool,
    #[serde(default)]
    pub at_end: bool,
}

#[derive(Default, Serialize)]
struct Outcome {
    images: Vec<String>,
    imported: Vec<LocalComic>,
    removed: Vec<Value>,
    skipped: Vec<String>,
    errors: Vec<Value>,
    cancelled: bool,
    recovered: usize,
    recovery_pending: bool,
}

pub struct Operation {
    cancel: Arc<HttpCancellation>,
    pub receiver: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<String>>,
}

struct Worker {
    cancel: Arc<HttpCancellation>,
    sender: tokio::sync::mpsc::Sender<String>,
}

impl Drop for Operation {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

impl Operation {
    pub fn start(engine: Arc<Engine>, options: Options, request: Value) -> Result<Arc<Self>> {
        let (sender, receiver) = tokio::sync::mpsc::channel(16);
        let operation = Arc::new(Self {
            cancel: Arc::new(HttpCancellation::new()),
            receiver: tokio::sync::Mutex::new(receiver),
        });
        let worker = Worker {
            cancel: operation.cancel.clone(),
            sender,
        };
        std::thread::Builder::new()
            .name("venera-local-operation".into())
            .spawn(move || {
                crate::script::executor().block_on(async move {
                    let mut outcome = Outcome::default();
                    let files = Files {
                        engine,
                        cancel: worker.cancel.clone(),
                    };
                    let result = worker.run(&files, &options, request, &mut outcome).await;
                    if let Err(error) = result {
                        outcome.recovery_pending |=
                            format!("{error:#}").contains("Recovery pending");
                        if !worker.cancel.is_cancelled()
                            || format!("{error:#}").contains("Recovery pending")
                        {
                            outcome.errors.push(json!({"error":format!("{error:#}")}));
                        }
                    }
                    outcome.cancelled = worker.cancel.is_cancelled();
                    let _ = worker
                        .sender
                        .send(json!({"kind":"result","result":outcome}).to_string())
                        .await;
                })
            })?;
        Ok(operation)
    }

    pub fn cancel(&self) {
        self.cancel.cancel();
    }
}

impl Worker {
    async fn run(
        &self,
        files: &Files,
        options: &Options,
        request: Value,
        outcome: &mut Outcome,
    ) -> Result<()> {
        let library_key = format!("local-library:{}", options.data_path);
        let _guard = tokio::select! {
            _ = self.cancel.cancelled() => anyhow::bail!("Local operation cancelled"),
            guard = crate::http_policy::serial(&library_key) => guard,
        };
        let _storage = tokio::select! {
            _ = self.cancel.cancelled() => anyhow::bail!("Local operation cancelled"),
            guard = crate::backup_storage::OPERATIONS.read() => guard,
        };
        let db = Database::open(options)?;
        std::fs::create_dir_all(&options.cache_path)?;
        let journals = journal_directory(options);
        std::fs::create_dir_all(&journals)?;
        for entry in std::fs::read_dir(&journals)? {
            let entry = entry?;
            if entry.path().extension().is_some_and(|ext| ext == "json") {
                let journal: Journal = serde_json::from_slice(&std::fs::read(entry.path())?)?;
                recover(files, &db, options, &journal)
                    .await
                    .with_context(|| format!("Recovery pending at {}", entry.path().display()))?;
                outcome.recovered += 1;
            }
        }
        let mode = request["mode"]
            .as_str()
            .context("Missing local operation mode")?;
        if mode == "recover" {
            return Ok(());
        }
        if mode == "images" {
            let id = request["id"].as_str().context("Missing comic ID")?;
            let comic_type = i32::try_from(request["type"].as_i64().context("Missing comic type")?)
                .context("Comic type out of range")?;
            let library = LocalLibrary::open(&join(&options.data_path, "local.db"))?;
            let comic = library.find(id, comic_type)?.context("Comic not found")?;
            let mut path = resolve(&options.local_path, &comic.directory)?;
            if !comic.chapters.is_null() {
                let ids = crate::local::chapter_ids(&comic.chapters);
                let chapter = if let Some(id) = request["episode"].as_str() {
                    id.to_owned()
                } else {
                    let index = request["episode"]
                        .as_u64()
                        .and_then(|v| v.checked_sub(1))
                        .context("Chapter must start at 1")?;
                    ids.get(usize::try_from(index).context("Chapter out of range")?)
                        .context("Chapter out of range")?
                        .clone()
                };
                ensure!(ids.contains(&chapter), "Unknown chapter ID");
                let raw = join(&path, &chapter);
                path = if comic_type == 0
                    && crate::archives::safe_relative(&chapter).is_ok()
                    && files.exists(&raw).await?
                {
                    raw
                } else {
                    let directory = crate::api::local::chapter_directory_name(chapter);
                    ensure!(
                        crate::archives::safe_relative(&directory)?
                            .components()
                            .count()
                            == 1,
                        "Invalid chapter directory"
                    );
                    join(&path, &directory)
                };
            }
            let paths = files
                .list(&path)
                .await?
                .into_iter()
                .filter(|entry| !entry.is_dir)
                .map(|entry| entry.path)
                .collect();
            outcome.images = crate::api::local::sort_comic_images(paths);
            return Ok(());
        }
        if matches!(mode, "delete" | "chapters") {
            let keys: Vec<Key> = serde_json::from_value(request["keys"].clone())?;
            for key in keys {
                if files.check().is_err() {
                    break;
                }
                let comic_key = comic_lock(options, &key.id, key.comic_type);
                let _comic_guard = tokio::select! {
                    _ = self.cancel.cancelled() => break,
                    guard = crate::http_policy::serial(&comic_key) => guard,
                };
                let result = delete(files, &db, options, &request, &key, outcome).await;
                match result {
                    Ok(true) => outcome
                        .removed
                        .push(json!({"id":key.id,"type":key.comic_type})),
                    Ok(false) => {}
                    Err(error) => {
                        if !files.cancel.is_cancelled() {
                            outcome.errors.push(json!({"id":key.id,"type":key.comic_type,"error":format!("{error:#}")}));
                        }
                    }
                }
                if outcome.recovery_pending {
                    break;
                }
            }
            return Ok(());
        }
        let path = request["path"].as_str().context("Missing import path")?;
        let mut candidates = Vec::new();
        let folder = request["folder"].as_str().map(str::to_owned);
        match mode {
            "directory" | "archive" => candidates.push(Candidate::new(path, folder)),
            "directories" | "archives" | "local_downloads" => {
                for entry in files.list(path).await? {
                    let archive = is_archive(&entry.path);
                    if (mode == "archives" && !entry.is_dir && archive)
                        || (mode != "archives"
                            && entry.is_dir
                            && !name(&entry.path).starts_with('.'))
                    {
                        candidates.push(Candidate::new(&entry.path, folder.clone()));
                    }
                }
            }
            "ehviewer" => {
                let database = request["database"]
                    .as_str()
                    .context("Missing EhViewer database")?;
                let groups: Vec<Value> = serde_json::from_str(
                    &crate::api::archive::read_ehviewer_library(database.into())?,
                )?;
                for group in groups {
                    let label = group["label"].as_str().context("Missing EhViewer label")?;
                    let folder = if label.is_empty() {
                        request["default_folder"]
                            .as_str()
                            .unwrap_or("(EhViewer)Default")
                            .to_owned()
                    } else {
                        format!("(EhViewer){label}")
                    };
                    for comic in group["comics"]
                        .as_array()
                        .context("Missing EhViewer comics")?
                    {
                        let directory = comic["directory"]
                            .as_str()
                            .context("Missing EhViewer directory")?;
                        crate::archives::safe_relative(directory)?;
                        let mut candidate =
                            Candidate::new(&join(path, directory), Some(folder.clone()));
                        candidate.title = comic["title"].as_str().map(str::to_owned);
                        candidate.tags = serde_json::from_value(comic["tags"].clone())?;
                        candidate.created_at = comic["created_at"].as_i64();
                        candidates.push(candidate);
                    }
                }
            }
            _ => anyhow::bail!("Unknown local operation mode: {mode}"),
        }
        if mode != "ehviewer" {
            candidates.sort_by(|a, b| a.path.cmp(&b.path));
        }
        for candidate in candidates {
            if files.check().is_err() {
                break;
            }
            let _ = self.sender.try_send(
                json!({"kind":"progress","path":candidate.path,"completed":outcome.imported.len()})
                    .to_string(),
            );
            let archive = matches!(mode, "archive" | "archives");
            let copy = archive || request["copy"].as_bool().unwrap_or(true);
            let result = import(files, &db, options, &candidate, copy, archive, outcome).await;
            match result {
                Ok(Some(comic)) => outcome.imported.push(comic),
                Ok(None) => outcome.skipped.push(candidate.path),
                Err(error) => {
                    if !files.cancel.is_cancelled()
                        || format!("{error:#}").contains("Recovery pending")
                    {
                        outcome
                            .errors
                            .push(json!({"path":candidate.path,"error":format!("{error:#}")}));
                    }
                }
            }
            if outcome.recovery_pending {
                break;
            }
        }
        Ok(())
    }
}

pub(crate) fn comic_lock(options: &Options, id: &str, comic_type: i32) -> String {
    format!("local-comic:{}:{comic_type}:{id}", options.data_path)
}

#[derive(Deserialize)]
struct Entry {
    path: String,
    is_dir: bool,
}

struct Files {
    engine: Arc<Engine>,
    cancel: Arc<HttpCancellation>,
}

impl Files {
    fn check(&self) -> Result<()> {
        ensure!(!self.cancel.is_cancelled(), "Local operation cancelled");
        Ok(())
    }
    async fn platform(&self, operation: &str, path: &str, to: Option<&str>) -> Result<Value> {
        // Wait for the platform receipt even after cancellation, then safely undo completed work.
        self.engine
            .request_platform(
                json!({"method":"localFile","operation":operation,"path":path,"to":to}),
            )
            .await
    }
    async fn list(&self, path: &str) -> Result<Vec<Entry>> {
        self.check()?;
        if saf(path) {
            return Ok(serde_json::from_value(
                self.platform("list", path, None).await?,
            )?);
        }
        let mut result = Vec::new();
        for entry in std::fs::read_dir(path)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            ensure!(
                !kind.is_symlink(),
                "Symbolic links cannot be imported: {}",
                entry.path().display()
            );
            result.push(Entry {
                path: entry.path().to_string_lossy().into_owned(),
                is_dir: kind.is_dir(),
            });
        }
        result.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(result)
    }
    async fn exists(&self, path: &str) -> Result<bool> {
        if saf(path) {
            return self
                .platform("exists", path, None)
                .await?
                .as_bool()
                .context("Invalid file existence receipt");
        }
        match std::fs::symlink_metadata(path) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
    async fn mkdir(&self, path: &str) -> Result<()> {
        if saf(path) {
            self.platform("mkdir", path, None).await?;
        } else {
            std::fs::create_dir(path)?;
        }
        Ok(())
    }
    async fn rename(&self, from: &str, to: &str) -> Result<()> {
        ensure!(!self.exists(to).await?, "Destination already exists: {to}");
        if saf(from) || saf(to) {
            self.platform("rename", from, Some(to)).await?;
        } else {
            std::fs::rename(from, to)?;
        }
        Ok(())
    }
    async fn remove(&self, path: &str) -> Result<()> {
        if !self.exists(path).await? {
            return Ok(());
        }
        if saf(path) {
            self.platform("remove", path, None).await?;
        } else {
            let path = path.to_owned();
            tokio::task::spawn_blocking(move || std::fs::remove_dir_all(path)).await??;
        }
        Ok(())
    }
    async fn copy(&self, from: &str, to: &str) -> Result<()> {
        self.check()?;
        if saf(from) || saf(to) {
            self.platform("copy", from, Some(to)).await?;
        } else {
            let from = from.to_owned();
            let to = to.to_owned();
            let cancel = self.cancel.clone();
            tokio::task::spawn_blocking(move || -> Result<()> {
                let mut input = std::fs::File::open(from)?;
                let mut output = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(to)?;
                let mut buffer = vec![0; 256 * 1024];
                loop {
                    ensure!(!cancel.is_cancelled(), "Local operation cancelled");
                    let length = input.read(&mut buffer)?;
                    if length == 0 {
                        break;
                    }
                    output.write_all(&buffer[..length])?;
                }
                output.sync_all()?;
                Ok(())
            })
            .await??;
        }
        self.check()
    }
    async fn modified(&self, path: &str) -> Result<i64> {
        if saf(path) {
            return self
                .platform("modified", path, None)
                .await?
                .as_i64()
                .context("Invalid modification time receipt");
        }
        Ok(std::fs::metadata(path)?
            .modified()?
            .duration_since(std::time::UNIX_EPOCH)?
            .as_millis() as i64)
    }
}

fn saf(path: &str) -> bool {
    path.starts_with("android://")
}
fn join(root: &str, child: &str) -> String {
    format!("{}/{}", root.trim_end_matches(['/', '\\']), child)
}
fn name(path: &str) -> &str {
    path.trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
}
fn identity(path: &str) -> Result<String> {
    if saf(path) {
        return Ok(path.trim_end_matches('/').to_owned());
    }
    Ok(std::fs::canonicalize(path)?.to_string_lossy().into_owned())
}
fn resolve(root: &str, directory: &str) -> Result<String> {
    if saf(directory) || Path::new(directory).is_absolute() {
        return Ok(directory.into());
    }
    crate::archives::safe_relative(directory)?;
    Ok(join(root, directory))
}
fn relative(root: &str, path: &str) -> Result<Option<String>> {
    let root = identity(root)?;
    let path = identity(path)?;
    if saf(&root) {
        return Ok(path
            .strip_prefix(&format!("{}/", root.trim_end_matches('/')))
            .map(str::to_owned));
    }
    Ok(Path::new(&path)
        .strip_prefix(root)
        .ok()
        .map(|p| p.to_string_lossy().into_owned()))
}
fn is_archive(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|v| v.to_str())
        .is_some_and(|v| ["cbz", "zip", "7z", "cb7"].contains(&v.to_ascii_lowercase().as_str()))
}
fn is_image(path: &str) -> bool {
    crate::comic_queue::is_image(Path::new(path))
        || Path::new(path)
            .extension()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.eq_ignore_ascii_case("jpe"))
}

struct Candidate {
    path: String,
    folder: Option<String>,
    title: Option<String>,
    tags: Vec<String>,
    created_at: Option<i64>,
}
impl Candidate {
    fn new(path: &str, folder: Option<String>) -> Self {
        Self {
            path: path.into(),
            folder,
            title: None,
            tags: vec![],
            created_at: None,
        }
    }
}

async fn scan(files: &Files, candidate: &Candidate) -> Result<(LocalComic, Vec<String>)> {
    let mut entries = files.list(&candidate.path).await?;
    entries.sort_by(|a, b| name(&a.path).cmp(name(&b.path)));
    let mut chapters = serde_json::Map::new();
    let mut all_files = Vec::new();
    let mut root_images = Vec::new();
    let mut chapter_cover = None;
    for entry in entries {
        let basename = name(&entry.path);
        if entry.is_dir {
            if basename.starts_with('.') {
                continue;
            }
            let mut children = files.list(&entry.path).await?;
            children.sort_by(|a, b| name(&a.path).cmp(name(&b.path)));
            ensure!(
                children.iter().all(|file| !file.is_dir),
                "Nested chapter directory: {}",
                entry.path
            );
            let images: Vec<_> = children
                .iter()
                .filter(|file| is_image(&file.path))
                .collect();
            ensure!(!images.is_empty(), "Chapter has no images: {}", entry.path);
            if chapter_cover.is_none() {
                chapter_cover = Some(format!("{basename}/{}", name(&images[0].path)));
            }
            chapters.insert(basename.into(), basename.into());
            all_files.extend(
                children
                    .into_iter()
                    .map(|file| format!("{basename}/{}", name(&file.path))),
            );
        } else {
            if is_image(&entry.path) {
                root_images.push(basename.to_owned());
            }
            all_files.push(basename.to_owned());
        }
    }
    let cover = root_images
        .iter()
        .find(|file| file.to_ascii_lowercase().starts_with("cover."))
        .cloned()
        .or_else(|| root_images.first().cloned())
        .or(chapter_cover)
        .context("No images found in comic directory")?;
    let chapters = if chapters.is_empty() {
        Value::Null
    } else {
        Value::Object(chapters)
    };
    let comic = LocalComic {
        id: String::new(),
        title: candidate
            .title
            .clone()
            .unwrap_or_else(|| name(&candidate.path).into()),
        subtitle: String::new(),
        tags: candidate.tags.clone(),
        directory: candidate.path.clone(),
        downloaded_chapters: crate::local::chapter_ids(&chapters),
        chapters,
        cover,
        comic_type: 0,
        created_at: candidate.created_at.unwrap_or(
            files
                .modified(&candidate.path)
                .await
                .unwrap_or_else(|_| crate::cache::now_ms()),
        ),
    };
    Ok((comic, all_files))
}

struct Database {
    favorites: Favorites,
    options: Options,
}
impl Database {
    fn open(options: &Options) -> Result<Self> {
        std::fs::create_dir_all(&options.data_path)?;
        LocalLibrary::open(&join(&options.data_path, "local.db"))?;
        crate::history::History::open(&join(&options.data_path, "history.db"))?;
        let favorites = Favorites::open(
            &join(&options.data_path, "local_favorite.db"),
            options.traditional,
        )?;
        favorites.db.execute(
            "ATTACH DATABASE ? AS local_library",
            [join(&options.data_path, "local.db")],
        )?;
        favorites.db.execute(
            "ATTACH DATABASE ? AS reading_history",
            [join(&options.data_path, "history.db")],
        )?;
        favorites.db.execute_batch("CREATE TABLE IF NOT EXISTS local_library.local_import_origins (origin TEXT PRIMARY KEY,id TEXT NOT NULL,type INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS local_library.local_operation_commits (token TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS local_library.local_id_sequence (id INTEGER PRIMARY KEY CHECK(id=1), next_value INTEGER NOT NULL);")?;
        let tx =
            rusqlite::Transaction::new_unchecked(&favorites.db, TransactionBehavior::Immediate)?;
        let mut maximum: i64 = favorites.db.query_row("SELECT MAX(value) FROM (SELECT COALESCE(MAX(CAST(id AS INTEGER)),0) AS value FROM local_library.comics WHERE comic_type=0 UNION ALL SELECT COALESCE(MAX(CAST(id AS INTEGER)),0) FROM reading_history.history WHERE type=0)",[],|row|row.get(0))?;
        for folder in favorites.folders()? {
            let table = format!("\"{}\"", folder.replace('"', "\"\""));
            maximum = maximum.max(favorites.db.query_row(
                &format!("SELECT COALESCE(MAX(CAST(id AS INTEGER)),0) FROM {table} WHERE type=0"),
                [],
                |row| row.get(0),
            )?);
        }
        favorites.db.execute("INSERT INTO local_library.local_id_sequence VALUES (1,?) ON CONFLICT(id) DO UPDATE SET next_value=MAX(next_value,excluded.next_value)",[maximum.checked_add(1).context("Local comic ID exhausted")?])?;
        tx.commit()?;
        Ok(Self {
            favorites,
            options: options.clone(),
        })
    }
    fn existing(&self, origin: &str) -> Result<Option<LocalComic>> {
        let library = LocalLibrary::open(&join(&self.options.data_path, "local.db"))?;
        let key = self
            .favorites
            .db
            .query_row(
                "SELECT id,type FROM local_library.local_import_origins WHERE origin=?",
                [origin],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i32>(1)?)),
            )
            .optional()?;
        if let Some((id, kind)) = key {
            if let Some(comic) = library.find(&id, kind)? {
                return Ok(Some(comic));
            }
        }
        for comic in library.list("time_desc", None, None)? {
            let path = resolve(&self.options.local_path, &comic.directory)?;
            if identity(&path).ok().as_deref() == Some(origin) {
                return Ok(Some(comic));
            }
        }
        Ok(None)
    }
    fn link(&self, comic: &LocalComic, folder: Option<&str>) -> Result<()> {
        let Some(folder) = folder else {
            return Ok(());
        };
        let folders = self.favorites.folders()?;
        let folder = if let Some(existing) = folders
            .iter()
            .find(|name| name.eq_ignore_ascii_case(folder))
        {
            existing.clone()
        } else {
            self.favorites.create(folder, false)?
        };
        let time: String = self.favorites.db.query_row(
            "SELECT datetime(? / 1000, 'unixepoch', 'localtime')",
            [comic.created_at],
            |r| r.get(0),
        )?;
        let favorite = Favorite {
            id: comic.id.clone(),
            name: comic.title.clone(),
            author: comic.subtitle.clone(),
            comic_type: comic.comic_type,
            tags: comic.tags.clone(),
            cover: comic.cover.clone(),
            time,
            folder: folder.clone(),
            translated_tags: String::new(),
            last_update_time: None,
            has_new_update: false,
            last_check_time: None,
        };
        self.favorites.add(
            &folder,
            &favorite,
            None,
            self.options.at_end,
            self.options.traditional,
        )?;
        Ok(())
    }
    fn register(
        &self,
        comic: &mut LocalComic,
        origin: &str,
        folder: Option<&str>,
        token: &str,
    ) -> Result<()> {
        let tx = rusqlite::Transaction::new_unchecked(
            &self.favorites.db,
            TransactionBehavior::Immediate,
        )?;
        comic.id = self.favorites.db.query_row(
            "SELECT CAST(next_value AS TEXT) FROM local_library.local_id_sequence WHERE id=1",
            [],
            |r| r.get(0),
        )?;
        self.favorites.db.execute(
            "UPDATE local_library.local_id_sequence SET next_value=next_value+1 WHERE id=1",
            [],
        )?;
        let base = comic.title.clone();
        let mut suffix = 1;
        while self.favorites.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM local_library.comics WHERE title=?)",
            [&comic.title],
            |r| r.get::<_, bool>(0),
        )? {
            comic.title = format!("{base} ({suffix})");
            suffix += 1;
        }
        crate::local::write_row(&self.favorites.db, "local_library.comics", comic)?;
        self.favorites.db.execute(
            "INSERT OR REPLACE INTO local_library.local_import_origins VALUES (?,?,?)",
            params![origin, comic.id, comic.comic_type],
        )?;
        self.link(comic, folder)?;
        self.favorites.db.execute(
            "INSERT INTO local_library.local_operation_commits VALUES (?)",
            [token],
        )?;
        tx.commit()?;
        Ok(())
    }
    fn committed(&self, token: &str) -> Result<bool> {
        Ok(self.favorites.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM local_library.local_operation_commits WHERE token=?)",
            [token],
            |r| r.get(0),
        )?)
    }
}

#[derive(Serialize, Deserialize)]
struct Move {
    from: String,
    to: String,
}
#[derive(Serialize, Deserialize)]
struct Journal {
    token: String,
    kind: String,
    created: Vec<String>,
    moves: Vec<Move>,
}
fn journal_directory(options: &Options) -> String {
    join(&options.data_path, "local_operations")
}
fn journal_path(options: &Options, token: &str) -> String {
    join(&journal_directory(options), &format!("{token}.json"))
}
fn persist(options: &Options, journal: &Journal) -> Result<()> {
    std::fs::create_dir_all(journal_directory(options))?;
    let mut file = tempfile::NamedTempFile::new_in(journal_directory(options))?;
    file.write_all(&serde_json::to_vec(journal)?)?;
    file.as_file().sync_all()?;
    file.persist(journal_path(options, &journal.token))?;
    Ok(())
}
async fn recover(files: &Files, db: &Database, options: &Options, journal: &Journal) -> Result<()> {
    uuid::Uuid::parse_str(&journal.token)?;
    let committed = db.committed(&journal.token)?;
    for path in &journal.created {
        ensure!(
            name(path).ends_with(&journal.token),
            "Invalid owned import directory"
        );
        if !committed || name(path).starts_with(".venera-import-") {
            files.remove(path).await?;
        }
    }
    for moved in journal.moves.iter().rev() {
        ensure!(
            name(&moved.to).starts_with(&format!(".venera-delete-{}-", journal.token)),
            "Invalid deletion quarantine"
        );
        if !files.exists(&moved.to).await? {
            continue;
        }
        if committed {
            files.remove(&moved.to).await?;
        } else {
            files.rename(&moved.to, &moved.from).await?;
        }
    }
    std::fs::remove_file(journal_path(options, &journal.token))?;
    db.favorites.db.execute(
        "DELETE FROM local_library.local_operation_commits WHERE token=?",
        [&journal.token],
    )?;
    Ok(())
}

async fn import(
    files: &Files,
    db: &Database,
    options: &Options,
    candidate: &Candidate,
    copy: bool,
    archive: bool,
    outcome: &mut Outcome,
) -> Result<Option<LocalComic>> {
    let origin = identity(&candidate.path)?;
    if let Some(comic) = db.existing(&origin)? {
        let tx =
            rusqlite::Transaction::new_unchecked(&db.favorites.db, TransactionBehavior::Immediate)?;
        db.link(&comic, candidate.folder.as_deref())?;
        tx.commit()?;
        return Ok(None);
    }
    let scratch = if archive {
        Some(tempfile::tempdir_in(&options.cache_path)?)
    } else {
        None
    };
    let (mut comic, plan, source) = if let Some(scratch) = &scratch {
        let mut input = candidate.path.clone();
        if saf(&input) {
            let target = scratch
                .path()
                .join(name(&input))
                .to_string_lossy()
                .into_owned();
            files.copy(&input, &target).await?;
            input = target;
        }
        let comic: LocalComic = serde_json::from_str(&crate::comic_archive::import(
            &input,
            &options.cache_path,
            &scratch.path().to_string_lossy(),
            &join(&options.data_path, "local.db"),
        )?)?;
        let source = scratch
            .path()
            .join(&comic.directory)
            .to_string_lossy()
            .into_owned();
        let (_, plan) = scan(files, &Candidate::new(&source, None)).await?;
        (comic, plan, source)
    } else {
        let (comic, plan) = scan(files, candidate).await?;
        (comic, plan, candidate.path.clone())
    };
    files.check()?;
    if !files.exists(&options.local_path).await? {
        files.mkdir(&options.local_path).await?;
    }
    let token = uuid::Uuid::new_v4().to_string();
    let mut journal = Journal {
        token: token.clone(),
        kind: "import".into(),
        created: vec![],
        moves: vec![],
    };
    let inside = relative(&options.local_path, &source)?;
    let copying = copy && inside.is_none();
    let stage = join(&options.local_path, &format!(".venera-import-{token}"));
    let directory = format!(
        "{}-{token}",
        crate::api::local::chapter_directory_name(comic.title.chars().take(65).collect())
    );
    let destination = join(&options.local_path, &directory);
    if copying {
        journal.created = vec![stage.clone(), destination.clone()];
    }
    persist(options, &journal)?;
    let work = async {
        if copying {
            files.mkdir(&stage).await?;
            for chapter in crate::local::chapter_ids(&comic.chapters) {
                files.mkdir(&join(&stage, &chapter)).await?;
            }
            for path in plan {
                files
                    .copy(&join(&source, &path), &join(&stage, &path))
                    .await?;
            }
            files.check()?;
            files.rename(&stage, &destination).await?;
            comic.directory = directory;
        } else {
            comic.directory = match inside {
                Some(relative) if !relative.contains(['/', '\\']) => relative,
                _ => source,
            };
        }
        files.check()?;
        db.register(&mut comic, &origin, candidate.folder.as_deref(), &token)
    }
    .await;
    let cleanup = recover(files, db, options, &journal).await;
    if let Err(error) = cleanup {
        outcome.recovery_pending = true;
        outcome.errors.push(json!({"path":candidate.path,"error":format!("Recovery pending at {}: {error:#}",journal_path(options,&token))}));
    }
    work?;
    Ok(Some(comic))
}

async fn delete(
    files: &Files,
    db: &Database,
    options: &Options,
    request: &Value,
    key: &Key,
    outcome: &mut Outcome,
) -> Result<bool> {
    let library = LocalLibrary::open(&join(&options.data_path, "local.db"))?;
    let Some(mut comic) = library.find(&key.id, key.comic_type)? else {
        return Ok(false);
    };
    let chapter_mode = request["mode"] == "chapters";
    let mut paths = Vec::new();
    let directory = resolve(&options.local_path, &comic.directory)?;
    if chapter_mode {
        ensure!(!comic.chapters.is_null(), "Comic has no chapters");
        let chapters: Vec<String> = serde_json::from_value(request["chapters"].clone())?;
        if chapters.is_empty() {
            return Ok(false);
        }
        let known = crate::local::chapter_ids(&comic.chapters);
        ensure!(
            chapters.iter().all(|chapter| known.contains(chapter)),
            "Unknown chapter ID"
        );
        for chapter in &chapters {
            let name = crate::api::local::chapter_directory_name(chapter.clone());
            ensure!(
                crate::archives::safe_relative(&name)?.components().count() == 1,
                "Invalid chapter directory"
            );
            ensure!(
                !known.iter().any(|other| !chapters.contains(other)
                    && crate::api::local::chapter_directory_name(other.clone()) == name),
                "Chapter directory is shared by another chapter"
            );
            let raw = join(&directory, chapter);
            let path = if key.comic_type == 0
                && crate::archives::safe_relative(chapter).is_ok()
                && files.exists(&raw).await?
            {
                raw
            } else {
                join(&directory, &name)
            };
            paths.push(path);
        }
        comic
            .downloaded_chapters
            .retain(|chapter| !chapters.contains(chapter));
    } else if request["remove_files"].as_bool().unwrap_or(true) {
        paths.push(directory.clone());
    }
    let removing_record = !chapter_mode || comic.downloaded_chapters.is_empty();
    if !paths.is_empty() {
        let other = library
            .list("time_desc", None, None)?
            .into_iter()
            .filter(|other| other.id != comic.id || other.comic_type != comic.comic_type);
        let references: Vec<String> = other
            .filter_map(|other| {
                resolve(&options.local_path, &other.directory)
                    .ok()
                    .and_then(|path| identity(&path).ok())
            })
            .collect();
        for path in &paths {
            let Ok(target) = identity(path) else {
                continue;
            };
            ensure!(
                !references.iter().any(|other| if saf(&target) {
                    other == &target || other.starts_with(&format!("{target}/"))
                } else {
                    Path::new(other).starts_with(&target)
                }),
                "Comic directory is referenced by another record"
            );
        }
    }
    let token = uuid::Uuid::new_v4().to_string();
    let mut journal = Journal {
        token: token.clone(),
        kind: "delete".into(),
        created: vec![],
        moves: vec![],
    };
    paths.sort();
    paths.dedup();
    for (index, path) in paths.into_iter().enumerate() {
        let trimmed = path.trim_end_matches(['/', '\\']);
        let (parent, _) = trimmed
            .rsplit_once(['/', '\\'])
            .context("Cannot remove filesystem root")?;
        ensure!(
            !parent.ends_with(":/") && !parent.is_empty(),
            "Cannot remove storage root"
        );
        ensure!(
            identity(&path).ok() != identity(&options.local_path).ok()
                || !files.exists(&path).await?,
            "Cannot remove local library root"
        );
        let to = join(parent, &format!(".venera-delete-{token}-{index}"));
        journal.moves.push(Move { from: path, to });
    }
    persist(options, &journal)?;
    let work = async {
        for moved in &journal.moves {
            files.check()?;
            if files.exists(&moved.from).await? {
                files.rename(&moved.from, &moved.to).await?;
            }
        }
        if chapter_mode && !removing_record && key.comic_type == 0
            && !files.exists(&join(&directory,&comic.cover)).await? {
            let (scanned,_) = scan(files,&Candidate::new(&directory,None)).await?;
            comic.cover = scanned.cover;
        }
        files.check()?;
        let tx =
            rusqlite::Transaction::new_unchecked(&db.favorites.db, TransactionBehavior::Immediate)?;
        if removing_record {
            db.favorites.db.execute(
                "DELETE FROM local_library.comics WHERE id=? AND comic_type=?",
                params![key.id, key.comic_type],
            )?;
            db.favorites.db.execute(
                "DELETE FROM local_library.local_import_origins WHERE id=? AND type=?",
                params![key.id, key.comic_type],
            )?;
            let clear = if chapter_mode || request["local_only"] == true {
                key.comic_type == 0
            } else {
                request["clear_associations"].as_bool().unwrap_or(true)
            };
            if clear {
                db.favorites.delete_rows(
                    None,
                    &[Key {
                        id: key.id.clone(),
                        comic_type: key.comic_type,
                    }],
                )?;
                db.favorites.db.execute(
                    "DELETE FROM reading_history.history WHERE id=? AND type=?",
                    params![key.id, key.comic_type],
                )?;
            }
        } else {
            crate::local::write_row(&db.favorites.db, "local_library.comics", &comic)?;
            if key.comic_type == 0 {
                for folder in db.favorites.find(&key.id,key.comic_type)? {
                    if let Some(mut favorite) = db.favorites.list(Some(&folder),None,false)?.into_iter().find(|favorite|favorite.id == key.id && favorite.comic_type == key.comic_type) {
                        favorite.cover = comic.cover.clone();
                        db.favorites.update_info(&folder,&favorite,options.traditional)?;
                    }
                }
                let position = db.favorites.db.query_row("SELECT ep,chapter_group FROM reading_history.history WHERE id=? AND type=?",params![key.id,key.comic_type],|row|Ok((row.get::<_,Option<i64>>(0)?,row.get::<_,Option<i64>>(1)?))).optional()?;
                let current = position.and_then(|(episode,group)|history_chapter(&comic.chapters,episode?,group));
                if current.is_some_and(|chapter|request["chapters"].as_array().is_some_and(|selected|selected.contains(&json!(chapter)))) {
                    db.favorites.db.execute("DELETE FROM reading_history.history WHERE id=? AND type=?",params![key.id,key.comic_type])?;
                } else {
                    db.favorites.db.execute("UPDATE reading_history.history SET cover=? WHERE id=? AND type=?",params![comic.cover,key.id,key.comic_type])?;
                }
            }
        }
        db.favorites.db.execute(
            "INSERT INTO local_library.local_operation_commits VALUES (?)",
            [&token],
        )?;
        tx.commit()?;
        Ok::<_, anyhow::Error>(())
    }
    .await;
    let cleanup = recover(files, db, options, &journal).await;
    if let Err(error) = cleanup {
        outcome.recovery_pending = true;
        outcome.errors.push(json!({"id":key.id,"type":key.comic_type,"error":format!("Recovery pending at {}: {error:#}",journal_path(options,&token))}));
    }
    work?;
    Ok(true)
}

fn history_chapter(chapters: &Value, episode: i64, group: Option<i64>) -> Option<String> {
    let group = group
        .and_then(|value| value.checked_sub(1))
        .and_then(|value| usize::try_from(value).ok())
        .and_then(|index| chapters.as_object()?.values().nth(index))
        .filter(|value| value.is_object())
        .unwrap_or(chapters);
    let index = usize::try_from(episode.checked_sub(1)?).ok()?;
    crate::local::chapter_ids(group).get(index).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _directory: tempfile::TempDir,
        options: Options,
        engine: Arc<Engine>,
    }
    impl Fixture {
        fn new() -> Result<Self> {
            let directory = tempfile::tempdir()?;
            let root = directory.path().to_string_lossy().into_owned();
            let options = Options {
                data_path: join(&root, "data"),
                cache_path: join(&root, "cache"),
                local_path: join(&root, "library"),
                traditional: false,
                at_end: true,
            };
            for path in [&options.data_path, &options.cache_path, &options.local_path] {
                std::fs::create_dir_all(path)?;
            }
            let engine = Arc::new(Engine::open(serde_json::from_value(
                json!({"data_path":options.data_path,"version":"1.6.3","locale":"zh_CN","platform":"test","user_agent":"test","http":{"proxy":null,"dns_overrides":{},"tls_sni":true,"verify_certificates":true,"connect_timeout_ms":1000,"receive_timeout_ms":1000,"max_redirects":5}}),
            )?)?);
            Ok(Self {
                _directory: directory,
                options,
                engine,
            })
        }
        fn book(&self, relative: &str, chapters: bool) -> Result<String> {
            let path = self._directory.path().join(relative);
            std::fs::create_dir_all(&path)?;
            if chapters {
                for chapter in ["One", "Two"] {
                    std::fs::create_dir(path.join(chapter))?;
                    std::fs::write(path.join(chapter).join("1.jpg"), chapter)?;
                }
            } else {
                std::fs::write(path.join("1.JPG"), b"page")?;
            }
            Ok(path.to_string_lossy().into_owned())
        }
        async fn run(&self, request: Value) -> Result<Value> {
            let operation = Operation::start(self.engine.clone(), self.options.clone(), request)?;
            result(&operation).await
        }
        fn library(&self) -> Result<LocalLibrary> {
            LocalLibrary::open(&join(&self.options.data_path, "local.db"))
        }
    }
    async fn result(operation: &Operation) -> Result<Value> {
        loop {
            let encoded = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                operation.receiver.lock().await.recv(),
            )
            .await?
            .context("Missing operation event")?;
            let value: Value = serde_json::from_str(&encoded)?;
            if value["kind"] == "result" {
                return Ok(value["result"].clone());
            }
        }
    }
    fn no_errors(value: &Value) {
        assert_eq!(value["errors"], json!([]), "{value}");
    }

    #[tokio::test]
    async fn detects_chapters_without_root_cover_and_links_duplicate_imports() -> Result<()> {
        let f = Fixture::new()?;
        let path = f.book("source/Book", true)?;
        let first = f
            .run(json!({"mode":"directory","path":path,"folder":"Favorites","copy":true}))
            .await?;
        no_errors(&first);
        let comic: LocalComic = serde_json::from_value(first["imported"][0].clone())?;
        assert_eq!(comic.cover, "One/1.jpg");
        assert_eq!(comic.downloaded_chapters, vec!["One", "Two"]);
        let copy = resolve(&f.options.local_path, &comic.directory)?;
        assert_eq!(std::fs::read(join(&copy, &comic.cover))?, b"One");
        let images = f
            .run(json!({"mode":"images","id":comic.id,"type":0,"episode":1}))
            .await?;
        no_errors(&images);
        assert_eq!(images["images"].as_array().unwrap().len(), 1);
        let duplicate = f
            .run(json!({"mode":"directory","path":path,"folder":"Second"}))
            .await?;
        no_errors(&duplicate);
        assert_eq!(
            identity(duplicate["skipped"][0].as_str().unwrap())?,
            identity(&path)?
        );
        assert_eq!(f.library()?.count()?, 1);
        let favorites = Favorites::open(&join(&f.options.data_path, "local_favorite.db"), false)?;
        assert_eq!(favorites.find(&comic.id, 0)?, vec!["Favorites", "Second"]);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn same_names_preserve_existing_directories_and_batch_reports_partial_success(
    ) -> Result<()> {
        let f = Fixture::new()?;
        let path = f.book("input/Book", false)?;
        let old = f.book("library/Book", false)?;
        std::fs::write(join(&old, "sentinel"), b"existing")?;
        let invalid = f._directory.path().join("input/Invalid");
        std::fs::create_dir_all(&invalid)?;
        let batch = f
            .run(json!({"mode":"directories","path":invalid.parent()}))
            .await?;
        assert_eq!(batch["imported"].as_array().unwrap().len(), 1);
        assert_eq!(batch["errors"].as_array().unwrap().len(), 1);
        let second = f.book("another/Book", false)?;
        let second = f.run(json!({"mode":"directory","path":second})).await?;
        no_errors(&second);
        assert_eq!(second["imported"][0]["title"], "Book (1)");
        assert_eq!(std::fs::read(join(&old, "sentinel"))?, b"existing");
        assert!(Path::new(&path).is_dir());
        assert_eq!(f.library()?.count()?, 2);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn record_only_deletion_and_last_chapter_cleanup_follow_backend_rules() -> Result<()> {
        let f = Fixture::new()?;
        let path = f.book("external/Book", true)?;
        let imported = f
            .run(json!({"mode":"directory","path":path,"copy":false,"folder":"Favorites"}))
            .await?;
        no_errors(&imported);
        let id = imported["imported"][0]["id"].as_str().unwrap();
        let db = Database::open(&f.options)?;
        db.favorites.db.execute(
            "INSERT INTO reading_history.history (id,type,ep,readEpisode) VALUES (?,0,1,'')",
            [id],
        )?;
        let first = f
            .run(json!({"mode":"chapters","keys":[{"id":id,"type":0}],"chapters":["One"]}))
            .await?;
        no_errors(&first);
        assert!(!Path::new(&join(&path, "One")).exists());
        assert!(Path::new(&join(&path, "Two")).exists());
        assert_eq!(
            f.library()?.find(id, 0)?.unwrap().downloaded_chapters,
            vec!["Two"]
        );
        assert_eq!(f.library()?.find(id, 0)?.unwrap().cover, "Two/1.jpg");
        assert_eq!(
            db.favorites.list(Some("Favorites"), None, false)?[0].cover,
            "Two/1.jpg"
        );
        assert_eq!(
            db.favorites.db.query_row(
                "SELECT COUNT(*) FROM reading_history.history",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            0
        );
        assert_eq!(
            history_chapter(
                &json!({"Group One":{"One":"One"},"Group Two":{"Two":"Two"}}),
                1,
                Some(2)
            ),
            Some("Two".into())
        );
        let last = f
            .run(json!({"mode":"chapters","keys":[{"id":id,"type":0}],"chapters":["Two"]}))
            .await?;
        no_errors(&last);
        assert!(f.library()?.find(id, 0)?.is_none());
        assert!(db.favorites.find(id, 0)?.is_empty());
        assert_eq!(
            db.favorites
                .db
                .query_row("SELECT COUNT(*) FROM reading_history.history", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
        let path = f.book("keep/Keep", false)?;
        let imported = f
            .run(json!({"mode":"directory","path":path,"copy":false,"folder":"Favorites"}))
            .await?;
        let id = imported["imported"][0]["id"].as_str().unwrap();
        let deleted = f.run(json!({"mode":"delete","keys":[{"id":id,"type":0}],"remove_files":false,"clear_associations":false})).await?;
        no_errors(&deleted);
        assert!(Path::new(&join(&path, "1.JPG")).exists());
        assert_eq!(db.favorites.find(id, 0)?, vec!["Favorites"]);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn database_failure_restores_quarantined_files_and_rolls_back_imports() -> Result<()> {
        let f = Fixture::new()?;
        let db = Database::open(&f.options)?;
        let path = f.book("external/Book", false)?;
        db.favorites.db.execute_batch("CREATE TRIGGER local_library.reject_import BEFORE INSERT ON comics BEGIN SELECT RAISE(ABORT,'test import failure'); END;")?;
        let failed = f
            .run(json!({"mode":"directory","path":path,"folder":"Favorites"}))
            .await?;
        assert_eq!(failed["errors"].as_array().unwrap().len(), 1);
        assert_eq!(f.library()?.count()?, 0);
        assert_eq!(std::fs::read_dir(&f.options.local_path)?.count(), 0);
        db.favorites
            .db
            .execute_batch("DROP TRIGGER local_library.reject_import;")?;
        let imported = f
            .run(json!({"mode":"directory","path":path,"copy":false,"folder":"Favorites"}))
            .await?;
        no_errors(&imported);
        let id = imported["imported"][0]["id"].as_str().unwrap();
        db.favorites.db.execute_batch("CREATE TRIGGER local_library.reject_delete BEFORE DELETE ON comics BEGIN SELECT RAISE(ABORT,'test deletion failure'); END;")?;
        let failed = f
            .run(json!({"mode":"delete","keys":[{"id":id,"type":0}]}))
            .await?;
        assert_eq!(failed["errors"].as_array().unwrap().len(), 1);
        assert_eq!(std::fs::read(join(&path, "1.JPG"))?, b"page");
        assert!(f.library()?.find(id, 0)?.is_some());
        assert_eq!(db.favorites.find(id, 0)?, vec!["Favorites"]);
        assert_eq!(std::fs::read_dir(journal_directory(&f.options))?.count(), 0);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn recovery_restores_uncommitted_moves_and_cleans_committed_quarantine() -> Result<()> {
        let f = Fixture::new()?;
        let db = Database::open(&f.options)?;
        let original = f.book("external/Book", false)?;
        for committed in [false, true] {
            let token = uuid::Uuid::new_v4().to_string();
            let quarantine = join(&f.options.local_path, &format!(".venera-delete-{token}-0"));
            let journal = Journal {
                token: token.clone(),
                kind: "delete".into(),
                created: vec![],
                moves: vec![Move {
                    from: original.clone(),
                    to: quarantine.clone(),
                }],
            };
            persist(&f.options, &journal)?;
            std::fs::rename(&original, &quarantine)?;
            if committed {
                db.favorites.db.execute(
                    "INSERT INTO local_library.local_operation_commits VALUES (?)",
                    [&token],
                )?;
            }
            let result = f.run(json!({"mode":"recover"})).await?;
            no_errors(&result);
            assert_eq!(result["recovered"], 1);
            assert_eq!(Path::new(&original).exists(), !committed);
            assert!(!Path::new(&quarantine).exists());
        }
        let token = uuid::Uuid::new_v4().to_string();
        let orphan = join(&f.options.local_path, &format!("Book-{token}"));
        std::fs::create_dir(&orphan)?;
        persist(
            &f.options,
            &Journal {
                token,
                kind: "import".into(),
                created: vec![orphan.clone()],
                moves: vec![],
            },
        )?;
        no_errors(&f.run(json!({"mode":"recover"})).await?);
        assert!(!Path::new(&orphan).exists());
        no_errors(&f.run(json!({"mode":"recover"})).await?);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn cancelled_wait_for_active_download_keeps_the_comic() -> Result<()> {
        let f = Fixture::new()?;
        let path = f.book("external/Book", false)?;
        let imported = f
            .run(json!({"mode":"directory","path":path,"copy":false}))
            .await?;
        let id = imported["imported"][0]["id"].as_str().unwrap();
        let guard = crate::http_policy::serial(&comic_lock(&f.options, id, 0)).await;
        let operation = Operation::start(
            f.engine.clone(),
            f.options.clone(),
            json!({"mode":"delete","keys":[{"id":id,"type":0}]}),
        )?;
        operation.cancel();
        let cancelled = result(&operation).await?;
        assert_eq!(cancelled["cancelled"], true);
        assert!(f.library()?.find(id, 0)?.is_some());
        assert!(Path::new(&path).exists());
        drop(guard);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn dropping_a_waiting_handle_cancels_and_releases_its_worker() -> Result<()> {
        let f = Fixture::new()?;
        let guard =
            crate::http_policy::serial(&format!("local-library:{}", f.options.data_path)).await;
        let operation = Operation::start(
            f.engine.clone(),
            f.options.clone(),
            json!({"mode":"recover"}),
        )?;
        let cancellation = Arc::downgrade(&operation.cancel);
        drop(operation);
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            while cancellation.upgrade().is_some() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await?;
        drop(guard);
        f.engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn ehviewer_metadata_and_local_download_discovery_use_backend_registration() -> Result<()>
    {
        let f = Fixture::new()?;
        f.book("eh/77", false)?;
        let path = f._directory.path().join("eh.db");
        let eh = rusqlite::Connection::open(&path)?;
        eh.execute_batch("CREATE TABLE DOWNLOAD_LABELS (LABEL TEXT,TIME INTEGER);
            CREATE TABLE DOWNLOAD_DIRNAME (GID INTEGER,DIRNAME TEXT);
            CREATE TABLE DOWNLOADS (GID INTEGER,TITLE_JPN TEXT,TITLE TEXT,TIME INTEGER,CATEGORY INTEGER,LABEL TEXT,STATE INTEGER);
            INSERT INTO DOWNLOAD_DIRNAME VALUES (77,'77');
            INSERT INTO DOWNLOADS VALUES (77,'','EH Book',123456,2,NULL,3);")?;
        let imported = f.run(json!({"mode":"ehviewer","path":f._directory.path().join("eh"),"database":path,"copy":false,"default_folder":"(EhViewer)默认"})).await?;
        no_errors(&imported);
        assert_eq!(imported["imported"][0]["title"], "EH Book");
        assert_eq!(imported["imported"][0]["tags"], json!(["DOUJINSHI"]));
        assert_eq!(imported["imported"][0]["created_at"], 123456);
        let db = Database::open(&f.options)?;
        assert_eq!(db.favorites.folders()?, vec!["(EhViewer)默认"]);
        let path = f.book("library/Downloaded", false)?;
        let discovered = f
            .run(json!({"mode":"local_downloads","path":f.options.local_path,"copy":false}))
            .await?;
        no_errors(&discovered);
        assert_eq!(discovered["imported"][0]["directory"], "Downloaded");
        let duplicate = f
            .run(json!({"mode":"local_downloads","path":f.options.local_path,"copy":false}))
            .await?;
        no_errors(&duplicate);
        assert_eq!(
            identity(duplicate["skipped"][0].as_str().unwrap())?,
            identity(&path)?
        );
        assert_eq!(f.library()?.count()?, 2);
        f.engine.shutdown().await;
        Ok(())
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn locked_files_leave_reported_cleanup_and_can_be_recovered() -> Result<()> {
        use std::os::windows::fs::OpenOptionsExt;
        let f = Fixture::new()?;
        let path = f.book("external/Book", false)?;
        let imported = f
            .run(json!({"mode":"directory","path":path,"copy":true}))
            .await?;
        let comic: LocalComic = serde_json::from_value(imported["imported"][0].clone())?;
        let directory = resolve(&f.options.local_path, &comic.directory)?;
        let handle = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(1 | 2)
            .open(join(&directory, "1.JPG"))?;
        let failed = f
            .run(json!({"mode":"delete","keys":[{"id":comic.id,"type":0}]}))
            .await?;
        assert!(!failed["errors"].as_array().unwrap().is_empty(), "{failed}");
        drop(handle);
        no_errors(&f.run(json!({"mode":"recover"})).await?);
        no_errors(
            &f.run(json!({"mode":"delete","keys":[{"id":comic.id,"type":0}]}))
                .await?,
        );
        assert!(f.library()?.find(&comic.id, 0)?.is_none());
        assert!(!Path::new(&directory).exists());
        f.engine.shutdown().await;
        Ok(())
    }
}
