use anyhow::Result;

pub struct ImageProgress {
    pub current: u64,
    pub total: Option<u64>,
    pub bytes: Option<Vec<u8>>,
    pub error: Option<String>,
}
#[flutter_rust_bridge::frb(opaque)]
pub struct ImageTransfer {
    pub(crate) inner: crate::image_tasks::Task,
}
impl ImageTransfer {
    pub fn start_view(
        runtime: &crate::api::script::ScriptRuntime,
        data_path: String,
        cache_path: String,
        local_path: String,
        request_json: String,
    ) -> Result<Self> {
        Ok(Self {
            inner: crate::view_images::start(
                runtime.inner.clone(),
                data_path,
                cache_path,
                local_path,
                serde_json::from_str(&request_json)?,
            )?,
        })
    }

    pub fn start_favorite(
        runtime: &crate::api::script::ScriptRuntime,
        data_path: String,
        cache_path: String,
        local_path: String,
        comic_type: i32,
        favorite_json: String,
    ) -> Result<Self> {
        Ok(Self {
            inner: crate::favorite_images::start(
                runtime.inner.clone(),
                data_path,
                cache_path,
                local_path,
                comic_type,
                serde_json::from_str(&favorite_json)?,
            )?,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn start(
        runtime: &crate::api::script::ScriptRuntime,
        data_path: String,
        cache_path: String,
        image: String,
        source: Option<String>,
        comic: String,
        chapter: String,
        thumbnail: bool,
    ) -> Result<Self> {
        Ok(Self {
            inner: crate::image_tasks::Task::start(
                runtime.inner.clone(),
                data_path,
                cache_path,
                image,
                source,
                comic,
                chapter,
                thumbnail,
                true,
            )?,
        })
    }
    pub async fn next(&self) -> Option<ImageProgress> {
        self.inner.receiver.lock().await.recv().await
    }
    #[flutter_rust_bridge::frb(sync)]
    pub fn cancel(&self) {
        self.inner.cancel();
    }
}

pub fn invalidate_view_image(
    data_path: String,
    cache_path: String,
    request_json: String,
) -> Result<()> {
    crate::view_images::invalidate(
        &data_path,
        &cache_path,
        &serde_json::from_str(&request_json)?,
    )
}

pub fn delete_legacy_favorite_covers(data_path: String, hashes: Vec<i32>) -> Result<()> {
    let root = std::path::Path::new(&data_path).join("favorite_cover");
    for hash in hashes {
        match std::fs::remove_file(root.join(hash.to_string())) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

pub async fn delete_favorite_image_cache(cache_path: String, favorite_json: String) -> Result<()> {
    crate::favorite_images::delete(&cache_path, &serde_json::from_str(&favorite_json)?).await
}

pub fn export_book(book_json: String, output: String, format: String) -> Result<()> {
    write_book(&serde_json::from_str(&book_json)?, output.as_ref(), &format)
}

pub(crate) fn write_book(
    book: &crate::books::Book,
    output: &std::path::Path,
    format: &str,
) -> Result<()> {
    match format {
        "pdf" => crate::books::pdf(book, output),
        "epub" => crate::books::epub(book, output),
        "cbz" => crate::books::cbz(book, output),
        _ => anyhow::bail!("Unsupported book format"),
    }
}

pub async fn modify_image(data: Vec<u8>, script: String) -> Result<Vec<u8>> {
    static LIMIT: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
    let _permit = LIMIT.acquire().await?;
    tokio::task::spawn_blocking(move || crate::imaging::modify(data, script)).await?
}
