use crate::{
    api::http::HttpCancellation,
    favorites::{Favorite, Favorites},
    script::Engine,
};
use anyhow::{anyhow, ensure, Context, Result};
use futures_util::{stream, StreamExt};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

type Store = Arc<Mutex<Option<Favorites>>>;
const DAY_MS: i64 = 86_400_000;

fn needs_check(last_check: Option<i64>, force: bool, now: i64) -> bool {
    force || last_check.is_none_or(|time| now.saturating_sub(time) >= DAY_MS)
}

#[derive(Clone, Serialize)]
pub struct Progress {
    pub total: usize,
    pub current: usize,
    pub skipped: usize,
    pub errors: usize,
    pub updated: usize,
    pub status: String,
    pub comic: Option<Favorite>,
    pub error_message: Option<String>,
}
impl Progress {
    fn new() -> Self {
        Self {
            total: 0,
            current: 0,
            skipped: 0,
            errors: 0,
            updated: 0,
            status: "running".into(),
            comic: None,
            error_message: None,
        }
    }
    pub fn terminal(&self) -> bool {
        self.status != "running"
    }
}

pub struct Job {
    pub folder: String,
    automatic: bool,
    cancel: HttpCancellation,
    stop_writes: Mutex<bool>,
    workers: Mutex<Vec<Arc<Engine>>>,
    snapshots: tokio::sync::watch::Sender<Progress>,
}
impl Job {
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<Progress> {
        let mut receiver = self.snapshots.subscribe();
        receiver.mark_changed();
        receiver
    }
    pub fn cancel(&self) {
        *self.stop_writes.lock().unwrap_or_else(|e| e.into_inner()) = true;
        for engine in self
            .workers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
        {
            engine.close();
        }
        self.cancel.cancel();
    }
    fn track_worker(&self, engine: Arc<Engine>) {
        let stop = self.stop_writes.lock().unwrap_or_else(|e| e.into_inner());
        if *stop {
            engine.close();
        }
        self.workers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(engine);
    }
    pub async fn wait(&self) {
        let mut receiver = self.snapshots.subscribe();
        while !receiver.borrow_and_update().terminal() {
            if receiver.changed().await.is_err() {
                break;
            }
        }
    }
    fn finished(&self) -> bool {
        self.snapshots.borrow().terminal()
    }
}

#[derive(Clone, Default)]
struct Config {
    folder: Option<String>,
    paused: bool,
    traditional: bool,
    sources: HashMap<i32, String>,
}
#[derive(Clone)]
struct Policy {
    retry_delay: Duration,
    throttle: Duration,
    attempt_timeout: Duration,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            retry_delay: Duration::from_secs(2),
            throttle: Duration::from_secs(2),
            attempt_timeout: Duration::from_secs(60),
        }
    }
}

