use crate::{
    image_tasks::{evaluate, Request, Task},
    script::Engine,
};
use anyhow::{ensure, Context, Result};
use serde::Deserialize;
use serde_json::json;
use std::{
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Clone, Deserialize)]
pub(crate) struct Favorite {
    pub id: String,
    #[serde(rename = "sourceKey")]
    pub source: String,
    pub eid: String,
    pub page: u32,
    #[serde(rename = "imageKey")]
    pub image: String,
}

impl Favorite {
    fn validate(&self) -> Result<()> {
        ensure!(self.page > 0, "Image favorite page must start at 1");
        Ok(())
    }

    fn cache_path(&self, root: &str) -> PathBuf {
        // Include page even when the saved image URL is empty or later expires.
        let key = json!([self.source, self.id, self.eid, self.page]).to_string();
        Path::new(root)
            .join("image_favorites")
            .join(format!("v2-{:x}", md5::compute(key)))
    }

    fn legacy_path(&self, root: &str) -> PathBuf {
        let key = format!(
            "ImageFavorites {}@{}@{}@{}",
            self.image, self.source, self.id, self.eid
        );
        Path::new(root)
            .join("image_favorites")
            .join(legacy_hash(&key))
    }

    fn lock_key(&self, root: &str) -> String {
        format!("favorite:{}", self.cache_path(root).display())
    }
}

fn legacy_hash(key: &str) -> String {
    // Dart's old implementation passed codeUnits to a byte sink.
    let bytes: Vec<u8> = key.encode_utf16().map(|v| v as u8).collect();
    format!("{:x}", md5::compute(bytes))
}

fn is_saf(path: &str) -> bool {
    path.starts_with("android://")
}

fn write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("Missing favorite cache directory")?;
    std::fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    file.persist(path)?;
    Ok(())
}

