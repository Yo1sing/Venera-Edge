use anyhow::{ensure, Context, Result};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, RwLock, RwLockReadGuard, Weak},
};

// Only short, synchronous storage operations take this lock. Source installation
// and local file operations can also span platform events, so they use OPERATIONS.
static STORAGE: RwLock<()> = RwLock::new(());
pub static OPERATIONS: tokio::sync::RwLock<()> = tokio::sync::RwLock::const_new(());
static STORES: Mutex<Vec<Weak<dyn RestoreStore>>> = Mutex::new(Vec::new());

pub fn access() -> RwLockReadGuard<'static, ()> {
    STORAGE.read().unwrap_or_else(|e| e.into_inner())
}

pub fn exclusive<T>(work: impl FnOnce() -> Result<T>) -> Result<T> {
    let _guard = STORAGE.write().unwrap_or_else(|e| e.into_inner());
    work()
}

pub(crate) trait RestoreStore: Send + Sync {
    fn disconnect(&self, directory: &Path);
}

// Register while holding shared storage access so restore cannot miss a live handle.
pub(crate) fn register(store: Arc<dyn RestoreStore>) {
    let mut stores = STORES.lock().unwrap_or_else(|e| e.into_inner());
    stores.retain(|store| store.strong_count() != 0);
    stores.push(Arc::downgrade(&store));
}

type OpenDatabase<T> = dyn Fn(&str) -> Result<T> + Send + Sync;

pub struct Database<T> {
    path: String,
    directory: Option<PathBuf>,
    open: Box<OpenDatabase<T>>,
    connection: Mutex<(bool, Option<T>)>,
}

impl<T: Send + 'static> Database<T> {
    pub fn new(
        path: String,
        open: impl Fn(&str) -> Result<T> + Send + Sync + 'static,
    ) -> Result<Arc<Self>> {
        let _guard = access();
        let db = open(&path)?;
        let directory = Path::new(&path)
            .parent()
            .and_then(|p| p.canonicalize().ok());
        let store = Arc::new(Self {
            path,
            directory,
            open: Box::new(open),
            connection: Mutex::new((true, Some(db))),
        });
        register(store.clone());
        Ok(store)
    }

    pub fn with<R>(&self, work: impl FnOnce(&mut T) -> Result<R>) -> Result<R> {
        let _guard = access();
        let mut state = self.connection.lock().unwrap_or_else(|e| e.into_inner());
        ensure!(state.0, "Database store is closed");
        if state.1.is_none() {
            state.1 = Some((self.open)(&self.path)?);
        }
        work(state.1.as_mut().context("Database unavailable")?)
    }

    pub fn close(&self) {
        let _guard = access();
        *self.connection.lock().unwrap_or_else(|e| e.into_inner()) = (false, None);
    }
}

impl<T: Send> RestoreStore for Database<T> {
    fn disconnect(&self, directory: &Path) {
        if self.directory.as_deref() == Some(directory) {
            self.connection
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .1
                .take();
        }
    }
}

// Call with exclusive storage access and after dropping SQLite change monitors.
pub fn disconnect(directory: &Path) -> Result<()> {
    let directory = directory.canonicalize()?;
    let stores = STORES.lock().unwrap_or_else(|e| e.into_inner());
    for store in stores.iter().filter_map(Weak::upgrade) {
        store.disconnect(&directory);
    }
    Ok(())
}
