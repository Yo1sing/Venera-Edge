use anyhow::Result;

pub fn import_pica_data(
    input: String,
    cache: String,
    directory: String,
    source_types_json: String,
    installed: Vec<String>,
    traditional: bool,
    at_end: bool,
) -> Result<()> {
    let _storage = crate::backup_storage::access();
    crate::legacy_import::import(
        &input,
        &cache,
        &directory,
        serde_json::from_str(&source_types_json)?,
        installed,
        traditional,
        at_end,
    )
}

pub fn export_app_data(directory: String, cache: String, sync: bool) -> Result<String> {
    let _storage = crate::backup_storage::access();
    crate::backup::export(&directory, &cache, sync)
}

#[flutter_rust_bridge::frb(opaque)]
pub struct SyncController {
    inner: std::sync::Arc<crate::sync_scheduler::Scheduler>,
    events: tokio::sync::Mutex<tokio::sync::watch::Receiver<String>>,
}

impl SyncController {
    pub fn open(directory: String, cache: String) -> Result<Self> {
        let inner = crate::sync_scheduler::Scheduler::open(directory, cache)?;
        Ok(Self {
            events: tokio::sync::Mutex::new(inner.subscribe()),
            inner,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn snapshot(&self) -> String {
        self.inner.snapshot()
    }

    pub async fn next_snapshot(&self) -> Result<String> {
        let mut events = self.events.lock().await;
        events.changed().await?;
        let snapshot = events.borrow_and_update().clone();
        Ok(snapshot)
    }

    pub async fn submit(
        &self,
        action: String,
        http_json: String,
        path: Option<String>,
    ) -> Result<()> {
        use crate::sync_scheduler::Request;
        let request = match action.as_str() {
            "refresh" => Request::Refresh,
            "startup" => Request::Startup,
            "resume" => Request::Resume,
            "changed" => Request::Changed,
            "upload" => Request::Upload,
            "download" => Request::Download,
            "import" => {
                Request::Import(path.ok_or_else(|| anyhow::anyhow!("Missing backup path"))?)
            }
            _ => anyhow::bail!("Unknown sync action"),
        };
        self.inner
            .submit(request, serde_json::from_str(&http_json)?)
            .await
    }

    pub async fn apply_restore(&self, id: u64) -> Result<String> {
        self.inner.apply(id).await
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn finish_restore(&self, id: u64, error: Option<String>) -> Result<()> {
        self.inner.finish(id, error)
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn cookie_restore_epoch() -> u64 {
    crate::backup_storage::restore_epoch()
}