fn read(path: &Path) -> Result<Option<Vec<u8>>> {
    match std::fs::read(path) {
        Ok(bytes) if !bytes.is_empty() => Ok(Some(bytes)),
        Ok(_) => Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn remove(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

pub(crate) async fn delete(cache_path: &str, favorite: &Favorite) -> Result<()> {
    favorite.validate()?;
    let _guard = crate::http_policy::serial(&favorite.lock_key(cache_path)).await;
    for path in [
        favorite.cache_path(cache_path),
        favorite.legacy_path(cache_path),
    ] {
        remove(&path)?;
    }
    Ok(())
}

pub(crate) fn start(
    engine: Arc<Engine>,
    data_path: String,
    cache_path: String,
    local_path: String,
    comic_type: i32,
    favorite: Favorite,
) -> Result<Task> {
    favorite.validate()?;
    Task::spawn(engine.clone(), move |state, id| async move {
        let _guard = crate::http_policy::serial(&favorite.lock_key(&cache_path)).await;
        let local_copy = {
            let _root = crate::local_storage::FILES.read().await;
            let root = crate::local_storage::active(&engine, &local_path);
            local(&engine, &data_path, &root, comic_type, &favorite).await?
        };
        if let Some(bytes) = local_copy {
            return Ok(bytes);
        }
        let path = favorite.cache_path(&cache_path);
        if let Some(bytes) = read(&path)? {
            return Ok(bytes);
        }
        // Empty old URLs shared a file across pages, so those payloads cannot be mapped safely.
        if !favorite.image.is_empty() {
            if let Some(bytes) = read(&favorite.legacy_path(&cache_path))? {
                write(&path, &bytes)?;
                remove(&favorite.legacy_path(&cache_path))?;
                return Ok(bytes);
            }
        }
        let source_lock = engine.source_lock(&favorite.source);
        let _source_guard = source_lock.read_owned().await;
        let bytes = network(&engine, &state, &id, &favorite).await?;
        ensure!(
            !state.cancellation.is_cancelled(),
            "Image request cancelled"
        );
        write(&path, &bytes)?;
        Ok(bytes)
    })
}

async fn local(
    engine: &Engine,
    data_path: &str,
    root: &str,
    comic_type: i32,
    favorite: &Favorite,
) -> Result<Option<Vec<u8>>> {
    let library_path = Path::new(data_path).join("local.db");
    if !library_path.is_file() {
        return Ok(None);
    }
    let comic = crate::local::LocalLibrary::open(&library_path.to_string_lossy())?
        .find(&favorite.id, comic_type)?;
    let Some(comic) = comic else {
        return Ok(None);
    };
    let directory = if comic.directory.contains(['/', '\\']) {
        comic.directory
    } else {
        format!(
            "{}/{directory}",
            root.trim_end_matches(['/', '\\']),
            directory = comic.directory
        )
    };
    let directory = if comic.chapters.is_null() {
        directory
    } else {
        if !crate::local::chapter_ids(&comic.chapters).contains(&favorite.eid) {
            return Ok(None);
        }
        format!(
            "{}/{}",
            directory.trim_end_matches(['/', '\\']),
            if comic_type == 0 && crate::archives::safe_relative(&favorite.eid).is_ok() {
                favorite.eid.clone()
            } else {
                crate::api::local::chapter_directory_name(favorite.eid.clone())
            }
        )
    };
    let result = async {
        let paths = if is_saf(&directory) {
            let value = engine
                .request_platform(
                    json!({"method":"imageFavoriteFile", "operation":"list", "path":directory}),
                )
                .await?;
            crate::api::local::sort_comic_images(serde_json::from_value(value)?)
        } else {
            crate::api::local::list_comic_images(directory)?
        };
        let Some(path) = paths.get((favorite.page - 1) as usize) else {
            return Ok(None);
        };
        let path = path.strip_prefix("file://").unwrap_or(path);
        if is_saf(path) {
            let value = engine
                .request_platform(
                    json!({"method":"imageFavoriteFile", "operation":"read", "path":path}),
                )
                .await?;
            return Ok(Some(crate::script_crypto::bytes(&value)?));
        }
        read(Path::new(path))
    }
    .await;
    // Missing/incomplete local downloads fall through to the favorite cache and source.
    match result {
        Ok(bytes) => Ok(bytes),
        Err(error) => {
            let _ = engine.evaluate(&format!(
                "console.log({})",
                json!(format!("Local favorite image unavailable: {error:#}"))
            ));
            Ok(None)
        }
    }
}

async fn network(
    engine: &Engine,
    state: &Request,
    id: &str,
    favorite: &Favorite,
) -> Result<Vec<u8>> {
    if !favorite.image.is_empty() {
        match fetch(engine, state, id, favorite, &favorite.image).await {
            Ok(bytes) => return Ok(bytes),
            Err(_) if state.cancellation.is_cancelled() => anyhow::bail!("Image request cancelled"),
            Err(_) => {}
        }
    }
    ensure!(
        !state.cancellation.is_cancelled(),
        "Image request cancelled"
    );
    let code = format!(
        r#"(async () => {{
            const source = ComicSource.sources[{}];
            if (!source?.comic?.loadEp) {{
                throw Error('Comic source cannot load pages');
            }}
            const chapter = await source.comic.loadEp({}, {});
            return chapter.images;
        }})()"#,
        json!(favorite.source),
        json!(favorite.id),
        json!(favorite.eid)
    );
    let pages = evaluate(engine, &code).await?;
    let image = pages
        .as_array()
        .context("Invalid comic pages")?
        .get((favorite.page - 1) as usize)
        .and_then(|v| v.as_str())
        .context("Image favorite page out of range")?;
    crate::image_tasks::retry_image(|| fetch(engine, state, id, favorite, image)).await
}

