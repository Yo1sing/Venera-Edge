use crate::{
    image_tasks::{self, Request, Task},
    local_operations::{resolve, saf, Files},
    script::Engine,
};
use anyhow::{ensure, Context, Result};
use base64::Engine as _;
use serde::Deserialize;
use serde_json::json;
use std::{path::Path, sync::Arc, time::Duration};

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum View {
    Reader {
        image: String,
        source: Option<String>,
        comic: String,
        chapter: String,
        page: u32,
        processor: Option<String>,
    },
    Thumbnail {
        image: String,
        source: Option<String>,
        comic: String,
        fallback_type: Option<i32>,
    },
    LocalCover {
        comic: String,
        comic_type: i32,
    },
    HistoryCover {
        image: String,
        source: Option<String>,
        comic: String,
        comic_type: i32,
    },
}

struct Paths {
    data: String,
    cache: String,
    local: String,
}

pub(crate) fn start(
    engine: Arc<Engine>,
    data: String,
    cache: String,
    local: String,
    view: View,
) -> Result<Task> {
    let paths = Paths { data, cache, local };
    Task::spawn_managed(engine.clone(), move |state, _| async move {
        let bytes = tokio::select! {
            biased;
            _ = state.cancellation.cancelled() => anyhow::bail!("Image request cancelled"),
            bytes = load(&engine, &paths, &view, &state) => bytes?,
        };
        if let View::Reader {
            source,
            comic,
            chapter,
            page,
            processor: Some(processor),
            ..
        } = &view
        {
            if !processor.trim().is_empty() {
                return process(
                    &engine,
                    &state,
                    bytes,
                    processor,
                    json!([comic, chapter, page, source]),
                )
                .await;
            }
        }
        Ok(bytes)
    })
}

async fn load(
    engine: &Arc<Engine>,
    paths: &Paths,
    view: &View,
    state: &Request,
) -> Result<Vec<u8>> {
    match view {
        View::Reader {
            image,
            source,
            comic,
            chapter,
            ..
        } => {
            transfer(
                engine,
                paths,
                state,
                image,
                source.as_deref(),
                comic,
                Some(chapter),
            )
            .await
        }
        View::LocalCover { comic, comic_type } => local_cover(engine, paths, comic, *comic_type)
            .await?
            .context("Cover not found"),
        View::Thumbnail {
            image,
            source,
            comic,
            fallback_type,
        } => match transfer(engine, paths, state, image, source.as_deref(), comic, None).await {
            Ok(bytes) => Ok(bytes),
            Err(error) => {
                if let Some(kind) = fallback_type {
                    if let Ok(Some(bytes)) = local_cover(engine, paths, comic, *kind).await {
                        return Ok(bytes);
                    }
                }
                Err(error)
            }
        },
        View::HistoryCover {
            image,
            source,
            comic,
            comic_type,
        } => {
            if !image.contains('/') {
                if let Some(bytes) = local_cover(engine, paths, comic, *comic_type).await? {
                    return Ok(bytes);
                }
                let source = source.as_deref().context("Comic source not found")?;
                let current =
                    history_cover(engine, paths, source, comic, *comic_type, image).await?;
                return transfer(engine, paths, state, &current, Some(source), comic, None).await;
            }
            transfer(engine, paths, state, image, source.as_deref(), comic, None).await
        }
    }
}

async fn transfer(
    engine: &Arc<Engine>,
    paths: &Paths,
    state: &Request,
    image: &str,
    source: Option<&str>,
    comic: &str,
    chapter: Option<&str>,
) -> Result<Vec<u8>> {
    if let Some(path) = image.strip_prefix("file://") {
        let _root = crate::local_storage::FILES.read().await;
        return read(engine, path)
            .await?
            .context("Image file not found or empty");
    }
    let transfer = Task::start(
        engine.clone(),
        paths.data.clone(),
        paths.cache.clone(),
        image.into(),
        source.map(str::to_owned),
        comic.into(),
        chapter.unwrap_or_default().into(),
        chapter.is_none(),
        true,
    )?;
    let mut receiver = transfer.receiver.lock().await;
    while let Some(event) = receiver.recv().await {
        if let Some(error) = event.error {
            anyhow::bail!("{error}");
        }
        if let Some(bytes) = event.bytes {
            return Ok(bytes);
        }
        state.progress(event.current, event.total);
    }
    anyhow::bail!("Image stream ended without data")
}

async fn read(engine: &Engine, path: &str) -> Result<Option<Vec<u8>>> {
    let bytes = if saf(path) {
        let value = engine
            .request_platform(json!({"method":"localFile","operation":"read","path":path}))
            .await?;
        crate::script_crypto::bytes(&value)?
    } else {
        let path = path.to_owned();
        match tokio::task::spawn_blocking(move || std::fs::read(path)).await? {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        }
    };
    Ok((!bytes.is_empty()).then_some(bytes))
}

