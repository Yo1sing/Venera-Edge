use crate::{
    api::http::HttpCancellation,
    backup_storage::{Database, OPERATIONS},
    favorites::{Favorite, Favorites},
    image_tasks::evaluate_worker,
    script::Engine,
};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashSet, sync::Arc, time::Duration};
use tokio::sync::{watch, Mutex};

#[derive(Deserialize)]
pub struct Request {
    source: String,
    comic_type: i32,
    page_limit: u32,
    folder: Option<String>,
    remote_folder: Option<String>,
    at_end: bool,
    traditional: bool,
}

#[derive(Serialize)]
struct Progress {
    status: &'static str,
    pages: u32,
    received: usize,
    added: usize,
    error: Option<String>,
}

impl Progress {
    fn publish(&self, sender: &watch::Sender<String>) {
        sender.send_replace(serde_json::to_string(self).expect("import progress JSON"));
    }
}

pub struct Task {
    cancel: Arc<HttpCancellation>,
    events: Mutex<watch::Receiver<String>>,
}

impl Drop for Task {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl Task {
    pub fn start(store: Arc<Database<Favorites>>, runtime: Arc<Engine>, request: Request) -> Self {
        let mut progress = Progress {
            status: "running",
            pages: 0,
            received: 0,
            added: 0,
            error: None,
        };
        let (sender, mut events) = watch::channel(serde_json::to_string(&progress).unwrap());
        events.mark_changed();
        let cancel = Arc::new(HttpCancellation::new());
        let stop = cancel.clone();
        crate::script::executor().spawn(async move {
            let result = run(&store, &runtime, &request, &stop, &sender, &mut progress).await;
            progress.status = match result {
                Err(error) if !stop.is_cancelled() => {
                    progress.error = Some(format!("{error:#}"));
                    "failed"
                }
                _ if stop.is_cancelled() => "cancelled",
                _ => "completed",
            };
            progress.publish(&sender);
        });
        Self {
            cancel,
            events: Mutex::new(events),
        }
    }

    pub fn cancel(&self) {
        self.cancel.cancel();
    }

