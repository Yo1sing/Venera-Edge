use crate::{
    api::{
        history::{ComicKey, HistoryEntry, HistoryRefreshProgress},
        http::HttpCancellation,
    },
    backup_storage::{Database, OPERATIONS},
    history::History,
    script::Engine,
};
use anyhow::{Context, Result};
use futures_util::{stream, StreamExt};
use serde_json::json;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{watch, Mutex};
use tokio::time::{sleep, sleep_until, Instant};

pub struct Task {
    cancellation: Arc<HttpCancellation>,
    progress: Mutex<watch::Receiver<HistoryRefreshProgress>>,
}

impl Drop for Task {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl Task {
    pub fn start(
        store: Arc<Database<History>>,
        runtime: Arc<Engine>,
        sources: HashMap<i32, String>,
        key: Option<ComicKey>,
    ) -> Result<Self> {
        let items = store.with(|history| match key {
            Some(key) => Ok(history.find(&key.id, key.comic_type)?.into_iter().collect()),
            None => history.list(None),
        })?;
        let total = items.len().try_into()?;
        let initial = HistoryRefreshProgress {
            total,
            current: 0,
            success: 0,
            failed: 0,
            skipped: 0,
        };
        let (sender, mut progress) = watch::channel(initial);
        progress.mark_changed();
        let cancellation = Arc::new(HttpCancellation::new());
        let stop = cancellation.clone();
        crate::script::executor().spawn(async move {
            let next_request = Mutex::new(Instant::now());
            let mut results = stream::iter(items)
                .map(|item| {
                    let source = sources.get(&item.comic_type);
                    let store = &store;
                    let runtime = &runtime;
                    let stop = &stop;
                    let next_request = &next_request;
                    async move {
                        let Some(source) = source.filter(|_| item.comic_type != 0) else {
                            return Outcome::Skipped;
                        };
                        match refresh(store, runtime, stop, next_request, item, source).await {
                            Ok(true) => Outcome::Success,
                            Ok(false) => Outcome::Skipped,
                            Err(_) if stop.is_cancelled() => Outcome::Skipped,
                            Err(_) => Outcome::Failed,
                        }
                    }
                })
                .buffer_unordered(5);
            let mut progress = sender.borrow().clone();
            while let Some(result) = results.next().await {
                match result {
                    Outcome::Success => progress.success += 1,
                    Outcome::Failed => progress.failed += 1,
                    Outcome::Skipped => progress.skipped += 1,
                }
                progress.current += 1;
                sender.send_replace(progress.clone());
            }
        });
        Ok(Self {
            cancellation,
            progress: Mutex::new(progress),
        })
    }

    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub async fn next(&self) -> Option<HistoryRefreshProgress> {
        let mut progress = self.progress.lock().await;
        progress.changed().await.ok()?;
        let value = progress.borrow_and_update().clone();
        Some(value)
    }
}

enum Outcome {
    Success,
    Failed,
    Skipped,
}

async fn refresh(
    store: &Database<History>,
    runtime: &Engine,
    stop: &HttpCancellation,
    next_request: &Mutex<Instant>,
    item: HistoryEntry,
    source: &str,
) -> Result<bool> {
    let source_lock = runtime.source_lock(source);
    let _operation = tokio::select! {
        biased;
        _ = stop.cancelled() => return Ok(false),
        guard = OPERATIONS.read() => guard,
    };
    let _source = tokio::select! {
        biased;
        _ = stop.cancelled() => return Ok(false),
        guard = source_lock.read() => guard,
    };
    let code = format!(
        "(async()=>{{const source=ComicSource.sources[{}];if(typeof source?.comic?.loadInfo!=='function') return null;await source.init?.();return source.comic.loadInfo({});}})()",
        json!(source),
        json!(item.id)
    );
    for attempt in 0..3 {
        let ready = async {
            if attempt > 0 {
                sleep(Duration::from_secs(2)).await;
            }
            let mut next = next_request.lock().await;
            sleep_until(*next).await;
            *next = Instant::now() + Duration::from_millis(400);
        };
        tokio::select! {
            biased;
            _ = stop.cancelled() => return Ok(false),
            _ = ready => {}
        }
        let worker = Arc::new(runtime.fork_sources()?);
        let eval_worker = worker.clone();
        let code = code.clone();
        let mut evaluation =
            tokio::spawn(async move { crate::image_tasks::evaluate(&eval_worker, &code).await });
        let result = tokio::select! {
            biased;
            _ = stop.cancelled() => None,
            result = tokio::time::timeout(Duration::from_secs(60), &mut evaluation) => Some(result),
        };
        worker.shutdown().await;
        let value = match result {
            None => {
                let _ = evaluation.await;
                return Ok(false);
            }
            Some(Ok(result)) => result?,
            Some(Err(_)) => {
                let _ = evaluation.await;
                Err(anyhow::anyhow!("Comic source request timed out"))
            }
        };
        let metadata = value.and_then(|value| {
            if value.is_null() {
                return Ok(None);
            }
            Ok(Some((
                value["title"]
                    .as_str()
                    .context("Invalid comic title")?
                    .to_owned(),
                value["subtitle"].as_str().unwrap_or_default().to_owned(),
                value["cover"]
                    .as_str()
                    .context("Invalid comic cover")?
                    .to_owned(),
            )))
        });
        match metadata {
            Ok(Some((title, subtitle, cover))) if !stop.is_cancelled() => {
                return store
                    .with(|history| history.update_metadata(&item, &title, &subtitle, &cover));
            }
            Ok(_) => return Ok(false),
            Err(error) if attempt == 2 => return Err(error),
            Err(_) => {}
        }
    }
    unreachable!("last attempt returns a result")
}