async fn fetch(
    engine: &Engine,
    state: &Request,
    id: &str,
    favorite: &Favorite,
    image: &str,
) -> Result<Vec<u8>> {
    let bytes = crate::image_tasks::fetch(
        engine,
        state,
        id,
        image,
        Some(&favorite.source),
        &favorite.id,
        &favorite.eid,
        false,
    )
    .await?;
    ensure!(!bytes.is_empty(), "Empty image response");
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn favorite(page: u32) -> Favorite {
        Favorite {
            id: "comic-id".into(),
            source: "source-key".into(),
            eid: "chapter/one".into(),
            page,
            image: "old-url".into(),
        }
    }

    fn engine(path: &Path) -> Result<Arc<Engine>> {
        Ok(Arc::new(Engine::open(serde_json::from_value(json!({
            "data_path":path, "version":"1.6.3", "locale":"zh_CN", "platform":"test", "user_agent":"test",
            "http":{"proxy":null,"dns_overrides":{},"tls_sni":true,"verify_certificates":true,"connect_timeout_ms":1000,"receive_timeout_ms":1000,"max_redirects":5}
        }))?)?))
    }

    async fn loaded(task: &Task) -> Result<Vec<u8>> {
        let event = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            task.receiver.lock().await.recv(),
        )
        .await?
        .context("Missing result")?;
        ensure!(event.error.is_none(), "{:?}", event.error);
        event.bytes.context("Missing bytes")
    }

    #[tokio::test]
    async fn legacy_cache_migrates_and_deletion_uses_the_same_identity() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().to_string_lossy().into_owned();
        let engine = engine(dir.path())?;
        let old = favorite(1);
        assert_eq!(
            old.legacy_path(&root).file_name().unwrap(),
            "aa2eb081a3cb6f831465ba11403152d6"
        );
        assert_eq!(
            legacy_hash("ImageFavorites 图片@sample@漫画@章节"),
            "780c15bff5c917fa966e27140f398cd5"
        );
        write(&old.legacy_path(&root), b"legacy")?;
        let task = start(
            engine.clone(),
            root.clone(),
            root.clone(),
            root.clone(),
            42,
            old.clone(),
        )?;
        assert_eq!(loaded(&task).await?, b"legacy");
        assert!(old.cache_path(&root).is_file());
        assert!(!old.legacy_path(&root).exists());
        // URL refresh does not change the stable page cache identity.
        let mut refreshed = old.clone();
        refreshed.image = "new-url".into();
        assert_eq!(refreshed.cache_path(&root), old.cache_path(&root));
        assert_ne!(favorite(2).cache_path(&root), old.cache_path(&root));
        delete(&root, &old).await?;
        assert!(!old.cache_path(&root).exists());
        assert!(!old.legacy_path(&root).exists());
        delete(&root, &old).await?;
        engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn local_comic_id_chapter_and_one_based_pages_precede_cache() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().to_string_lossy().into_owned();
        let engine = engine(dir.path())?;
        let library =
            crate::local::LocalLibrary::open(&dir.path().join("local.db").to_string_lossy())?;
        let mut comic = crate::local::LocalComic {
            id: "comic-id".into(),
            title: "test".into(),
            subtitle: String::new(),
            tags: vec![],
            directory: "book".into(),
            chapters: json!({"group":{"chapter/one":"First","chapter-two":"Last"}}),
            cover: String::new(),
            comic_type: 42,
            downloaded_chapters: vec!["chapter/one".into()],
            created_at: 0,
        };
        library.save(comic.clone())?;
        let chapter = dir.path().join("book/chapter_one");
        std::fs::create_dir_all(&chapter)?;
        std::fs::write(chapter.join("10.jpg"), b"last")?;
        std::fs::write(chapter.join("2.jpg"), b"first")?;
        std::fs::write(chapter.join("cover.jpg"), b"cover")?;
        std::fs::write(chapter.join(".hidden"), b"hidden")?;
        for (page, expected) in [(1, b"first".as_slice()), (2, b"last".as_slice())] {
            let image = favorite(page);
            write(&image.cache_path(&root), b"cache")?;
            let task = start(
                engine.clone(),
                root.clone(),
                root.clone(),
                root.clone(),
                42,
                image,
            )?;
            assert_eq!(loaded(&task).await?, expected);
        }
        let overflow = favorite(3);
        write(&overflow.cache_path(&root), b"fallback")?;
        assert_eq!(
            loaded(&start(
                engine.clone(),
                root.clone(),
                root.clone(),
                root.clone(),
                42,
                overflow
            )?)
            .await?,
            b"fallback"
        );
        assert!(start(
            engine.clone(),
            root.clone(),
            root.clone(),
            root.clone(),
            42,
            favorite(0)
        )
        .is_err());
        // Chapterless comics use their root directory.
        comic.chapters = serde_json::Value::Null;
        library.save(comic)?;
        std::fs::write(dir.path().join("book/1.jpg"), b"single")?;
        assert_eq!(
            loaded(&start(
                engine.clone(),
                root.clone(),
                root.clone(),
                root.clone(),
                42,
                favorite(1)
            )?)
            .await?,
            b"single"
        );
        engine.shutdown().await;
        Ok(())
    }

    #[tokio::test]
    async fn deletion_waits_for_the_active_cache_writer() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().to_string_lossy().into_owned();
        let image = favorite(1);
        let lock_key = image.lock_key(&root);
        let guard = crate::http_policy::serial(&lock_key).await;
        let delete_root = root.clone();
        let deleting = tokio::spawn(async move { delete(&delete_root, &favorite(1)).await });
        tokio::task::yield_now().await;
        assert!(!deleting.is_finished());
        write(&image.cache_path(&root), b"completed")?;
        drop(guard);
        deleting.await??;
        assert!(!image.cache_path(&root).exists());
        Ok(())
    }
}
