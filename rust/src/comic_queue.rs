use crate::{api::http::HttpCancellation, script::Engine};
use anyhow::{anyhow, ensure, Context, Result};
use futures_util::{stream, StreamExt, TryStreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Instant,
};

#[derive(Clone, Deserialize, Serialize)]
pub struct Options {
    pub data_path: String,
    pub cache_path: String,
    pub local_path: String,
    pub saf: bool,
    pub threads: usize,
    pub http: crate::api::http::HttpOptions,
}
struct State {
    moving_storage: bool,
    items: Vec<Value>,
    running: bool,
    epoch: u64,
    cancel: Option<Arc<HttpCancellation>>,
    options: Options,
    cleanup: Vec<Value>,
}
pub struct Queue {
    engine: Arc<Engine>,
    execution: tokio::sync::Mutex<()>,
    state: Mutex<State>,
    snapshots: tokio::sync::watch::Sender<String>,
    pub snapshot_receiver: tokio::sync::Mutex<tokio::sync::watch::Receiver<String>>,
    platform: tokio::sync::mpsc::Sender<String>,
    pub platform_receiver: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<String>>,
    acknowledgements: Mutex<HashMap<String, tokio::sync::oneshot::Sender<Result<Value>>>>,
}
fn key(value: &Value) -> String {
    format!(
        "{}@{}",
        value["source"].as_str().unwrap_or_default(),
        value["comicId"].as_str().unwrap_or_default()
    )
}
fn normalize(value: &mut Value, types: &Value) {
    if value["source"].is_null() {
        value["source"] = value["comic"]["sourceKey"].clone();
    }
    if value["comicId"].is_null() {
        value["comicId"] = value["comic"]["comicId"].clone();
    }
    if value["comicType"].is_null() {
        value["comicType"] = types[value["source"].as_str().unwrap_or_default()].clone();
    }
    value["_key"] = key(value).into();
    value["_running"] = false.into();
    value["_error"] = false.into();
    value["_speed"] = 0.into();
    value["message"] = "Paused".into();
    if crate::download_files::token(value).is_err() {
        value["_work"] = uuid::Uuid::new_v4().to_string().into();
        value["_legacyWork"] = true.into();
    }
}
impl Queue {
    pub fn open(engine: Arc<Engine>, options: Options, types: Value) -> Result<Arc<Self>> {
        let path = Path::new(&options.data_path).join("downloading_tasks.json");
        let mut items: Vec<Value> = if path.exists() {
            serde_json::from_slice(&fs::read(path)?)?
        } else {
            vec![]
        };
        let cleanup_path = Path::new(&options.data_path).join("download_cleanup.json");
        let cleanup: Vec<Value> = match fs::read(cleanup_path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => vec![],
            Err(error) => return Err(error.into()),
        };
        for item in &mut items {
            let needs_owner = crate::download_files::token(item).is_err();
            normalize(item, &types);
            if needs_owner {
                if let Some(request) = cleanup
                    .iter()
                    .find(|request| key(&request["item"]) == key(item))
                {
                    item["_work"] = request["item"]["_work"].clone();
                    item["_legacyWork"] = request["item"]["_legacyWork"].clone();
                }
            }
            if cleanup
                .iter()
                .any(|request| request["item"]["_work"] == item["_work"])
            {
                item["_cleanupOnly"] = true.into();
                item["message"] = "Cleaning up cancelled download...".into();
            }
        }
        let (snapshots, receiver) = tokio::sync::watch::channel(serde_json::to_string(&items)?);
        let (platform, platform_receiver) = tokio::sync::mpsc::channel(8);
        let queue = Arc::new(Self {
            engine,
            execution: tokio::sync::Mutex::new(()),
            state: Mutex::new(State {
                moving_storage: false,
                items,
                running: false,
                epoch: 0,
                cancel: None,
                options,
                cleanup,
            }),
            snapshots,
            snapshot_receiver: tokio::sync::Mutex::new(receiver),
            platform,
            platform_receiver: tokio::sync::Mutex::new(platform_receiver),
            acknowledgements: Mutex::new(HashMap::new()),
        });
        queue.schedule();
        Ok(queue)
    }
    fn publish(&self, state: &State, persist: bool) -> Result<()> {
        let json = serde_json::to_string(&state.items)?;
        if persist {
            let root = Path::new(&state.options.data_path);
            fs::create_dir_all(root)?;
            crate::atomic_file::write_json(&root.join("downloading_tasks.json"), &state.items)?;
        }
        self.snapshots.send_replace(json);
        Ok(())
    }
    pub fn snapshot(&self) -> String {
        self.snapshots.borrow().clone()
    }
    pub fn configure(&self, mut options: Options) -> Result<()> {
        let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
        options.local_path.clone_from(&state.options.local_path);
        options.saf = crate::local_operations::saf(&options.local_path);
        state.options = options;
        Ok(())
    }
    pub async fn move_storage(&self, destination: &str, android: bool) -> Result<String> {
        struct Moving<'a>(&'a Mutex<State>);
        impl Drop for Moving<'_> {
            fn drop(&mut self) {
                self.0
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .moving_storage = false;
            }
        }
        let options = {
            let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
            ensure!(
                !state.moving_storage
                    && state.items.is_empty()
                    && state.cleanup.is_empty()
                    && state.cancel.is_none(),
                "Finish or cancel queued downloads before moving the storage directory"
            );
            state.moving_storage = true;
            state.options.clone()
        };
        let _moving = Moving(&self.state);
        let warnings =
            crate::local_storage::relocate(self.engine.clone(), &options, destination, android)
                .await?;
        let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
        state.options.local_path = crate::local_storage::active(&self.engine, destination);
        state.options.saf = crate::local_operations::saf(&state.options.local_path);
        Ok(json!({"path":state.options.local_path,"warnings":warnings}).to_string())
    }
    pub fn add(self: &Arc<Self>, mut item: Value) -> Result<()> {
        item["_legacyWork"] = false.into();
        item["_work"] = uuid::Uuid::new_v4().to_string().into();
        normalize(&mut item, &json!({}));
        ensure!(item["comicType"].is_i64(), "Missing comic type");
        {
            let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
            ensure!(!state.moving_storage, "Storage directory is being moved");
            state
                .items
                .retain(|existing| key(existing) != key(&item) || existing["_cleanupOnly"] != true);
            ensure!(
                !state.items.iter().any(|v| key(v) == key(&item)),
                "Comic is already queued"
            );
            state.items.push(item);
            state.running = true;
            self.publish(&state, true)?;
        }
        self.schedule();
        Ok(())
    }
    fn persist_cleanup(&self, state: &State) -> Result<()> {
        crate::atomic_file::write_json(
            &Path::new(&state.options.data_path).join("download_cleanup.json"),
            &state.cleanup,
        )
    }
    pub async fn command(self: &Arc<Self>, id: &str, action: &str) -> Result<()> {
        ensure!(
            ["pause", "resume", "first", "cancel"].contains(&action),
            "Unknown queue command"
        );
        {
            let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
            let Some(index) = state.items.iter().position(|value| key(value) == id) else {
                ensure!(action == "cancel", "Download task not found");
                return Ok(());
            };
            if action == "cancel"
                && !state
                    .cleanup
                    .iter()
                    .any(|request| request["item"]["_work"] == state.items[index]["_work"])
            {
                let request = json!({"item":state.items[index],"options":state.options});
                state.cleanup.push(request);
                self.persist_cleanup(&state)?;
            }
            state.epoch += 1;
            if let Some(cancel) = &state.cancel {
                cancel.cancel();
            }
            for item in &mut state.items {
                item["_running"] = false.into();
                item["_speed"] = 0.into();
            }
            match action {
                "pause" => {
                    state.running = false;
                    state.items[index]["message"] = "Paused".into();
                }
                "resume" | "first" => {
                    let item = state.items.remove(index);
                    state.items.insert(0, item);
                    if action == "resume" {
                        state.running = true;
                    }
                }
                "cancel" => {
                    state.items[index]["_cleanupOnly"] = true.into();
                    state.items[index]["message"] = "Cleaning up cancelled download...".into();
                }
                _ => unreachable!(),
            }
            self.publish(&state, true)?;
        }
        // Keep the barrier through transport shutdown, extraction and every SAF receipt.
        // All later generations process durable cleanup requests before they can write.
        let cleanup = {
            let _execution = self.execution.lock().await;
            self.process_cleanup().await
        };
        self.schedule();
        cleanup
    }
    async fn process_cleanup(&self) -> Result<()> {
        loop {
            let request = {
                self.state
                    .lock()
                    .map_err(|_| anyhow!("Queue poisoned"))?
                    .cleanup
                    .first()
                    .cloned()
            };
            let Some(request) = request else {
                return Ok(());
            };
            let item = &request["item"];
            let token = crate::download_files::token(item)?;
            let options: Options = serde_json::from_value(request["options"].clone())?;
            let lock = format!(
                "local-comic:{}:{}:{}",
                options.data_path,
                item["comicType"],
                item["comicId"].as_str().unwrap_or_default()
            );
            let _comic = crate::http_policy::serial(&lock).await;
            let result = async {
                let mut work = if let Some(work) = crate::download_files::read(&options, token)? {
                    work
                } else {
                    let destination = item["path"]
                        .as_str()
                        .map(PathBuf::from)
                        .unwrap_or_else(|| Path::new(&options.local_path).join(token));
                    crate::download_files::Work::open(
                        options.clone(),
                        item,
                        key(item),
                        destination,
                    )?
                };
                work.clean(self, true).await
            }
            .await;
            let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
            match result {
                Ok(()) => {
                    state.items.retain(|item| item["_work"] != token);
                    self.publish(&state, true)?;
                    state
                        .cleanup
                        .retain(|request| request["item"]["_work"] != token);
                    self.persist_cleanup(&state)?;
                }
                Err(error) => {
                    state.running = false;
                    for pending in &mut state.items {
                        if pending["_work"] == token
                            || key(pending) == key(item)
                            || pending["_running"] == true
                        {
                            pending["_running"] = false.into();
                            pending["_error"] = true.into();
                            pending["message"] =
                                format!("Cleanup pending: {error:#}. Resume to retry.").into();
                        }
                    }
                    self.publish(&state, true)?;
                    return Err(error
                        .context("Cancelled download cleanup pending; resume or cancel to retry"));
                }
            }
        }
    }
    fn schedule(self: &Arc<Self>) {
        let start = {
            let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            if state.cancel.is_some() {
                return;
            }
            let item = if !state.cleanup.is_empty() {
                None
            } else {
                if !state.running {
                    return;
                }
                state
                    .items
                    .iter()
                    .find(|item| item["_cleanupOnly"] != true)
                    .cloned()
            };
            if item.is_none() && state.cleanup.is_empty() {
                return;
            }
            let cancel = Arc::new(HttpCancellation::new());
            state.cancel = Some(cancel.clone());
            if let Some(item) = &item {
                if let Some(row) = state
                    .items
                    .iter_mut()
                    .find(|row| row["_work"] == item["_work"])
                {
                    row["_running"] = true.into();
                    row["_error"] = false.into();
                    row["message"] = "Downloading...".into();
                }
            }
            let _ = self.publish(&state, false);
            (item, state.options.clone(), state.epoch, cancel)
        };
        let queue = self.clone();
        crate::script::executor().spawn(async move {
            let (item, options, epoch, cancel) = start;
            let result = {
                let _execution = queue.execution.lock().await;
                let work = async {
                    queue.process_cleanup().await?;
                    if let Some(item) = &item {
                        ensure!(!cancel.is_cancelled(), "Download cancelled");
                        queue.run(item.clone(), options, epoch, &cancel).await?;
                    }
                    Ok::<_, anyhow::Error>(())
                }
                .await;
                let cleanup = queue.process_cleanup().await;
                work.and(cleanup)
            };
            {
                let mut state = queue
                    .state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                if state
                    .cancel
                    .as_ref()
                    .is_some_and(|active| Arc::ptr_eq(active, &cancel))
                {
                    state.cancel = None;
                }
                if state.epoch == epoch {
                    if let Some(item) = &item {
                        if let Some(index) = state
                            .items
                            .iter()
                            .position(|row| row["_work"] == item["_work"])
                        {
                            match result {
                                Ok(()) => {
                                    state.items.remove(index);
                                }
                                Err(error) => {
                                    state.running = false;
                                    let row = &mut state.items[index];
                                    row["_running"] = false.into();
                                    row["_error"] = true.into();
                                    row["_speed"] = 0.into();
                                    row["message"] = format!("Error: {error:#}").into();
                                }
                            }
                        }
                    } else if result.is_err() {
                        state.running = false;
                    }
                }
                if let Err(error) = queue.publish(&state, true) {
                    state.running = false;
                    eprintln!("Download queue persistence failed: {error}");
                }
            }
            // A failed cleanup is retried by an explicit command or a later open.
            if queue
                .state
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .cleanup
                .is_empty()
            {
                queue.schedule();
            }
        });
    }
    fn update(&self, id: &str, epoch: u64, patch: Value, persist: bool) -> Result<()> {
        let mut state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
        ensure!(state.epoch == epoch, "Download cancelled");
        let item = state
            .items
            .iter_mut()
            .find(|v| key(v) == id)
            .context("Download cancelled")?;
        for (k, v) in patch.as_object().context("Invalid update")? {
            item[k] = v.clone();
        }
        self.publish(&state, persist)
    }
    pub fn resolve_platform(
        &self,
        id: &str,
        error: Option<String>,
        value: Option<String>,
    ) -> Result<()> {
        if let Some(sender) = self
            .acknowledgements
            .lock()
            .map_err(|_| anyhow!("Queue poisoned"))?
            .remove(id)
        {
            let result = match error {
                Some(error) => Err(anyhow!(error)),
                None => value
                    .map(|value| serde_json::from_str(&value).map_err(Into::into))
                    .unwrap_or(Ok(Value::Null)),
            };
            let _ = sender.send(result);
        }
        Ok(())
    }
    pub(crate) async fn platform_operation(
        &self,
        operation: &str,
        from: &Path,
        to: Option<&Path>,
    ) -> Result<Value> {
        let id = uuid::Uuid::new_v4().to_string();
        let (sender, receiver) = tokio::sync::oneshot::channel();
        self.acknowledgements
            .lock()
            .map_err(|_| anyhow!("Queue poisoned"))?
            .insert(id.clone(), sender);
        if self.platform.send(json!({"id":id,"operation":operation,"from":from.to_string_lossy(),"to":to.map(|path|path.to_string_lossy())}).to_string()).await.is_err() {
            self.acknowledgements.lock().unwrap_or_else(|error|error.into_inner()).remove(&id);
            anyhow::bail!("Platform event listener stopped");
        }
        receiver.await?
    }
    #[allow(clippy::too_many_arguments)]
    async fn image(
        &self,
        options: &Options,
        source: &str,
        comic: &str,
        chapter: &str,
        image: &str,
        thumbnail: bool,
        id: &str,
        epoch: u64,
        cancellation: &HttpCancellation,
    ) -> Result<Vec<u8>> {
        for attempt in 0..3 {
            ensure!(!cancellation.is_cancelled(), "Download cancelled");
            let task = crate::image_tasks::Task::start(
                self.engine.clone(),
                options.data_path.clone(),
                options.cache_path.clone(),
                image.into(),
                Some(source.into()),
                comic.into(),
                chapter.into(),
                thumbnail,
                false,
            )?;
            let work = async {
                let mut receiver = task.receiver.lock().await;
                let started = Instant::now();
                let mut last = Instant::now();
                while let Some(progress) = receiver.recv().await {
                    if let Some(error) = progress.error {
                        return Err(anyhow!(error));
                    }
                    if let Some(bytes) = progress.bytes {
                        return Ok(bytes);
                    }
                    if last.elapsed().as_millis() > 300 {
                        self.update(id,epoch,json!({"_speed":(progress.current as f64/started.elapsed().as_secs_f64().max(0.1)) as u64}),false)?;
                        last = Instant::now();
                    }
                }
                Err(anyhow!("Image stream ended without data"))
            };
            let result = tokio::select! {
                _ = cancellation.cancelled() => {
                    task.cancel_and_wait().await;
                    return Err(anyhow!("Download cancelled"));
                }
                result = work => result,
            };
            match result {
                Ok(bytes) => return Ok(bytes),
                Err(error) if attempt == 2 => return Err(error),
                Err(_) => {
                    tokio::select! { _=cancellation.cancelled()=>return Err(anyhow!("Download cancelled")), _=tokio::time::sleep(std::time::Duration::from_secs(attempt + 1))=>{} }
                }
            }
        }
        unreachable!()
    }
    async fn run(
        &self,
        mut item: Value,
        options: Options,
        epoch: u64,
        cancellation: &Arc<HttpCancellation>,
    ) -> Result<()> {
        let id = key(&item);
        let source = item["source"]
            .as_str()
            .context("Missing source")?
            .to_owned();
        // Hold the source through all chapter/image calls and final registration.
        // Child image tasks reuse this protection rather than acquiring a nested
        // read lock while an update is waiting for the download to finish.
        let source_lock = self.engine.source_lock(&source);
        let _source_guard = tokio::select! { _=cancellation.cancelled()=>return Err(anyhow!("Download cancelled")), guard=source_lock.read_owned()=>guard };
        let comic_id = item["comicId"]
            .as_str()
            .context("Missing comic id")?
            .to_owned();
        let comic_type = item["comicType"].as_i64().context("Missing comic type")? as i32;
        let comic_lock = format!("local-comic:{}:{comic_type}:{comic_id}", options.data_path);
        let _comic_guard = tokio::select! {
            _ = cancellation.cancelled() => return Err(anyhow!("Download cancelled")),
            guard = crate::http_policy::serial(&comic_lock) => guard,
        };
        if item["comic"].is_null() {
            let mut comic = evaluate_with_retry(
                &self.engine,
                &format!(
                    "ComicSource.sources[{}].comic.loadInfo({})",
                    json!(source),
                    json!(comic_id)
                ),
                cancellation,
            )
            .await?;
            comic["comicId"] = comic_id.clone().into();
            comic["sourceKey"] = source.clone().into();
            item["comic"] = comic;
            self.update(&id, epoch, json!({"comic":item["comic"]}), true)?;
        }
        let comic = item["comic"].clone();
        let title = comic["title"].as_str().context("Missing comic title")?;
        let library = crate::local::LocalLibrary::open(&format!("{}/local.db", options.data_path))?;
        let existing = library.find(&comic_id, comic_type)?;
        drop(library);
        let destination = if let Some(existing) = &existing {
            Path::new(&options.local_path).join(&existing.directory)
        } else if let Some(path) = item["path"].as_str() {
            PathBuf::from(path)
        } else {
            Path::new(&options.local_path).join(format!(
                "{}-{}",
                crate::api::local::chapter_directory_name(title.chars().take(65).collect()),
                &uuid::Uuid::new_v4().to_string()[..8]
            ))
        };
        let mut ownership = crate::download_files::Work::open(
            options.clone(),
            &item,
            id.clone(),
            destination.clone(),
        )?;
        if ownership.committed()? {
            ownership.clean(self, true).await?;
            return Ok(());
        }
        ownership.clean(self, false).await?;
        let result = self
            .transfer(item, options, epoch, cancellation, &mut ownership, existing)
            .await;
        let cleanup = ownership.clean(self, false).await;
        result.and(cleanup)
    }

    async fn transfer(
        &self,
        item: Value,
        options: Options,
        epoch: u64,
        cancellation: &Arc<HttpCancellation>,
        ownership: &mut crate::download_files::Work,
        existing: Option<crate::local::LocalComic>,
    ) -> Result<()> {
        let id = key(&item);
        let source = item["source"]
            .as_str()
            .context("Missing source")?
            .to_owned();
        let comic_id = item["comicId"]
            .as_str()
            .context("Missing comic ID")?
            .to_owned();
        let comic_type = item["comicType"].as_i64().context("Missing comic type")? as i32;
        let comic = item["comic"].clone();
        let title = comic["title"].as_str().context("Missing comic title")?;
        let destination = ownership.destination.clone();
        let working = ownership.payload();
        fs::create_dir_all(&working)?;
        self.update(
            &id,
            epoch,
            json!({"path":destination.to_string_lossy()}),
            true,
        )?;
        let cover = if item["type"] == "ArchiveDownloadTask" {
            let archive = ownership.archive();
            fs::create_dir_all(archive.parent().unwrap())?;
            let task = crate::api::download::FileDownload::start(
                item["archiveUrl"]
                    .as_str()
                    .context("Missing archive URL")?
                    .into(),
                archive.to_string_lossy().into(),
                options.threads.clamp(1, 32) as u32,
                options.http.clone(),
            )
            .await?;
            let download_result = async {
                let mut finished = false;
                loop {
                    let progress = tokio::select! {
                        _ = cancellation.cancelled() => return Err(anyhow!("Download cancelled")),
                        progress = task.next_status() => progress?,
                    };
                    let Some(progress) = progress else {
                        break;
                    };
                    self.update(
                        &id,
                        epoch,
                        json!({
                            "_speed": progress.bytes_per_second,
                            "downloadedCount": progress.downloaded_bytes,
                            "totalCount": progress.total_bytes,
                            "message": "Downloading archive..."
                        }),
                        false,
                    )?;
                    finished = progress.finished;
                }
                ensure!(finished, "Archive download interrupted");
                Ok::<_, anyhow::Error>(())
            }
            .await;
            task.stop().await?;
            download_result?;
            self.update(
                &id,
                epoch,
                json!({"message":"Extracting archive..."}),
                false,
            )?;
            let extract_archive = archive.clone();
            let extract_working = working.clone();
            let extract_cancel = cancellation.clone();
            tokio::task::spawn_blocking(move || {
                crate::archives::extract_cancellable(
                    &extract_archive,
                    &extract_working,
                    &extract_cancel,
                )
            })
            .await??;
            let _ = fs::remove_file(archive);
            let mut files = fs::read_dir(&working)?
                .filter_map(|e| e.ok())
                .filter(|e| e.path().is_file() && is_image(&e.path()))
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            files.sort();
            files
                .iter()
                .find(|p| p.starts_with("cover."))
                .or(files.first())
                .context("Archive contains no images")?
                .clone()
        } else {
            let saved_cover = ownership.existing_cover(self).await?;
            let cover = fs::read_dir(&working)?
                .filter_map(|v| v.ok())
                .find(|v| v.file_name().to_string_lossy().starts_with("cover."));
            let cover = if let Some(saved) = saved_cover {
                saved
            } else if let Some(cover) = cover {
                cover.file_name().to_string_lossy().into_owned()
            } else {
                let bytes = self
                    .image(
                        &options,
                        &source,
                        &comic_id,
                        "",
                        comic["cover"].as_str().context("Missing cover")?,
                        true,
                        &id,
                        epoch,
                        cancellation,
                    )
                    .await?;
                ensure!(!cancellation.is_cancelled(), "Download cancelled");
                let name = format!("cover.{}", extension(&bytes));
                write_image(&working.join(&name), &bytes)?;
                name
            };
            self.update(
                &id,
                epoch,
                json!({"cover":format!("file://{}",if working.join(&cover).is_file(){working.join(&cover)}else{destination.join(&cover)}.display())}),
                true,
            )?;
            let chapter_ids = if comic["chapters"].is_null() {
                vec![String::new()]
            } else {
                crate::local::chapter_ids(&comic["chapters"])
            };
            for chapter in &chapter_ids {
                if !chapter.is_empty() {
                    let directory = crate::api::local::chapter_directory_name(chapter.clone());
                    ensure!(
                        crate::archives::safe_relative(&directory)?
                            .components()
                            .count()
                            == 1,
                        "Invalid chapter directory"
                    );
                }
            }
            let selected = item["chapters"].as_array();
            let mut images = item["images"].as_object().cloned().unwrap_or_default();
            images.retain(|chapter, _| {
                chapter_ids.contains(chapter)
                    && selected.is_none_or(|selected| selected.contains(&json!(chapter)))
                    && !existing
                        .as_ref()
                        .is_some_and(|comic| comic.downloaded_chapters.contains(chapter))
            });
            for chapter in chapter_ids.iter().filter(|c| {
                selected.is_none_or(|s| s.contains(&json!(c)))
                    && !existing
                        .as_ref()
                        .is_some_and(|comic| comic.downloaded_chapters.contains(c))
            }) {
                if !images.contains_key(chapter) {
                    self.update(
                        &id,
                        epoch,
                        json!({"message":"Fetching image list..."}),
                        false,
                    )?;
                    let pages = evaluate_with_retry(
                        &self.engine,
                        &format!(
                            "ComicSource.sources[{}].comic.loadEp({},{})",
                            json!(source),
                            json!(comic_id),
                            if chapter.is_empty() {
                                Value::Null
                            } else {
                                json!(chapter)
                            }
                        ),
                        cancellation,
                    )
                    .await?;
                    ensure!(pages["images"].is_array(), "Invalid image list");
                    images.insert(chapter.clone(), pages["images"].clone());
                    self.update(&id, epoch, json!({"images":images}), true)?;
                }
            }
            let total: usize = images
                .values()
                .filter_map(Value::as_array)
                .map(Vec::len)
                .sum();
            let completed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            self.update(
                &id,
                epoch,
                json!({"totalCount":total,"downloadedCount":0}),
                true,
            )?;
            let chapterless = comic["chapters"].is_null();
            for (chapter, pages) in &images {
                let directory = if comic["chapters"].is_null() {
                    working.clone()
                } else {
                    working.join(crate::api::local::chapter_directory_name(chapter.clone()))
                };
                fs::create_dir_all(&directory)?;
                let pages = pages.as_array().context("Invalid saved image list")?;
                stream::iter(pages.clone().into_iter().enumerate().map(|(index, image)| {
                    let directory = &directory;
                    let completed = &completed;
                    let id = &id;
                    let source = &source;
                    let comic_id = &comic_id;
                    let options = &options;
                    let ownership = &ownership;
                    async move {
                        let relative = if chapterless {
                            PathBuf::new()
                        } else {
                            PathBuf::from(crate::api::local::chapter_directory_name(
                                chapter.clone(),
                            ))
                        };
                        let staged =
                            fs::read_dir(directory)?
                                .filter_map(|entry| entry.ok())
                                .any(|entry| {
                                    entry.path().is_file()
                                        && entry
                                            .path()
                                            .file_stem()
                                            .is_some_and(|stem| stem == index.to_string().as_str())
                                        && is_image(&entry.path())
                                });
                        let exists =
                            staged || ownership.existing_page(self, &relative, index).await?;
                        if !exists {
                            let bytes = self
                                .image(
                                    options,
                                    source,
                                    comic_id,
                                    chapter,
                                    image.as_str().context("Invalid image key")?,
                                    false,
                                    id,
                                    epoch,
                                    cancellation,
                                )
                                .await?;
                            ensure!(!cancellation.is_cancelled(), "Download cancelled");
                            write_image(
                                &directory.join(format!("{index}.{}", extension(&bytes))),
                                &bytes,
                            )?;
                        }
                        let count =
                            completed.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                        self.update(
                            id,
                            epoch,
                            json!({"downloadedCount":count,"message":format!("{count}/{total}")}),
                            true,
                        )
                    }
                }))
                .buffer_unordered(options.threads.clamp(1, 32))
                .try_collect::<Vec<_>>()
                .await?;
            }
            cover
        };
        self.update(&id, epoch, json!({"message":"Saving files..."}), false)?;
        ownership.promote(self, cancellation).await?;
        let tags = comic["tags"]
            .as_object()
            .map(|tags| {
                tags.iter()
                    .flat_map(|(k, v)| {
                        v.as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(move |s| s.as_str().map(|s| format!("{k}:{s}")))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let downloaded_chapters = item["chapters"]
            .as_array()
            .map(|v| {
                v.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_else(|| crate::local::chapter_ids(&comic["chapters"]));
        let record = crate::local::LocalComic {
            id: comic_id,
            title: title.into(),
            subtitle: comic["subTitle"]
                .as_str()
                .or(comic["subtitle"].as_str())
                .unwrap_or_default()
                .into(),
            tags,
            directory: destination
                .file_name()
                .context("Invalid comic directory")?
                .to_string_lossy()
                .into(),
            chapters: comic["chapters"].clone(),
            cover,
            comic_type,
            downloaded_chapters,
            created_at: crate::cache::now_ms(),
        };
        let state = self.state.lock().map_err(|_| anyhow!("Queue poisoned"))?;
        ensure!(state.epoch == epoch, "Download cancelled");
        crate::local::LocalLibrary::open(&format!("{}/local.db", options.data_path))?
            .save_download(record, &ownership.token)?;
        drop(state);
        Ok(())
    }
}
async fn evaluate_with_retry(
    engine: &Engine,
    code: &str,
    cancellation: &HttpCancellation,
) -> Result<Value> {
    for attempt in 0..3 {
        let result = tokio::select! { _=cancellation.cancelled()=>return Err(anyhow!("Download cancelled")), result=crate::image_tasks::evaluate(engine,code)=>result };
        match result {
            Ok(value) => return Ok(value),
            Err(error) if attempt == 2 => return Err(error),
            Err(_) => {
                tokio::select! { _=cancellation.cancelled()=>return Err(anyhow!("Download cancelled")), _=tokio::time::sleep(std::time::Duration::from_secs(attempt+1))=>{} }
            }
        }
    }
    unreachable!()
}
fn extension(bytes: &[u8]) -> &'static str {
    match image::guess_format(bytes) {
        Ok(image::ImageFormat::Jpeg) => "jpg",
        Ok(image::ImageFormat::Gif) => "gif",
        Ok(image::ImageFormat::WebP) => "webp",
        Ok(image::ImageFormat::Bmp) => "bmp",
        _ => "png",
    }
}
pub(crate) fn is_image(path: &Path) -> bool {
    path.extension().and_then(|v| v.to_str()).is_some_and(|v| {
        ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif"]
            .contains(&v.to_ascii_lowercase().as_str())
    })
}
fn write_image(path: &Path, bytes: &[u8]) -> Result<()> {
    ensure!(!bytes.is_empty(), "Empty image");
    let mut file = tempfile::NamedTempFile::new_in(path.parent().context("Missing directory")?)?;
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    file.persist(path)
        .with_context(|| format!("Cannot save image {}", path.display()))?;
    Ok(())
}
