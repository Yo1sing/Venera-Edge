use anyhow::Result;
use std::sync::Arc;

#[flutter_rust_bridge::frb(opaque)]
pub struct FollowUpdateService {
    inner: Arc<crate::follow_updates::Service>,
}
impl FollowUpdateService {
    pub fn open(
        runtime: &crate::api::script::ScriptRuntime,
        favorites: &crate::api::favorites::FavoriteStore,
    ) -> Self {
        Self {
            inner: crate::follow_updates::Service::open(
                runtime.inner.clone(),
                favorites.inner.clone(),
            ),
        }
    }
    pub async fn configure(
        &self,
        folder: Option<String>,
        paused: bool,
        traditional: bool,
        source_types_json: String,
    ) -> Result<()> {
        self.inner
            .configure(
                folder,
                paused,
                traditional,
                serde_json::from_str(&source_types_json)?,
            )
            .await
    }
    pub async fn start(
        &self,
        folder: String,
        force: bool,
        keys_json: Option<String>,
    ) -> Result<FollowUpdateTask> {
        let job = self
            .inner
            .start(
                folder,
                force,
                keys_json.map(|v| serde_json::from_str(&v)).transpose()?,
            )
            .await?;
        Ok(FollowUpdateTask {
            receiver: tokio::sync::Mutex::new(job.subscribe()),
            job,
        })
    }
    pub async fn next_event(&self) -> Option<String> {
        self.inner.next_event().await
    }
    pub async fn close(&self) {
        self.inner.close().await;
    }
}

#[flutter_rust_bridge::frb(opaque)]
pub struct FollowUpdateTask {
    job: Arc<crate::follow_updates::Job>,
    receiver: tokio::sync::Mutex<tokio::sync::watch::Receiver<crate::follow_updates::Progress>>,
}
impl Drop for FollowUpdateTask {
    fn drop(&mut self) {
        self.job.cancel();
    }
}
impl FollowUpdateTask {
    #[flutter_rust_bridge::frb(sync)]
    pub fn cancel(&self) {
        self.job.cancel();
    }
    pub async fn wait(&self) {
        self.job.wait().await;
    }
    pub async fn next_snapshot(&self) -> Option<String> {
        let mut receiver = self.receiver.lock().await;
        if !receiver.has_changed().unwrap_or(false) && receiver.borrow().terminal() {
            return None;
        }
        receiver.changed().await.ok()?;
        let value = receiver.borrow_and_update().clone();
        Some(serde_json::to_string(&value).expect("progress JSON"))
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn find_update_time(info_json: String) -> Result<Option<String>> {
    Ok(crate::follow_updates::find_update_time(
        &serde_json::from_str(&info_json)?,
    ))
}
