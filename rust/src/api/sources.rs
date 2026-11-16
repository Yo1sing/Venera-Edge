use crate::api::{http::HttpCancellation, script::ScriptRuntime};
use anyhow::Result;

#[flutter_rust_bridge::frb(opaque)]
pub struct SourceManager {
    inner: crate::sources::Manager,
}
impl SourceManager {
    pub fn open(runtime: &ScriptRuntime) -> Result<Self> {
        Ok(Self {
            inner: crate::sources::Manager::open(runtime.inner.clone())?,
        })
    }
    pub async fn load(&self, cancellation: &HttpCancellation) -> Result<String> {
        self.inner.load(cancellation).await
    }
    #[flutter_rust_bridge::frb(sync)]
    pub fn snapshot(&self) -> Result<String> {
        self.inner.snapshot()
    }
    pub async fn install(
        &self,
        code: Vec<u8>,
        name: String,
        cancellation: &HttpCancellation,
    ) -> Result<String> {
        self.inner
            .install(String::from_utf8(code)?, name, cancellation)
            .await
    }
    pub async fn install_url(
        &self,
        url: String,
        cancellation: &HttpCancellation,
    ) -> Result<String> {
        self.inner.install_url(url, cancellation).await
    }
    pub async fn update(&self, key: String, cancellation: &HttpCancellation) -> Result<String> {
        self.inner.update(key, cancellation).await
    }
    pub async fn save(
        &self,
        key: String,
        code: String,
        cancellation: &HttpCancellation,
    ) -> Result<String> {
        self.inner.save(key, code, cancellation).await
    }
    pub async fn remove(&self, key: String, cancellation: &HttpCancellation) -> Result<()> {
        self.inner.remove(&key, cancellation).await
    }
    pub fn read(&self, key: String) -> Result<String> {
        self.inner.read(&key)
    }
    pub fn begin_edit(&self, key: String) -> Result<String> {
        self.inner.begin_edit(&key)
    }
    pub async fn save_edit(
        &self,
        key: String,
        path: String,
        cancellation: &HttpCancellation,
    ) -> Result<String> {
        self.inner.save_edit(key, path, cancellation).await
    }
    pub fn discard_edit(&self, path: String) -> Result<()> {
        self.inner.discard_edit(&path)
    }
    pub async fn catalog(&self, url: String, cancellation: &HttpCancellation) -> Result<String> {
        self.inner.catalog(url, cancellation).await
    }
    pub async fn check_updates(
        &self,
        url: String,
        cancellation: &HttpCancellation,
    ) -> Result<String> {
        self.inner.check_updates(url, cancellation).await
    }
    #[flutter_rust_bridge::frb(sync)]
    pub fn reconcile_pages(&self, settings_json: String, added: Option<String>) -> Result<String> {
        self.inner
            .reconcile_pages(serde_json::from_str(&settings_json)?, added.as_deref())
    }
}