async fn local_cover(
    engine: &Arc<Engine>,
    paths: &Paths,
    id: &str,
    kind: i32,
) -> Result<Option<Vec<u8>>> {
    let _root = crate::local_storage::FILES.read().await;
    let db = Path::new(&paths.data).join("local.db");
    if !db.is_file() {
        return Ok(None);
    }
    let Some(comic) = crate::local::LocalLibrary::open(&db.to_string_lossy())?.find(id, kind)?
    else {
        return Ok(None);
    };
    let root = crate::local_storage::active(engine, &paths.local);
    let directory = resolve(&root, &comic.directory)?;
    let files = Files::new(engine.clone());
    if !comic.cover.is_empty() {
        let cover = resolve(&directory, &comic.cover)?;
        if let Ok(Some(bytes)) = read(engine, &cover).await {
            return Ok(Some(bytes));
        }
    }
    if !files.exists(&directory).await? {
        return Ok(None);
    }
    let entries = files.list(&directory).await?;
    let mut dirs = Vec::new();
    let mut images = Vec::new();
    for entry in entries {
        if entry.is_dir {
            dirs.push(entry.path);
        } else if crate::local_operations::is_image(&entry.path) {
            images.push(entry.path);
        }
    }
    dirs.sort();
    if let Some(bytes) = first_image(engine, images).await {
        return Ok(Some(bytes));
    }
    for dir in dirs {
        let images = files
            .list(&dir)
            .await?
            .into_iter()
            .filter(|entry| !entry.is_dir && crate::local_operations::is_image(&entry.path))
            .map(|entry| entry.path)
            .collect();
        if let Some(bytes) = first_image(engine, images).await {
            return Ok(Some(bytes));
        }
    }
    Ok(None)
}

async fn first_image(engine: &Engine, paths: Vec<String>) -> Option<Vec<u8>> {
    for path in crate::api::local::sort_comic_images(paths) {
        if let Ok(Some(bytes)) = read(engine, path.strip_prefix("file://").unwrap_or(&path)).await {
            return Some(bytes);
        }
    }
    None
}

async fn history_cover(
    engine: &Engine,
    paths: &Paths,
    source: &str,
    comic: &str,
    kind: i32,
    old: &str,
) -> Result<String> {
    let _storage = crate::backup_storage::OPERATIONS.read().await;
    let lock = engine.source_lock(source);
    let _source = lock.read().await;
    let db = Path::new(&paths.data).join("history.db");
    if db.is_file() {
        if let Some(current) =
            crate::history::History::open(&db.to_string_lossy())?.find(comic, kind)?
        {
            if current.cover != old && !current.cover.is_empty() {
                return Ok(current.cover);
            }
        }
    }
    let code = format!(
        "ComicSource.sources[{}].comic.loadInfo({})",
        json!(source),
        json!(comic)
    );
    let info = image_tasks::evaluate(engine, &code).await?;
    let cover = info["cover"]
        .as_str()
        .filter(|cover| !cover.is_empty())
        .context("Comic source returned an invalid cover")?;
    if db.is_file() {
        crate::history::History::open(&db.to_string_lossy())?
            .update_cover(comic, kind, old, cover)?;
    }
    Ok(cover.into())
}

async fn process(
    engine: &Engine,
    state: &Request,
    bytes: Vec<u8>,
    script: &str,
    args: serde_json::Value,
) -> Result<Vec<u8>> {
    static PROCESSORS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
    let _permit = tokio::select! {
        biased;
        _ = state.cancellation.cancelled() => anyhow::bail!("Image request cancelled"),
        permit = PROCESSORS.acquire() => permit?,
    };
    let worker = Arc::new(engine.fork_sources()?);
    let base64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let code = format!(
        "__images.process({}, {}, ...{})",
        json!(script),
        json!(base64),
        args
    );
    let result = tokio::select! {
        biased;
        _ = state.cancellation.cancelled() => None,
        result = tokio::time::timeout(
            Duration::from_secs(60), image_tasks::evaluate_worker(worker.clone(), code)
        ) => Some(result),
    };
    if result.is_none() {
        let _ = tokio::time::timeout(
            Duration::from_millis(250),
            image_tasks::evaluate_worker(worker.clone(), "__images.cancelProcessor()".into()),
        )
        .await;
    }
    worker.shutdown().await;
    match result {
        None => anyhow::bail!("Image request cancelled"),
        Some(Err(_)) => anyhow::bail!("Custom image processing timed out"),
        Some(Ok(result)) => {
            let result = result?;
            if result.is_null() {
                return Ok(bytes);
            }
            let output = crate::script_crypto::bytes(&result)?;
            ensure!(
                !output.is_empty(),
                "Custom image processing returned an empty image"
            );
            Ok(output)
        }
    }
}

pub(crate) fn invalidate(data: &str, cache: &str, view: &View) -> Result<()> {
    let (image, source, comic, chapter, thumbnail) = match view {
        View::Reader {
            image,
            source,
            comic,
            chapter,
            ..
        } => (image.clone(), source, comic, chapter.as_str(), false),
        View::Thumbnail {
            image,
            source,
            comic,
            ..
        } => (image.clone(), source, comic, "", true),
        View::HistoryCover {
            image,
            source,
            comic,
            comic_type,
        } => {
            let db = Path::new(data).join("history.db");
            let current = if db.is_file() {
                crate::history::History::open(&db.to_string_lossy())?
                    .find(comic, *comic_type)?
                    .map(|row| row.cover)
            } else {
                None
            };
            (
                current.unwrap_or_else(|| image.clone()),
                source,
                comic,
                "",
                true,
            )
        }
        View::LocalCover { .. } => return Ok(()),
    };
    if image.starts_with("file://") {
        return Ok(());
    }
    let key = image_tasks::cache_key(&image, source.as_deref(), comic, chapter, thumbnail);
    crate::cache::shared(data, cache)?
        .lock()
        .map_err(|_| anyhow::anyhow!("Cache poisoned"))?
        .delete(&key)
}