pub struct Service {
    runtime: Arc<Engine>,
    store: Store,
    config: Mutex<Config>,
    active: Mutex<Option<Arc<Job>>>,
    gate: tokio::sync::Mutex<()>,
    shutdown: HttpCancellation,
    closed: AtomicBool,
    events: tokio::sync::mpsc::UnboundedSender<String>,
    receiver: tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<String>>,
    policy: Policy,
}
impl Drop for Service {
    fn drop(&mut self) {
        self.shutdown.cancel();
        if let Ok(active) = self.active.lock() {
            if let Some(job) = active.as_ref() {
                job.cancel();
            }
        }
    }
}
impl Service {
    pub fn open(runtime: Arc<Engine>, store: Store) -> Arc<Self> {
        Self::open_with_policy(runtime, store, Policy::default())
    }
    fn open_with_policy(runtime: Arc<Engine>, store: Store, policy: Policy) -> Arc<Self> {
        let (events, receiver) = tokio::sync::mpsc::unbounded_channel();
        let service = Arc::new(Self {
            runtime,
            store,
            config: Mutex::new(Config::default()),
            active: Mutex::new(None),
            gate: tokio::sync::Mutex::new(()),
            shutdown: HttpCancellation::new(),
            closed: AtomicBool::new(false),
            events,
            receiver: tokio::sync::Mutex::new(receiver),
            policy,
        });
        let weak = Arc::downgrade(&service);
        crate::script::executor().spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(600)).await;
                let Some(service) = weak.upgrade() else {
                    break;
                };
                if service.closed.load(Ordering::Relaxed) {
                    break;
                }
                let _ = service.start_automatic().await;
            }
        });
        service
    }
    pub async fn next_event(&self) -> Option<String> {
        let mut receiver = self.receiver.lock().await;
        tokio::select! {
            biased;
            _=self.shutdown.cancelled()=>None,
            result=receiver.recv()=>result
        }
    }
    fn with_store<T>(&self, f: impl FnOnce(&Favorites) -> Result<T>) -> Result<T> {
        let store = self
            .store
            .lock()
            .map_err(|_| anyhow!("Favorites poisoned"))?;
        f(store.as_ref().context("Favorites store closed")?)
    }
    pub async fn configure(
        self: &Arc<Self>,
        folder: Option<String>,
        paused: bool,
        traditional: bool,
        sources: HashMap<i32, String>,
    ) -> Result<()> {
        let changed = {
            let _gate = self.gate.lock().await;
            ensure!(
                !self.closed.load(Ordering::Relaxed),
                "Update service closed"
            );
            let old = self
                .config
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if paused || old.folder != folder || old.sources != sources {
                self.stop_active().await;
            }
            let changed = old.folder != folder || old.paused != paused || old.sources != sources;
            *self.config.lock().unwrap_or_else(|e| e.into_inner()) = Config {
                folder,
                paused,
                traditional,
                sources,
            };
            changed
        };
        if changed {
            self.start_automatic().await?;
        }
        Ok(())
    }
    async fn stop_active(&self) {
        let active = self
            .active
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if let Some(job) = active {
            job.cancel();
            job.wait().await;
        }
    }
    pub async fn close(&self) {
        let _gate = self.gate.lock().await;
        self.config.lock().unwrap_or_else(|e| e.into_inner()).paused = true;
        self.closed.store(true, Ordering::Relaxed);
        self.shutdown.cancel();
        self.stop_active().await;
    }
    async fn start_automatic(self: &Arc<Self>) -> Result<()> {
        let _gate = self.gate.lock().await;
        let config = self
            .config
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if config.paused || self.closed.load(Ordering::Relaxed) {
            return Ok(());
        }
        let Some(folder) = config.folder.clone() else {
            return Ok(());
        };
        if self
            .active
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|j| !j.finished())
        {
            return Ok(());
        }
        self.launch(folder, false, None, true, config)?;
        Ok(())
    }
    pub async fn start(
        self: &Arc<Self>,
        folder: String,
        force: bool,
        keys: Option<Vec<crate::favorites::Key>>,
    ) -> Result<Arc<Job>> {
        let _gate = self.gate.lock().await;
        ensure!(
            !self.closed.load(Ordering::Relaxed),
            "Update service closed"
        );
        let config = self
            .config
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        ensure!(
            !config.paused,
            "Update checking is paused during data restore"
        );
        let previous = self
            .active
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        if let Some(job) = previous {
            ensure!(
                job.finished() || job.automatic,
                "An update check is already running"
            );
            job.cancel();
            job.wait().await;
        }
        self.launch(folder, force, keys, false, config)
    }
    fn publish(&self, job: &Job, progress: &Progress) {
        job.snapshots.send_replace(progress.clone());
        if progress.terminal() || progress.error_message.is_some() {
            let _ = self
                .events
                .send(serde_json::to_string(progress).expect("progress JSON"));
        }
    }
    fn launch(
        self: &Arc<Self>,
        folder: String,
        force: bool,
        keys: Option<Vec<crate::favorites::Key>>,
        automatic: bool,
        config: Config,
    ) -> Result<Arc<Job>> {
        let comics = self.with_store(|db| db.list(Some(&folder), None, false))?;
        let comics: Vec<_> = comics
            .into_iter()
            .filter(|c| {
                keys.as_ref().is_none_or(|keys| {
                    keys.iter()
                        .any(|k| k.id == c.id && k.comic_type == c.comic_type)
                })
            })
            .collect();
        let mut progress = Progress::new();
        progress.total = comics.len();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let pending: Vec<_> = comics
            .into_iter()
            .filter(|c| needs_check(c.last_check_time, force, now))
            .collect();
        progress.skipped = progress.total - pending.len();
        progress.current = progress.skipped;
        let job = Arc::new(Job {
            folder,
            automatic,
            cancel: HttpCancellation::new(),
            stop_writes: Mutex::new(false),
            workers: Mutex::new(Vec::new()),
            snapshots: tokio::sync::watch::channel(progress.clone()).0,
        });
        *self.active.lock().unwrap_or_else(|e| e.into_inner()) = Some(job.clone());
        self.publish(&job, &progress);
        let service = self.clone();
        let worker = job.clone();
        crate::script::executor().spawn(async move {
            let result = service.run(&worker, pending, &config, &mut progress).await;
            if let Err(error) = result {
                progress.status = "failed".into();
                progress.error_message = Some(format!("{error:#}"));
            }
            service.publish(&worker, &progress);
        });
        Ok(job)
    }
    async fn run(
        &self,
        job: &Job,
        pending: Vec<Favorite>,
        config: &Config,
        progress: &mut Progress,
    ) -> Result<()> {
        if pending.is_empty() {
            progress.status = "completed".into();
            return Ok(());
        }
        let work = async {
            let limiter = tokio::sync::Mutex::new(tokio::time::Instant::now());
            let mut results = stream::iter(pending)
                .map(|comic| self.check(job, &config.sources, comic, &limiter))
                .buffer_unordered(5);
            while let Some((mut comic, result)) = results.next().await {
                let stop = job.stop_writes.lock().unwrap_or_else(|e| e.into_inner());
                if *stop {
                    progress.status = "cancelled".into();
                    return Ok(());
                }
                progress.current += 1;
                progress.error_message = None;
                match result.and_then(|info| {
                    let time = find_update_time(&info);
                    apply_info(&mut comic, &info)?;
                    let updated = self.with_store(|db| {
                        db.apply_follow(&job.folder, &comic, time.as_deref(), config.traditional)
                    })?;
                    comic.last_update_time = time.or(comic.last_update_time.clone());
                    Ok(updated)
                }) {
                    Ok(updated) => progress.updated += usize::from(updated),
                    Err(error) => {
                        progress.errors += 1;
                        progress.error_message = Some(format!("{error:#}"));
                    }
                }
                progress.comic = Some(comic);
                self.publish(job, progress);
            }
            Ok::<_, anyhow::Error>(())
        };
        let result = tokio::select! {
            biased;
            _=job.cancel.cancelled()=>{progress.status="cancelled".into();Ok(())},
            _=self.shutdown.cancelled()=>{progress.status="cancelled".into();Ok(())},
            result=work=>{if progress.status=="running" {progress.status="completed".into();}result}
        };
        // Dropping the buffered futures cannot leave their JS promises or HTTP
        // host tasks running. Await every worker before publishing the terminal
        // snapshot, including workers interrupted during their own shutdown.
        let remaining = std::mem::take(&mut *job.workers.lock().unwrap_or_else(|e| e.into_inner()));
        for engine in remaining {
            engine.shutdown().await;
        }
        result
    }
    async fn check(
        &self,
        job: &Job,
        sources: &HashMap<i32, String>,
        comic: Favorite,
        limiter: &tokio::sync::Mutex<tokio::time::Instant>,
    ) -> (Favorite, Result<Value>) {
        let result = async {
            let source = sources
                .get(&comic.comic_type)
                .context("Comic source not found")?;
            let code = format!(
                "(async()=>{{const source=ComicSource.sources[{}];if(!source) throw Error('Comic source not found');await source.init?.();return source.comic.loadInfo({});}})()",
                serde_json::to_string(source)?,
                serde_json::to_string(&comic.id)?
            );
            let mut last = None;
            for attempt in 0..3 {
                if attempt > 0 {
                    tokio::time::sleep(self.policy.retry_delay).await;
                }
                // Pace actual loadInfo attempts, including retries, globally for
                // this folder. Five futures may be in flight at once.
                {
                    let mut next = limiter.lock().await;
                    tokio::time::sleep_until(*next).await;
                    *next = tokio::time::Instant::now() + self.policy.throttle;
                }
                let engine=Arc::new(self.runtime.fork_sources()?);
                job.track_worker(engine.clone());
                let result=tokio::time::timeout(self.policy.attempt_timeout,crate::image_tasks::evaluate(&engine,&code)).await;
                engine.shutdown().await;
                job.workers.lock().unwrap_or_else(|e|e.into_inner()).retain(|worker|!Arc::ptr_eq(worker,&engine));
                match result {
                    Ok(Ok(info)) => {
                        // Validate before writing, so malformed responses use the
                        // same bounded retry policy as source exceptions.
                        match apply_info(&mut comic.clone(), &info) {
                            Ok(()) => return Ok(info),
                            Err(error) => last = Some(error),
                        }
                    }
                    Ok(Err(error)) => last = Some(error),
                    Err(_) => last=Some(anyhow!("Comic source request timed out")),
                }
            }
            Err(last.unwrap_or_else(|| anyhow!("Update check failed")))
        }
        .await;
        (comic, result)
    }
}

