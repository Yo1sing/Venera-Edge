use crate::backup_storage::Database;
use anyhow::Result;
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct StoredCookie {
    pub name: String,
    pub value: String,
    pub domain: Option<String>,
    pub path: Option<String>,
    pub expires_ms: Option<i64>,
    pub secure: bool,
    pub http_only: bool,
    pub max_age: Option<i64>,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct CookieStore {
    pub(crate) inner: Arc<Database<crate::cookies::Cookies>>,
}

// Synchronous methods retain the existing JavaScript cookie API contract.
// Network interceptors can call the same owner from their worker threads.
impl CookieStore {
    #[flutter_rust_bridge::frb(sync)]
    pub fn open(path: String) -> Result<Self> {
        Ok(Self {
            inner: Database::new(path, crate::cookies::Cookies::open)?,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save(&self, url: String, cookies: Vec<StoredCookie>) -> Result<()> {
        self.with(|jar| jar.save(&url, cookies))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save_headers(&self, url: String, headers: Vec<String>) -> Result<()> {
        self.with(|jar| jar.save_headers(&url, headers))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save_headers_at_epoch(
        &self,
        url: String,
        headers: Vec<String>,
        epoch: u64,
    ) -> Result<()> {
        self.with(|jar| {
            if crate::backup_storage::restore_epoch() == epoch {
                jar.save_headers(&url, headers)?;
            }
            Ok(())
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn load(&self, url: String) -> Result<Vec<StoredCookie>> {
        self.with(|jar| jar.load(&url))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn header(&self, url: String) -> Result<String> {
        self.with(|jar| {
            Ok(jar
                .load(&url)?
                .iter()
                .map(|c| format!("{}={}", c.name, c.value))
                .collect::<Vec<_>>()
                .join("; "))
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn delete(&self, url: String, name: Option<String>) -> Result<()> {
        self.with(|jar| jar.delete(&url, name.as_deref()))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear(&self) -> Result<()> {
        self.with(|jar| jar.clear())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn close(&self) -> Result<()> {
        self.inner.close();
        Ok(())
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn with<T>(&self, f: impl FnOnce(&mut crate::cookies::Cookies) -> Result<T>) -> Result<T> {
        self.inner.with(f)
    }
}
