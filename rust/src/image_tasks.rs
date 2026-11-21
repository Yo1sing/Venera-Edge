use crate::api::{http::HttpCancellation, media::ImageProgress};
use anyhow::{Context, Result};
use serde_json::json;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

static THUMBNAIL_REQUESTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(8);

pub struct Request {
    pub cancellation: Arc<HttpCancellation>,
    pub sender: tokio::sync::mpsc::Sender<ImageProgress>,
}
impl Request {
    pub fn progress(&self, current: u64, total: Option<u64>) {
        let _ = self.sender.try_send(ImageProgress {
            current,
            total,
            bytes: None,
            error: None,
        });
    }
}
fn registry() -> &'static Mutex<std::collections::HashMap<String, Weak<Request>>> {
    static REGISTRY: OnceLock<Mutex<std::collections::HashMap<String, Weak<Request>>>> =
        OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}
pub fn request(id: &str) -> Option<Arc<Request>> {
    registry().lock().ok()?.get(id)?.upgrade()
}

pub struct Task {
    pub state: Arc<Request>,
    engine: Arc<crate::script::Engine>,
    id: String,
    finished: Arc<std::sync::atomic::AtomicBool>,
    pub receiver: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<ImageProgress>>,
}
impl Drop for Task {
    fn drop(&mut self) {
        self.cancel();
    }
}
pub async fn evaluate(engine: &crate::script::Engine, code: &str) -> Result<serde_json::Value> {
    settle(engine, engine.evaluate(code)?).await
}

pub(crate) async fn evaluate_worker(
    engine: Arc<crate::script::Engine>,
    code: String,
) -> Result<serde_json::Value> {
    let worker = engine.clone();
    let wire = tokio::task::spawn_blocking(move || worker.evaluate(&code)).await??;
    settle(&engine, wire).await
}

async fn settle(engine: &crate::script::Engine, wire: String) -> Result<serde_json::Value> {
    let mut wire: serde_json::Value = serde_json::from_str(&wire)?;
    if wire[0] == "promise" {
        wire = serde_json::from_str(
            &engine
                .promise(wire[1].as_u64().context("Invalid promise")?)
                .await?,
        )?;
    }
    crate::script::unpack(&wire)
}
impl Task {
    pub fn cancel(&self) {
        self.state.cancellation.cancel();
        if !self.finished.load(std::sync::atomic::Ordering::Relaxed) {
            let _ = self
                .engine
                .evaluate(&format!("__images.cancel({})", json!(self.id)));
        }
    }
    pub async fn cancel_and_wait(&self) {
        self.cancel();
        let mut receiver = self.receiver.lock().await;
        while let Some(progress) = receiver.recv().await {
            if progress.error.is_some() || progress.bytes.is_some() {
                break;
            }
        }
    }
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        engine: Arc<crate::script::Engine>,
        data_path: String,
        cache_path: String,
        image: String,
        source: Option<String>,
        comic: String,
        chapter: String,
        thumbnail: bool,
        interactive: bool,
    ) -> Result<Self> {
        Self::spawn(engine.clone(), move |state, id| async move {
            let key = cache_key(&image, source.as_deref(), &comic, &chapter, thumbnail);
            let _permit = if thumbnail && interactive {
                Some(THUMBNAIL_REQUESTS.acquire().await?)
            } else {
                None
            };
            let source_lock = source
                .as_deref()
                .filter(|_| interactive)
                .map(|key| engine.source_lock(key));
            let _source_guard = match source_lock {
                Some(lock) => Some(lock.read_owned().await),
                None => None,
            };
            let _lock = crate::http_policy::serial(&format!("image:{key}")).await;
            let cache = crate::cache::shared(&data_path, &cache_path)?;
            let hit = cache
                .lock()
                .map_err(|_| anyhow::anyhow!("Cache poisoned"))?
                .find(&key)?;
            if let Some(path) = hit {
                return Ok(std::fs::read(path)?);
            }
            let load = || {
                fetch(
                    &engine,
                    &state,
                    &id,
                    &image,
                    source.as_deref(),
                    &comic,
                    &chapter,
                    thumbnail,
                )
            };
            // The download queue coordinates source access and its own retries.
            let bytes = if interactive {
                retry_image(load).await?
            } else {
                load().await?
            };
            anyhow::ensure!(!bytes.is_empty(), "Empty image data");
            cache
                .lock()
                .map_err(|_| anyhow::anyhow!("Cache poisoned"))?
                .write(&key, &bytes, 7 * 24 * 60 * 60 * 1000)?;
            Ok(bytes)
        })
    }

    pub(crate) fn spawn<F, Fut>(engine: Arc<crate::script::Engine>, work: F) -> Result<Self>
    where
        F: FnOnce(Arc<Request>, String) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<Vec<u8>>> + Send + 'static,
    {
        Self::spawn_managed(engine, move |state, id| {
            let cancel = state.cancellation.clone();
            async move {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => Err(anyhow::anyhow!("Image request cancelled")),
                    result = work(state, id) => result,
                }
            }
        })
    }

    pub(crate) fn spawn_managed<F, Fut>(engine: Arc<crate::script::Engine>, work: F) -> Result<Self>
    where
        F: FnOnce(Arc<Request>, String) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<Vec<u8>>> + Send + 'static,
    {
        let (sender, receiver) = tokio::sync::mpsc::channel(8);
        let state = Arc::new(Request {
            cancellation: Arc::new(HttpCancellation::new()),
            sender,
        });
        let worker = state.clone();
        let id = uuid::Uuid::new_v4().to_string();
        let task_engine = engine.clone();
        let task_id = id.clone();
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_finished = finished.clone();
        registry()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.clone(), Arc::downgrade(&state));
        crate::script::executor().spawn(async move {
            let result = work(worker.clone(), id.clone()).await;
            let progress = match result {
                Ok(bytes) => ImageProgress {
                    current: bytes.len() as u64,
                    total: Some(bytes.len() as u64),
                    bytes: Some(bytes),
                    error: None,
                },
                Err(error) => ImageProgress {
                    current: 0,
                    total: None,
                    bytes: None,
                    error: Some(format!("{error:#}")),
                },
            };
            worker_finished.store(true, std::sync::atomic::Ordering::Relaxed);
            let _ = worker.sender.send(progress).await;
            registry()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
        });
        Ok(Self {
            state,
            engine: task_engine,
            id: task_id,
            finished,
            receiver: tokio::sync::Mutex::new(receiver),
        })
    }
}

