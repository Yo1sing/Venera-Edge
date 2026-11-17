use crate::backup_storage::Database;
use anyhow::Result;
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryEntry {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub cover: String,
    pub time_ms: i64,
    pub comic_type: i32,
    pub episode: i32,
    pub page: i32,
    pub read_episodes: Vec<String>,
    pub max_page: Option<i32>,
    pub chapter_group: Option<i32>,
}

pub struct ComicKey {
    pub id: String,
    pub comic_type: i32,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct HistoryStore {
    pub(crate) inner: Arc<Database<crate::history::History>>,
}

impl HistoryStore {
    pub fn open(path: String) -> Result<Self> {
        Ok(Self {
            inner: Database::new(path, crate::history::History::open)?,
        })
    }

    pub fn save(&self, entry: HistoryEntry) -> Result<()> {
        self.with(|db| db.save(&entry))
    }

    pub fn refresh_metadata(
        &self,
        runtime: &crate::api::script::ScriptRuntime,
        sources_json: String,
        key: Option<ComicKey>,
    ) -> Result<HistoryRefreshTask> {
        Ok(HistoryRefreshTask {
            inner: crate::history_refresh::Task::start(
                self.inner.clone(),
                runtime.inner.clone(),
                serde_json::from_str(&sources_json)?,
                key,
            )?,
        })
    }

    // Existing widgets perform synchronous history lookups during build.
    // Keep these compatibility calls small; async APIs are used for writes on reader scroll.
    #[flutter_rust_bridge::frb(sync)]
    pub fn save_sync(&self, entry: HistoryEntry) -> Result<()> {
        self.with(|db| db.save(&entry))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn find(&self, id: String, comic_type: i32) -> Result<Option<HistoryEntry>> {
        self.with(|db| db.find(&id, comic_type))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn list(&self, limit: Option<u32>) -> Result<Vec<HistoryEntry>> {
        self.with(|db| db.list(limit))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn count(&self) -> Result<u32> {
        self.with(|db| db.count())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn delete(&self, keys: Vec<ComicKey>) -> Result<()> {
        self.with(|db| db.delete(keys))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear(&self) -> Result<()> {
        self.with(|db| db.clear())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn image_save(&self, comic_json: String) -> Result<()> {
        self.with(|db| db.image_save(serde_json::from_str(&comic_json)?))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn image_list(&self, keyword: Option<String>) -> Result<String> {
        self.with(|db| Ok(serde_json::to_string(&db.image_list(keyword.as_deref())?)?))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn image_find(&self, id: String, source_key: String) -> Result<Option<String>> {
        self.with(|db| {
            db.image_find(&id, &source_key)?
                .map(|v| serde_json::to_string(&v).map_err(Into::into))
                .transpose()
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn image_count(&self) -> Result<u32> {
        self.with(|db| db.image_count())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn image_has(
        &self,
        id: String,
        source_key: String,
        eid: String,
        page: i32,
        episode: i32,
    ) -> Result<bool> {
        self.with(|db| db.image_has(&id, &source_key, &eid, page, episode))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn image_delete(&self, images_json: String) -> Result<()> {
        self.with(|db| db.image_delete(serde_json::from_str(&images_json)?))
    }

    pub fn image_statistics(&self) -> Result<String> {
        self.with(|db| Ok(serde_json::to_string(&db.image_statistics()?)?))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn close(&self) -> Result<()> {
        self.inner.close();
        Ok(())
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn with<T>(
        &self,
        operation: impl FnOnce(&mut crate::history::History) -> Result<T>,
    ) -> Result<T> {
        self.inner.with(operation)
    }
}

#[derive(Clone)]
pub struct HistoryRefreshProgress {
    pub total: u32,
    pub current: u32,
    pub success: u32,
    pub failed: u32,
    pub skipped: u32,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct HistoryRefreshTask {
    inner: crate::history_refresh::Task,
}

impl HistoryRefreshTask {
    pub async fn next(&self) -> Option<HistoryRefreshProgress> {
        self.inner.next().await
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn cancel(&self) {
        self.inner.cancel();
    }
}