pub fn normalize_time(time: &str) -> Option<String> {
    let segments: Vec<_> = time.split(' ').next()?.split('-').collect();
    if segments.len() != 3 {
        return None;
    }
    let y: i32 = segments[0].trim().parse().ok()?;
    let m: i32 = segments[1].trim().parse().ok()?;
    let d: i32 = segments[2].trim().parse().ok()?;
    if !(2000..=3000).contains(&y) || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(format!("{y}-{m}-{d}"))
}
pub fn find_update_time(info: &Value) -> Option<String> {
    if let Some(time) = info["updateTime"].as_str() {
        return normalize_time(time);
    }
    for (namespace, tags) in info["tags"].as_object()? {
        if ["更新", "最後更新", "最后更新", "update", "last update"]
            .contains(&namespace.to_lowercase().as_str())
        {
            if let Some(value) = tags
                .as_array()
                .and_then(|v| v.first())
                .and_then(Value::as_str)
            {
                return normalize_time(value);
            }
        }
    }
    None
}
fn apply_info(comic: &mut Favorite, info: &Value) -> Result<()> {
    comic.name = info["title"]
        .as_str()
        .context("Invalid comic title")?
        .into();
    comic.cover = info["cover"]
        .as_str()
        .context("Invalid comic cover")?
        .into();
    let tags = info["tags"].as_object().context("Invalid comic tags")?;
    if let Some(author) = info["subtitle"].as_str().or_else(|| {
        tags.get("author")
            .and_then(|v| v.as_array())
            .and_then(|v| v.first())
            .and_then(Value::as_str)
    }) {
        comic.author = author.into();
    }
    comic.tags.clear();
    for (namespace, values) in tags {
        let Some(values) = values.as_array() else {
            continue;
        };
        for value in values {
            let value = value.as_str().context("Invalid comic tag")?;
            if !["author", "artist", "time"].contains(&namespace.to_lowercase().as_str()) {
                comic.tags.push(format!("{namespace}:{value}"));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const SOURCE: &str = r#"
class UpdateTest extends ComicSource {
    name='Updates'; key='updates'; version='1.0.0';
    comic={loadInfo:async(id)=>{
        const s=ComicSource.sources.updates;
        const attempt=(s.loadData('attempt_'+id)??0)+1;
        s.saveData('attempt_'+id,attempt);
        if(id==='bad'||(id==='retry'&&attempt<3)) throw Error('temporary failure');
        if(id==='hang') await new Promise(()=>{});
        if(id==='busy') {while(true) {}}
        if(id==='slow') {
            await new Promise(resolve=>setTimeout(resolve,200));
            s.saveData('late',true);
        }
        return {title:'New '+id,cover:'new-cover',tags:{author:['Author'],Artist:['Artist'],time:['ignored'],genre:['action'],'最后更新':['2026-11-16 12:00:00']}};
    }};
}
"#;

    struct Fixture {
        directory: tempfile::TempDir,
        service: Arc<Service>,
    }
    impl Fixture {
        async fn open(ids: &[&str]) -> Result<Self> {
            let directory = tempfile::tempdir()?;
            let options = serde_json::from_value(json!({
                "data_path":directory.path(),"version":"1.6.3","locale":"zh_CN","platform":"test","user_agent":"test",
                "http":{"proxy":null,"dns_overrides":{},"tls_sni":true,"verify_certificates":true,"connect_timeout_ms":1000,"receive_timeout_ms":1000,"max_redirects":5}
            }))?;
            let engine = Arc::new(Engine::open(options)?);
            engine.evaluate(&format!("__sources.install({})", json!(SOURCE)))?;
            let db = Favorites::open(":memory:", false)?;
            db.create("Follow", false)?;
            for id in ids {
                let comic = serde_json::from_value(
                    json!({"id":id,"name":"Old","author":"Old author","type":42,"coverPath":"old-cover","tags":[]}),
                )?;
                db.add("Follow", &comic, None, true, false)?;
            }
            let service = Service::open_with_policy(
                engine,
                Arc::new(Mutex::new(Some(db))),
                Policy {
                    retry_delay: Duration::from_millis(20),
                    throttle: Duration::from_millis(1),
                    attempt_timeout: Duration::from_secs(3),
                },
            );
            service
                .configure(None, false, false, HashMap::from([(42, "updates".into())]))
                .await?;
            Ok(Self { directory, service })
        }
        fn data(&self) -> Value {
            let mut data =
                crate::script::source_data(self.directory.path().to_str().unwrap(), "updates")
                    .unwrap();
            // Each independent worker updates its own key. A read/modify/write
            // of one shared attempts map would lose counters across workers.
            let attempts: serde_json::Map<String, Value> = data
                .as_object()
                .unwrap()
                .iter()
                .filter_map(|(key, value)| {
                    key.strip_prefix("attempt_")
                        .map(|id| (id.to_owned(), value.clone()))
                })
                .collect();
            if !attempts.is_empty() {
                data["attempts"] = attempts.into();
            }
            data
        }
        async fn started(&self, id: &str) -> Result<()> {
            tokio::time::timeout(Duration::from_secs(3), async {
                while self.data()["attempts"][id].is_null() {
                    tokio::time::sleep(Duration::from_millis(2)).await;
                }
            })
            .await?;
            Ok(())
        }
        fn comics(&self) -> Vec<Favorite> {
            self.service
                .with_store(|db| db.list(Some("Follow"), None, false))
                .unwrap()
        }
    }
    async fn finished(job: &Job) -> Progress {
        tokio::time::timeout(Duration::from_secs(5), job.wait())
            .await
            .unwrap();
        job.snapshots.borrow().clone()
    }
    #[test]
    fn dates_and_tag_rules_match_existing_sources() {
        assert!(!needs_check(Some(DAY_MS), false, DAY_MS * 2 - 1));
        assert!(needs_check(Some(DAY_MS), false, DAY_MS * 2));
        assert!(!needs_check(Some(DAY_MS * 3), false, DAY_MS * 2));
        assert!(needs_check(Some(DAY_MS * 3), true, DAY_MS * 2));
        assert_eq!(
            normalize_time("2026-01-02 10:00:00"),
            Some("2026-1-2".into())
        );
        for value in ["1999-1-1", "3001-1-1", "2026-13-1", "2026-1-32", "2026/1/1"] {
            assert_eq!(normalize_time(value), None);
        }
        // An explicit but invalid date does not fall back to tags in the old API.
        assert_eq!(
            find_update_time(&json!({"updateTime":"invalid","tags":{"update":["2026-1-1"]}})),
            None
        );
        assert_eq!(
            find_update_time(&json!({"tags":{"LAST UPDATE":["2026-01-02"]}})),
            Some("2026-1-2".into())
        );
    }
    #[tokio::test]
    async fn folder_check_retries_partial_failures_and_skips_recent_successes() -> Result<()> {
        let f = Fixture::open(&["ok", "retry", "bad"]).await?;
        let job = f.service.start("Follow".into(), true, None).await?;
        let p = finished(&job).await;
        assert_eq!(
            (p.total, p.current, p.updated, p.errors),
            (3, 3, 2, 1),
            "progress={} data={}",
            serde_json::to_string(&p)?,
            f.data()
        );
        assert_eq!(p.status, "completed");
        assert_eq!(f.data()["attempts"], json!({"ok":1,"retry":3,"bad":3}));
        let rows = f.comics();
        let ok = rows.iter().find(|c| c.id == "ok").unwrap();
        assert_eq!(ok.author, "Author");
        assert_eq!(
            ok.tags,
            vec!["genre:action", "最后更新:2026-11-16 12:00:00"]
        );
        assert_eq!(ok.last_update_time.as_deref(), Some("2026-11-16"));
        assert!(ok.has_new_update);
        let bad = rows.iter().find(|c| c.id == "bad").unwrap();
        assert_eq!(bad.name, "Old");
        assert!(bad.last_check_time.is_none());
        let job = f.service.start("Follow".into(), false, None).await?;
        let p = finished(&job).await;
        assert_eq!((p.total, p.current, p.skipped, p.errors), (3, 3, 2, 1));
        assert_eq!(f.data()["attempts"]["ok"], 1);
        assert_eq!(f.data()["attempts"]["bad"], 6);
        f.service.close().await;
        Ok(())
    }
    #[tokio::test]
    async fn empty_and_all_recent_folders_finish_without_source_calls() -> Result<()> {
        let f = Fixture::open(&[]).await?;
        let job = f.service.start("Follow".into(), false, None).await?;
        let p = finished(&job).await;
        assert_eq!((p.total, p.current, p.errors), (0, 0, 0));
        assert_eq!(p.status, "completed");
        assert!(f.data()["attempts"].is_null());
        f.service.close().await;
        let f = Fixture::open(&["ok"]).await?;
        f.service
            .with_store(|db| db.update_check("Follow", "ok", 42, None))?;
        let job = f.service.start("Follow".into(), false, None).await?;
        let p = finished(&job).await;
        assert_eq!((p.total, p.current, p.skipped), (1, 1, 1));
        assert!(f.data()["attempts"].is_null());
        f.service.close().await;
        Ok(())
    }
    #[tokio::test]
    async fn cancellation_stops_js_and_writes_before_immediate_restart() -> Result<()> {
        let f = Fixture::open(&["slow", "ok"]).await?;
        let keys = Some(vec![crate::favorites::Key {
            id: "slow".into(),
            comic_type: 42,
        }]);
        let job = f.service.start("Follow".into(), true, keys).await?;
        f.started("slow").await?;
        assert!(f.service.start("Follow".into(), true, None).await.is_err());
        job.cancel();
        assert_eq!(finished(&job).await.status, "cancelled");
        let job = f
            .service
            .start(
                "Follow".into(),
                true,
                Some(vec![crate::favorites::Key {
                    id: "ok".into(),
                    comic_type: 42,
                }]),
            )
            .await?;
        assert_eq!(finished(&job).await.updated, 1);
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(f.data()["late"].is_null());
        assert!(f
            .comics()
            .iter()
            .find(|c| c.id == "slow")
            .unwrap()
            .last_check_time
            .is_none());
        f.service.close().await;
        Ok(())
    }
    #[tokio::test]
    async fn cancelled_retry_wait_does_not_issue_another_attempt() -> Result<()> {
        let f = Fixture::open(&["bad"]).await?;
        let job = f.service.start("Follow".into(), true, None).await?;
        f.started("bad").await?;
        job.cancel();
        assert_eq!(finished(&job).await.status, "cancelled");
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert_eq!(f.data()["attempts"]["bad"], 1);
        f.service.close().await;
        Ok(())
    }
    #[tokio::test]
    async fn cancellation_interrupts_a_source_that_does_not_yield() -> Result<()> {
        let f = Fixture::open(&["busy"]).await?;
        let job = f.service.start("Follow".into(), true, None).await?;
        f.started("busy").await?;
        job.cancel();
        tokio::time::timeout(Duration::from_secs(2), job.wait()).await?;
        assert_eq!(job.snapshots.borrow().status, "cancelled");
        assert!(f.comics()[0].last_check_time.is_none());
        f.service.close().await;
        Ok(())
    }
    #[tokio::test]
    async fn unchanged_date_preserves_a_concurrent_mark_as_read() -> Result<()> {
        let f = Fixture::open(&["slow"]).await?;
        f.service
            .with_store(|db| db.update_check("Follow", "slow", 42, Some("2026-11-16")))?;
        let job = f.service.start("Follow".into(), true, None).await?;
        f.started("slow").await?;
        f.service
            .with_store(|db| db.on_read("slow", 42, "start", Some("Follow")))?;
        assert_eq!(finished(&job).await.updated, 0);
        assert!(!f.comics()[0].has_new_update);
        f.service.close().await;
        Ok(())
    }
    #[tokio::test]
    async fn configuration_pauses_active_tasks_and_does_not_repeat_on_ui_notifications(
    ) -> Result<()> {
        let f = Fixture::open(&["slow"]).await?;
        let sources = HashMap::from([(42, "updates".into())]);
        f.service
            .configure(Some("Follow".into()), false, false, sources.clone())
            .await?;
        f.started("slow").await?;
        let job = f.service.active.lock().unwrap().clone().unwrap();
        f.service
            .configure(Some("Follow".into()), true, false, sources.clone())
            .await?;
        assert_eq!(finished(&job).await.status, "cancelled");
        assert!(f.service.start("Follow".into(), true, None).await.is_err());
        f.service
            .configure(Some("Follow".into()), false, false, sources.clone())
            .await?;
        let job = f.service.active.lock().unwrap().clone().unwrap();
        finished(&job).await;
        f.service
            .configure(Some("Follow".into()), false, false, sources)
            .await?;
        assert!(Arc::ptr_eq(
            &job,
            f.service.active.lock().unwrap().as_ref().unwrap()
        ));
        f.service.close().await;
        assert!(f.service.next_event().await.is_none());
        Ok(())
    }

    #[tokio::test]
    async fn missing_sources_and_deleted_folders_do_not_recreate_favorites() -> Result<()> {
        let f = Fixture::open(&["ok"]).await?;
        f.service
            .configure(None, false, false, HashMap::new())
            .await?;
        let job = f.service.start("Follow".into(), true, None).await?;
        assert_eq!(finished(&job).await.errors, 1);
        assert!(f.data()["attempts"].is_null());
        assert!(f.comics()[0].last_check_time.is_none());
        f.service.close().await;
        let f = Fixture::open(&["slow"]).await?;
        let job = f.service.start("Follow".into(), true, None).await?;
        f.started("slow").await?;
        f.service.with_store(|db| db.delete_folder("Follow"))?;
        assert_eq!(finished(&job).await.errors, 1);
        assert!(f.service.with_store(|db| db.folders())?.is_empty());
        f.service.close().await;
        Ok(())
    }

    #[tokio::test]
    async fn timeouts_retry_in_isolated_workers_without_failing_other_comics() -> Result<()> {
        let f = Fixture::open(&["hang", "ok"]).await?;
        let service = Service::open_with_policy(
            f.service.runtime.clone(),
            f.service.store.clone(),
            Policy {
                attempt_timeout: Duration::from_millis(60),
                retry_delay: Duration::from_millis(1),
                throttle: Duration::from_millis(1),
            },
        );
        service
            .configure(None, false, false, HashMap::from([(42, "updates".into())]))
            .await?;
        let job = service.start("Follow".into(), true, None).await?;
        let p = finished(&job).await;
        assert_eq!((p.errors, p.updated), (1, 1));
        assert_eq!(f.data()["attempts"]["hang"], 3);
        service.close().await;
        f.service.close().await;
        Ok(())
    }

    #[tokio::test]
    async fn at_most_five_source_requests_run_concurrently() -> Result<()> {
        let f = Fixture::open(&["1", "2", "3", "4", "5", "6"]).await?;
        f.service
            .runtime
            .evaluate("delete ComicSource.sources.updates")?;
        f.service.runtime.evaluate(&format!(
            "__sources.install({})",
            json!(
                r#"
class Blocking extends ComicSource {
    name='Blocking';key='updates';version='1.0.0';
    comic={loadInfo:async()=>({title:await getClipboard(),cover:'cover',tags:{}})};
}
"#
            )
        ))?;
        let job = f.service.start("Follow".into(), true, None).await?;
        let mut events = f.service.runtime.events.lock().await;
        let mut tickets = vec![];
        for _ in 0..5 {
            let event: Value = serde_json::from_str(
                &tokio::time::timeout(Duration::from_secs(3), events.recv())
                    .await?
                    .unwrap(),
            )?;
            tickets.push(event["ticket"].as_u64().unwrap());
        }
        assert!(
            tokio::time::timeout(Duration::from_millis(30), events.recv())
                .await
                .is_err()
        );
        f.service
            .runtime
            .settle(tickets.pop().unwrap(), json!("Title"), None)?;
        let event: Value = serde_json::from_str(
            &tokio::time::timeout(Duration::from_secs(3), events.recv())
                .await?
                .unwrap(),
        )?;
        tickets.push(event["ticket"].as_u64().unwrap());
        for ticket in tickets {
            f.service.runtime.settle(ticket, json!("Title"), None)?;
        }
        assert_eq!(finished(&job).await.errors, 0);
        f.service.close().await;
        Ok(())
    }
}
