use anyhow::{anyhow, ensure, Context, Result};
use serde_json::json;
use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
    time::{Duration, Instant},
};
use tokio::sync::{oneshot, watch};

use crate::{backup, backup_storage, settings, sync};

pub enum Request {
    Refresh,
    Startup,
    Resume,
    Changed,
    Upload,
    Download,
    Import(String),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Upload,
    Download,
    Import,
}

impl Kind {
    fn status(self) -> &'static str {
        match self {
            Self::Upload => "uploading",
            Self::Download => "downloading",
            Self::Import => "restoring",
        }
    }
}

struct Job {
    kind: Kind,
    http: crate::api::http::HttpOptions,
    path: Option<String>,
    waiters: Vec<oneshot::Sender<Result<(), String>>>,
}

struct Restore {
    id: u64,
    work: Option<(backup::Prepared, backup::LocalState)>,
    from_webdav: bool,
    done: oneshot::Sender<Result<(), String>>,
    operations: Option<tokio::sync::RwLockWriteGuard<'static, ()>>,
    applied: bool,
}

#[derive(Default)]
struct State {
    queued: VecDeque<Job>,
    active: Option<Kind>,
    restore: Option<Restore>,
    next_id: u64,
    enabled: bool,
    last_auto_check: Option<Instant>,
    dirty: u64,
    uploaded: u64,
    revision: Option<u64>,
    error: Option<String>,
}

pub struct Scheduler {
    directory: String,
    cache: String,
    state: Mutex<State>,
    events: watch::Sender<String>,
}

static CONTROLLERS: Mutex<Option<HashMap<PathBuf, Weak<Scheduler>>>> = Mutex::new(None);