    pub async fn next(&self) -> Option<String> {
        let mut events = self.events.lock().await;
        events.changed().await.ok()?;
        let value = events.borrow_and_update().clone();
        Some(value)
    }
}

async fn run(
    store: &Database<Favorites>,
    runtime: &Engine,
    request: &Request,
    cancelled: &HttpCancellation,
    sender: &watch::Sender<String>,
    progress: &mut Progress,
) -> Result<()> {
    let source_lock = runtime.source_lock(&request.source);
    let _storage = tokio::select! {
        _ = cancelled.cancelled() => return Ok(()),
        guard = OPERATIONS.read() => guard,
    };
    let _source = tokio::select! {
        _ = cancelled.cancelled() => return Ok(()),
        guard = source_lock.read() => guard,
    };
    let worker = Arc::new(runtime.fork_sources()?);
    let result = import(store, &worker, request, cancelled, sender, progress).await;
    worker.shutdown().await;
    result
}

async fn import(
    store: &Database<Favorites>,
    worker: &Arc<Engine>,
    request: &Request,
    cancelled: &HttpCancellation,
    sender: &watch::Sender<String>,
    progress: &mut Progress,
) -> Result<()> {
    let source = format!("ComicSource.sources[{}]", json!(request.source));
    let capabilities = call(worker, cancelled, format!(
        "(async()=>{{const s={source}; if(!s?.favorites) throw Error('Unsupported source'); await s.init?.(); return {{name:s.name,paged:typeof s.favorites.loadComics==='function',cursor:typeof s.favorites.loadNext==='function',oldToNew:s.favorites.isOldToNewSort===true}};}})()"
    )).await?;
    let paged = capabilities["paged"] == true;
    ensure!(
        paged || capabilities["cursor"] == true,
        "Unsupported source"
    );
    let old_to_new = capabilities["oldToNew"] == true;
    let folder = request
        .folder
        .as_deref()
        .filter(|name| !name.is_empty())
        .or_else(|| capabilities["name"].as_str())
        .context("Missing source name")?;
    let remote = request.remote_folder.as_deref().unwrap_or_default();
    let serial_key = format!("favorite-import:{folder}");
    let _serial = tokio::select! {
        _ = cancelled.cancelled() => return Ok(()),
        guard = crate::http_policy::serial(&serial_key) => guard,
    };
    let mut ids = store.with(|db| {
        db.prepare_network_import(folder, &request.source, remote, request.comic_type)
    })?;
    let mut items = Vec::new();
    let load = collect(
        worker, cancelled, sender, progress, request, &source, paged, old_to_new, &mut ids,
        &mut items,
    )
    .await;
    if !request.at_end && !old_to_new {
        items.reverse();
    }
    progress.added = store.with(|db| {
        let transaction = db.db.unchecked_transaction()?;
        db.require_network_folder(folder, &request.source, remote)?;
        let mut added = 0;
        for item in items {
            added +=
                usize::from(db.add(folder, &item, None, request.at_end, request.traditional)?);
        }
        transaction.commit()?;
        Ok(added)
    })?;
    load
}

#[allow(clippy::too_many_arguments)]
async fn collect(
    worker: &Arc<Engine>,
    cancelled: &HttpCancellation,
    sender: &watch::Sender<String>,
    progress: &mut Progress,
    request: &Request,
    source: &str,
    paged: bool,
    old_to_new: bool,
    ids: &mut HashSet<String>,
    items: &mut Vec<Favorite>,
) -> Result<()> {
    if request.page_limit == 0 {
        return Ok(());
    }
    let folder = json!(request.remote_folder);
    let mut page = 1u64;
    let mut prefetched = None;
    if paged && old_to_new {
        let first = load_page(
            worker,
            cancelled,
            format!("{source}.favorites.loadComics(1,{folder})"),
            request.comic_type,
        )
        .await?;
        page = first
            .max_page
            .unwrap_or(1)
            .saturating_sub(u64::from(request.page_limit) - 1)
            .max(1);
        if page == 1 {
            prefetched = Some(first);
        }
    }
    let mut cursor = Value::Null;
    let mut seen_cursors = HashSet::new();
    while progress.pages < request.page_limit {
        let response = if let Some(first) = prefetched.take() {
            first
        } else {
            let code = if paged {
                format!("{source}.favorites.loadComics({page},{folder})")
            } else {
                format!("{source}.favorites.loadNext({cursor},{folder})")
            };
            load_page(worker, cancelled, code, request.comic_type).await?
        };
        ensure!(!cancelled.is_cancelled(), "Import cancelled");
        let finished = response.comics.is_empty()
            || if paged {
                response.max_page.is_some_and(|last| page >= last)
            } else {
                response.next.is_null()
            };
        progress.pages += 1;
        progress.received += response.comics.len();
        items.extend(
            response
                .comics
                .into_iter()
                .filter(|comic| ids.insert(comic.id.clone())),
        );
        progress.added = items.len();
        progress.publish(sender);
        if finished {
            break;
        }
        if !paged {
            ensure!(
                seen_cursors.insert(response.next.to_string()),
                "Source repeated a favorites cursor"
            );
            cursor = response.next;
        }
        page = page
            .checked_add(1)
            .context("Favorites page index overflow")?;
    }
    Ok(())
}

struct Page {
    comics: Vec<Favorite>,
    max_page: Option<u64>,
    next: Value,
}

async fn load_page(
    worker: &Arc<Engine>,
    cancelled: &HttpCancellation,
    code: String,
    comic_type: i32,
) -> Result<Page> {
    for attempt in 0.. {
        let response = call(worker, cancelled, code.clone())
            .await
            .and_then(|value| parse_page(value, comic_type));
        match response {
            Err(_) if attempt < 2 && !cancelled.is_cancelled() => continue,
            result => return result,
        }
    }
    unreachable!()
}

fn parse_page(mut response: Value, comic_type: i32) -> Result<Page> {
    let rows = response["comics"]
        .as_array()
        .context("Invalid favorites page")?;
    let comics = rows.iter().map(|row| {
        serde_json::from_value(json!({
            "id": row["id"], "name": row["title"], "coverPath": row["cover"],
            "type": comic_type, "tags": row["tags"].as_array().cloned().unwrap_or_default(),
            "author": row["subtitle"].as_str().or_else(|| row["subTitle"].as_str()).unwrap_or_default(),
        })).context("Invalid favorite comic")
    }).collect::<Result<_>>()?;
    Ok(Page {
        comics,
        max_page: response["maxPage"].as_u64(),
        next: response["next"].take(),
    })
}

async fn call(worker: &Arc<Engine>, cancelled: &HttpCancellation, code: String) -> Result<Value> {
    let result = tokio::select! {
        biased;
        _ = cancelled.cancelled() => Err(anyhow::anyhow!("Import cancelled")),
        result = tokio::time::timeout(Duration::from_secs(60), evaluate_worker(worker.clone(), code)) => {
            match result {
                Ok(value) => return value,
                Err(_) => Err(anyhow::anyhow!("Favorites source request timed out")),
            }
        }
    };
    worker.close();
    result
}