pub(crate) fn cache_key(
    image: &str,
    source: Option<&str>,
    comic: &str,
    chapter: &str,
    thumbnail: bool,
) -> String {
    let source = source.unwrap_or("null");
    if !thumbnail {
        format!("{image}@{source}@{comic}@{chapter}")
    } else if comic.is_empty() {
        format!("{image}@{source}")
    } else {
        format!("{image}@{source}@{comic}")
    }
}

fn retryable_image_error(error: &anyhow::Error) -> bool {
    let message = format!("{error:#}").to_ascii_lowercase();
    ![
        "http 403",
        "http 404",
        "invalid status code: 403",
        "invalid status code: 404",
        "handshake",
        "cancelled",
        "cloudflareexception:",
    ]
    .iter()
    .any(|pattern| message.contains(pattern))
}

pub(crate) async fn retry_image<F, Fut>(mut load: F) -> Result<Vec<u8>>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<Vec<u8>>>,
{
    for delay in [2, 4, 8] {
        match load().await {
            Ok(bytes) => return Ok(bytes),
            Err(error) if !retryable_image_error(&error) => return Err(error),
            Err(_) => tokio::time::sleep(Duration::from_secs(delay)).await,
        }
    }
    load().await
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn fetch(
    engine: &crate::script::Engine,
    state: &Request,
    id: &str,
    image: &str,
    source: Option<&str>,
    comic: &str,
    chapter: &str,
    thumbnail: bool,
) -> Result<Vec<u8>> {
    anyhow::ensure!(
        !state.cancellation.is_cancelled(),
        "Image request cancelled"
    );
    let code = format!(
        "__images.fetch({},{},{},{},{},{})",
        json!(image),
        json!(source),
        json!(comic),
        json!(chapter),
        thumbnail,
        json!(id)
    );
    crate::script_crypto::bytes(&evaluate(engine, &code).await?)
}