impl Scheduler {
    pub fn open(directory: String, cache: String) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&directory)?;
        let key = PathBuf::from(&directory).canonicalize()?;
        let mut controllers = CONTROLLERS.lock().unwrap_or_else(|e| e.into_inner());
        let controllers = controllers.get_or_insert_with(HashMap::new);
        controllers.retain(|_, scheduler| scheduler.strong_count() > 0);
        ensure!(
            !controllers.contains_key(&key),
            "Sync controller already open for this directory"
        );
        let scheduler = Arc::new(Self::new(directory, cache)?);
        controllers.insert(key, Arc::downgrade(&scheduler));
        Ok(scheduler)
    }

    fn new(directory: String, cache: String) -> Result<Self> {
        let scheduler = Self {
            directory,
            cache,
            state: Mutex::new(State::default()),
            events: watch::channel(String::new()).0,
        };
        let enabled = scheduler.enabled()?;
        {
            let mut state = scheduler.state();
            state.enabled = enabled;
            scheduler.publish(&state);
        }
        Ok(scheduler)
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn subscribe(&self) -> watch::Receiver<String> {
        self.events.subscribe()
    }

    pub fn snapshot(&self) -> String {
        self.events.borrow().clone()
    }

    fn enabled(&self) -> Result<bool> {
        let _storage = backup_storage::access();
        let data = settings::load(&self.directory)?;
        Ok(data["implicitData"]["webdavAutoSync"] == true
            && data["settings"]["webdav"]
                .as_array()
                .is_some_and(|config| !config.is_empty()))
    }

    fn publish(&self, state: &State) {
        let snapshot = json!({
            "phase": if state.restore.is_some() { "restoring" } else {
                state.active.map(Kind::status).unwrap_or("idle")
            },
            "pending": state.queued.len(),
            "enabled": state.enabled,
            "revision": state.revision,
            "error": state.error,
            "restore": state.restore.as_ref().map(|r| r.id),
        })
        .to_string();
        self.events.send_if_modified(|current| {
            if *current == snapshot {
                return false;
            }
            *current = snapshot;
            true
        });
    }

    pub async fn submit(
        self: &Arc<Self>,
        request: Request,
        http: crate::api::http::HttpOptions,
    ) -> Result<()> {
        let enabled = self.enabled()?;
        let receiver = {
            let mut state = self.state();
            state.enabled = enabled;
            let now = Instant::now();
            let (kind, path, wait) = match request {
                Request::Changed => {
                    if enabled || state.active.is_some() {
                        state.dirty += 1;
                    }
                    if !enabled {
                        self.publish(&state);
                        return Ok(());
                    }
                    (Kind::Upload, None, false)
                }
                Request::Startup if enabled && state.last_auto_check.is_none() => {
                    state.last_auto_check = Some(now);
                    (Kind::Download, None, false)
                }
                Request::Resume
                    if enabled
                        && state.last_auto_check.is_none_or(|last| {
                            now.duration_since(last) >= Duration::from_secs(600)
                        }) =>
                {
                    state.last_auto_check = Some(now);
                    (Kind::Download, None, false)
                }
                Request::Upload => (Kind::Upload, None, true),
                Request::Download => (Kind::Download, None, true),
                Request::Import(path) => (Kind::Import, Some(path), true),
                _ => {
                    self.publish(&state);
                    return Ok(());
                }
            };
            let (sender, receiver) = if wait {
                let (sender, receiver) = oneshot::channel();
                (Some(sender), Some(receiver))
            } else {
                (None, None)
            };
            // Merge only adjacent requests. A later upload must never share the
            // result of an upload whose snapshot may already be on the wire.
            if let Some(job) = state
                .queued
                .back_mut()
                .filter(|job| kind != Kind::Import && job.kind == kind)
            {
                job.http = http;
                job.waiters.extend(sender);
            } else {
                state.queued.push_back(Job {
                    kind,
                    http,
                    path,
                    waiters: sender.into_iter().collect(),
                });
            }
            if state.active.is_none() {
                state.active = Some(kind);
                let scheduler = self.clone();
                tokio::spawn(async move { scheduler.run().await });
            }
            self.publish(&state);
            receiver
        };
        if let Some(receiver) = receiver {
            receiver
                .await
                .context("Sync worker stopped")?
                .map_err(|e| anyhow!("{e}"))?;
        }
        Ok(())
    }

    async fn run(self: Arc<Self>) {
        loop {
            let (job, dirty_at_start) = {
                let mut state = self.state();
                let Some(job) = state.queued.pop_front() else {
                    state.active = None;
                    self.publish(&state);
                    return;
                };
                state.active = Some(job.kind);
                state.error = None;
                self.publish(&state);
                (job, state.dirty)
            };
            let result = self.execute(&job).await.map_err(|e| format!("{e:#}"));
            let mut state = self.state();
            state.error = result.as_ref().err().cloned();
            if let Ok(Some(revision)) = result.as_ref() {
                state.revision = Some(*revision);
                state.uploaded = dirty_at_start;
            }
            self.publish(&state);
            let completion = result.map(|_| ());
            for waiter in job.waiters {
                let _ = waiter.send(completion.clone());
            }
        }
    }

    async fn execute(&self, job: &Job) -> Result<Option<u64>> {
        let options = sync::Options {
            directory: self.directory.clone(),
            cache: self.cache.clone(),
            http: job.http.clone(),
        };
        if job.waiters.is_empty() && !self.enabled()? {
            return Ok(None);
        }
        if job.kind == Kind::Upload {
            return sync::upload_revision(options).await;
        }
        let directory = self.directory.clone();
        let local =
            tokio::task::spawn_blocking(move || backup::LocalState::capture(&directory)).await??;
        let from_webdav = job.kind == Kind::Download;
        let input = if from_webdav {
            let Some(input) = sync::download(options).await? else {
                return Ok(None);
            };
            input
        } else {
            job.path.clone().context("Missing backup path")?
        };
        let cache = self.cache.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            let result = backup::prepare(
                &input,
                &cache,
                if from_webdav { local.revision() } else { None },
            );
            if from_webdav {
                let _ = std::fs::remove_file(input);
            }
            result.map(|prepared| (prepared, local))
        })
        .await??;
        let (Some(prepared), local) = prepared else {
            return Ok(None);
        };
        let receiver = {
            let mut state = self.state();
            if from_webdav {
                ensure!(
                    state.dirty == state.uploaded,
                    "Local changes have not been uploaded; the remote backup was not applied"
                );
            }
            let (done, receiver) = oneshot::channel();
            state.next_id += 1;
            state.restore = Some(Restore {
                id: state.next_id,
                work: Some((prepared, local)),
                from_webdav,
                done,
                operations: None,
                applied: false,
            });
            self.publish(&state);
            receiver
        };
        receiver
            .await
            .context("Restore was interrupted")?
            .map_err(|e| anyhow!("{e}"))?;
        Ok(None)
    }

    pub async fn apply(&self, id: u64) -> Result<String> {
        // First let in-flight source edits and local library transactions finish.
        let operations = backup_storage::OPERATIONS.write().await;
        let work = {
            let mut state = self.state();
            let dirty = state.dirty != state.uploaded;
            let restore = state
                .restore
                .as_mut()
                .filter(|r| r.id == id)
                .context("Unknown restore")?;
            let work = restore.work.take().context("Restore already applied")?;
            ensure!(
                !restore.from_webdav || !dirty,
                "Local changes have not been uploaded; the remote backup was not applied"
            );
            restore.operations = Some(operations);
            work
        };
        let directory = self.directory.clone();
        let data =
            tokio::task::spawn_blocking(move || work.0.apply_checked(&directory, Some(work.1)))
                .await??;
        if let Some(restore) = self.state().restore.as_mut().filter(|r| r.id == id) {
            restore.applied = true;
        }
        Ok(data)
    }

    pub fn finish(&self, id: u64, error: Option<String>) -> Result<()> {
        let mut state = self.state();
        ensure!(
            state.restore.as_ref().is_some_and(|r| r.id == id),
            "Unknown restore"
        );
        let restore = state.restore.take().unwrap();
        drop(restore.operations);
        let result = match error {
            Some(error) => Err(error),
            None if !restore.applied => Err("Backup was not applied".into()),
            None => Ok(()),
        };
        let _ = restore.done.send(result);
        self.publish(&state);
        Ok(())
    }
}
