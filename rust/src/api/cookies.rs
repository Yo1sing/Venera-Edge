use anyhow::{anyhow, Result};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock, Weak},
};

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
    path: PathBuf,
    inner: Arc<Mutex<State>>,
}

struct State {
    jar: Option<crate::cookies::Cookies>,
    generation: i64,
}

fn next_generation() -> i64 {
    use std::sync::atomic::{AtomicI64, Ordering};
    static GENERATION: AtomicI64 = AtomicI64::new(1);
    GENERATION.fetch_add(1, Ordering::Relaxed)
}

impl CookieStore {
    #[flutter_rust_bridge::frb(sync)]
    pub fn open(path: String) -> Result<Self> {
        // The Dart owner keeps the state alive while requests and script workers borrow it.
        static STORES: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<State>>>>> = OnceLock::new();
        let path: PathBuf = std::path::Path::new(&path).components().collect();
        let mut stores = STORES
            .get_or_init(Default::default)
            .lock()
            .map_err(|_| anyhow!("cookie registry lock poisoned"))?;
        stores.retain(|_, weak| weak.strong_count() > 0);
        let inner = if let Some(state) = stores.get(&path).and_then(Weak::upgrade) {
            state
        } else {
            let state = Arc::new(Mutex::new(State {
                jar: Some(crate::cookies::Cookies::open(&path.to_string_lossy())?),
                generation: next_generation(),
            }));
            stores.insert(path.clone(), Arc::downgrade(&state));
            state
        };
        Ok(Self { path, inner })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save(&self, url: String, cookies: Vec<StoredCookie>) -> Result<()> {
        self.mutate(|jar| jar.save(&url, cookies))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save_webview(
        &self,
        url: String,
        cookies: Vec<StoredCookie>,
        user_agent: Option<String>,
        generation: i64,
    ) -> Result<bool> {
        if let Some(agent) = &user_agent {
            reqwest::header::HeaderValue::from_str(agent)?;
        }
        let mut state = self.lock()?;
        if state.generation != generation {
            return Ok(false);
        }
        state
            .jar
            .as_mut()
            .ok_or_else(|| anyhow!("Cookie access is paused"))?
            .save_webview(&url, cookies, user_agent.as_deref())?;
        state.generation = next_generation();
        Ok(true)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn save_headers(&self, url: String, headers: Vec<String>) -> Result<()> {
        self.mutate(|jar| jar.save_headers(&url, headers, None))
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
        self.mutate(|jar| jar.delete(&url, name.as_deref()))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn clear(&self) -> Result<()> {
        self.mutate(|jar| jar.clear())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn close(&self) -> Result<()> {
        let mut state = self.lock()?;
        state.jar.take();
        state.generation = next_generation();
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn reopen(&self) -> Result<()> {
        let mut state = self.lock()?;
        if state.jar.is_none() {
            state.jar = Some(crate::cookies::Cookies::open(&self.path.to_string_lossy())?);
            state.generation = next_generation();
        }
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn generation(&self) -> Result<i64> {
        let state = self.lock()?;
        anyhow::ensure!(state.jar.is_some(), "Cookie access is paused");
        Ok(state.generation)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn complete_cloudflare(
        &self,
        url: String,
        cookies: Vec<StoredCookie>,
        user_agent: String,
        generation: i64,
    ) -> Result<bool> {
        anyhow::ensure!(!user_agent.is_empty(), "Missing WebView User-Agent");
        reqwest::header::HeaderValue::from_str(&user_agent)?;
        let mut state = self.lock()?;
        if state.generation != generation {
            return Ok(false);
        }
        let jar = state
            .jar
            .as_mut()
            .ok_or_else(|| anyhow!("Cookie access is paused"))?;
        if !jar.save_verification(&url, cookies, &user_agent)? {
            return Ok(false);
        }
        state.generation = next_generation();
        Ok(true)
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) fn request_cookies(
        &self,
        url: &str,
        generation: i64,
    ) -> Result<Vec<(StoredCookie, Option<String>)>> {
        let mut state = self.lock()?;
        anyhow::ensure!(state.generation == generation, "Cookie session changed");
        state
            .jar
            .as_mut()
            .ok_or_else(|| anyhow!("Cookie access is paused"))?
            .load_with_agents(url)
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) fn save_response(
        &self,
        url: &str,
        headers: Vec<String>,
        user_agent: Option<&str>,
        generation: i64,
    ) -> Result<()> {
        let mut state = self.lock()?;
        // A response from before a clear, account update or restore cannot repopulate the jar.
        if state.generation == generation && !headers.is_empty() {
            if let Some(jar) = state.jar.as_mut() {
                jar.save_headers(url, headers, user_agent)?;
            }
        }
        Ok(())
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, State>> {
        self.inner
            .lock()
            .map_err(|_| anyhow!("cookie lock poisoned"))
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn mutate(&self, f: impl FnOnce(&mut crate::cookies::Cookies) -> Result<()>) -> Result<()> {
        let mut state = self.lock()?;
        f(state
            .jar
            .as_mut()
            .ok_or_else(|| anyhow!("Cookie access is paused"))?)?;
        state.generation = next_generation();
        Ok(())
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn with<T>(&self, f: impl FnOnce(&mut crate::cookies::Cookies) -> Result<T>) -> Result<T> {
        let mut guard = self.lock()?;
        f(guard
            .jar
            .as_mut()
            .ok_or_else(|| anyhow!("Cookie access is paused"))?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        api::http::{HttpHeader, SourceHttpOptions},
        http_policy::{header, Session},
    };

    fn platform_cookie(name: &str, value: &str, domain: &str, path: &str) -> StoredCookie {
        StoredCookie {
            name: name.into(),
            value: value.into(),
            domain: Some(domain.into()),
            path: Some(path.into()),
            expires_ms: None,
            secure: true,
            http_only: true,
            max_age: None,
        }
    }

    #[test]
    fn verification_pairs_the_ua_with_the_scoped_cookie_and_migrates_the_legacy_store() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("cookie.db").to_string_lossy().into_owned();
        let old_db = rusqlite::Connection::open(&path)?;
        old_db.execute_batch(
            "CREATE TABLE cookies (name TEXT NOT NULL, value TEXT NOT NULL, domain TEXT NOT NULL,
             path TEXT, expires INTEGER, secure INTEGER, httpOnly INTEGER, PRIMARY KEY(name,domain,path));
             INSERT INTO cookies VALUES ('cf_clearance','old','legacy.example','/',NULL,1,1);
             INSERT INTO cookies VALUES ('inherited','old','.co.uk','/',NULL,1,1);",
        )?;
        drop(old_db);
        let store = CookieStore::open(path.clone())?;
        let source = SourceHttpOptions {
            cookie_path: path,
            user_agent: "default".into(),
            legacy_clearance_user_agent: Some("legacy".into()),
        };
        let url = "https://read.example.co.uk/books/1";
        assert!(store.complete_cloudflare(
            url.into(),
            vec![
                platform_cookie("cf_clearance", "one", "read.example.co.uk", "/books"),
                platform_cookie("shared", "two", ".example.co.uk", "/"),
                platform_cookie("foreign", "three", ".other.co.uk", "/"),
                platform_cookie("suffix", "four", ".co.uk", "/"),
                platform_cookie("wrong_path", "five", ".example.co.uk", "/book"),
            ],
            "webview".into(),
            store.generation()?,
        )?);
        let session = Session {
            config: &source,
            store: &store,
            generation: store.generation()?,
        };
        let headers = session.headers(
            url,
            &[HttpHeader {
                name: "User-Agent".into(),
                value: "caller".into(),
            }],
        )?;
        assert_eq!(
            header(&headers, "cookie"),
            Some("cf_clearance=one; shared=two")
        );
        assert_eq!(header(&headers, "user-agent"), Some("webview"));
        let headers = session.headers("https://legacy.example/", &[])?;
        assert_eq!(header(&headers, "user-agent"), Some("legacy"));
        let headers = session.headers("https://sub.read.example.co.uk/books/1", &[])?;
        assert_eq!(header(&headers, "cookie"), Some("shared=two"));
        assert_eq!(header(&headers, "user-agent"), Some("default"));
        assert!(session
            .headers("http://read.example.co.uk/books/1", &[])?
            .iter()
            .all(|header| header.name != "cookie"));
        let headers = session.headers(
            url,
            &[
                HttpHeader {
                    name: "Cookie".into(),
                    value: "cf_clearance=manual".into(),
                },
                HttpHeader {
                    name: "User-Agent".into(),
                    value: "caller".into(),
                },
            ],
        )?;
        assert_eq!(header(&headers, "cookie"), Some("cf_clearance=manual"));
        assert_eq!(header(&headers, "user-agent"), Some("caller"));
        Ok(())
    }

    #[test]
    fn clear_and_restore_invalidate_in_flight_cookie_writes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("cookie.db").to_string_lossy().into_owned();
        let store = CookieStore::open(path.clone())?;
        let other = CookieStore::open(path.clone())?;
        let url = "https://source.example/";
        other.save_headers(url.into(), vec!["account=one".into()])?;
        let old = other.generation()?;
        store.clear()?;
        other.save_response(url, vec!["account=one".into()], None, old)?;
        assert_eq!(store.header(url.into())?, "");
        assert!(!other.complete_cloudflare(
            url.into(),
            vec![platform_cookie(
                "cf_clearance",
                "old",
                "source.example",
                "/"
            )],
            "webview".into(),
            old,
        )?);
        let before_restore = other.generation()?;
        store.close()?;
        assert!(CookieStore::open(path.clone())?.load(url.into()).is_err());
        std::fs::rename(&path, dir.path().join("before-restore.db"))?;
        let mut restored = crate::cookies::Cookies::open(&path)?;
        restored.save_headers(url, vec!["restored=1".into()], None)?;
        drop(restored);
        store.reopen()?;
        other.save_response(url, vec!["before_restore=1".into()], None, before_restore)?;
        assert_eq!(other.header(url.into())?, "restored=1");
        other.delete(url.into(), None)?;
        other.save_headers(url.into(), vec!["account=two".into()])?;
        assert_eq!(store.header(url.into())?, "account=two");
        Ok(())
    }
}
