use crate::{
    api::http::HttpCancellation,
    comic_queue::{Options, Queue},
};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Deserialize, Serialize)]
struct OwnedFile {
    relative: String,
    digest: String,
    #[serde(default)]
    created: bool,
}

#[derive(Deserialize, Serialize)]
pub(crate) struct Work {
    pub token: String,
    pub key: String,
    options: Options,
    pub destination: PathBuf,
    files: Vec<OwnedFile>,
    directories: Vec<String>,
    mirror_owned: bool,
    legacy_owned: bool,
}

pub(crate) fn token(item: &Value) -> Result<&str> {
    let token = item["_work"].as_str().context("Missing download owner")?;
    uuid::Uuid::parse_str(token)?;
    Ok(token)
}

fn root(options: &Options) -> PathBuf {
    Path::new(&options.data_path).join("download_work")
}
fn manifest(options: &Options, token: &str) -> PathBuf {
    root(options).join("owners").join(format!("{token}.json"))
}

pub(crate) fn read(options: &Options, token: &str) -> Result<Option<Work>> {
    uuid::Uuid::parse_str(token)?;
    let path = manifest(options, token);
    match fs::read(path) {
        Ok(bytes) => {
            let work: Work = serde_json::from_slice(&bytes)?;
            ensure!(
                work.token == token && work.options.data_path == options.data_path,
                "Download owner mismatch"
            );
            Ok(Some(work))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(crate) fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    fs::create_dir_all(path.parent().context("Missing state directory")?)?;
    let mut temporary = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
    temporary.write_all(&serde_json::to_vec(value)?)?;
    temporary.as_file().sync_all()?;
    for attempt in 0..5 {
        match temporary.persist(path) {
            Ok(_) => return Ok(()),
            Err(error)
                if cfg!(windows)
                    && matches!(error.error.raw_os_error(), Some(5 | 32 | 33))
                    && attempt < 4 =>
            {
                temporary = error.file;
                std::thread::sleep(std::time::Duration::from_millis(10 * (attempt + 1)));
            }
            Err(error) => {
                return Err(error).with_context(|| format!("Cannot replace {}", path.display()))
            }
        }
    }
    unreachable!()
}

impl Work {
    pub fn open(options: Options, item: &Value, key: String, destination: PathBuf) -> Result<Self> {
        let token = token(item)?.to_owned();
        if let Some(work) = read(&options, &token)? {
            ensure!(
                work.key == key && work.destination == destination,
                "Download checkpoint belongs to another task"
            );
            return Ok(work);
        }
        let work = Self {
            token,
            key,
            options,
            destination,
            files: vec![],
            directories: vec![],
            mirror_owned: false,
            legacy_owned: item["_legacyWork"] == true,
        };
        work.persist()?;
        fs::create_dir_all(work.payload())?;
        Ok(work)
    }
    pub fn persist(&self) -> Result<()> {
        atomic_json(&manifest(&self.options, &self.token), self)
    }
    pub fn stage(&self) -> PathBuf {
        root(&self.options).join("jobs").join(&self.token)
    }
    pub fn payload(&self) -> PathBuf {
        self.stage().join("content")
    }
    pub fn archive(&self) -> PathBuf {
        self.stage().join("archive.zip")
    }
    fn mirror(&self) -> Result<PathBuf> {
        Ok(self
            .destination
            .parent()
            .context("Invalid SAF destination")?
            .join(format!(".venera-download-{}", self.token)))
    }
    pub fn legacy_payload(&self) -> PathBuf {
        root(&self.options).join(format!("{:x}", md5::compute(&self.key)))
    }
    pub fn committed(&self) -> Result<bool> {
        crate::local::LocalLibrary::open(&format!("{}/local.db", self.options.data_path))?
            .download_committed(&self.token)
    }
    pub async fn exists(&self, queue: &Queue, path: &Path) -> Result<bool> {
        if self.options.saf {
            return queue
                .platform_operation("exists", path, None)
                .await?
                .as_bool()
                .context("Invalid existence receipt");
        }
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                ensure!(
                    !metadata.file_type().is_symlink(),
                    "Download destination contains a symbolic link"
                );
                Ok(true)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
    async fn digest(&self, queue: &Queue, path: &Path) -> Result<String> {
        let bytes = if self.options.saf {
            serde_json::from_value::<Vec<u8>>(
                queue.platform_operation("readFile", path, None).await?,
            )?
        } else {
            fs::read(path)?
        };
        Ok(format!("{:x}", md5::compute(bytes)))
    }
    async fn mkdir(&mut self, queue: &Queue, relative: &str) -> Result<()> {
        let target = self.destination.join(relative);
        if self.exists(queue, &target).await? {
            return Ok(());
        }
        self.directories.push(relative.to_owned());
        self.persist()?;
        if self.options.saf {
            queue
                .platform_operation("createDirectory", &target, None)
                .await?;
        } else {
            fs::create_dir(&target)?;
        }
        Ok(())
    }
    async fn names(&self, queue: &Queue, path: &Path) -> Result<Vec<String>> {
        if !self.exists(queue, path).await? {
            return Ok(vec![]);
        }
        if self.options.saf {
            return Ok(serde_json::from_value(
                queue.platform_operation("listFiles", path, None).await?,
            )?);
        }
        fs::read_dir(path)?
            .map(|entry| {
                let entry = entry?;
                Ok(entry.file_name().to_string_lossy().into_owned())
            })
            .collect()
    }
    pub async fn existing_cover(&self, queue: &Queue) -> Result<Option<String>> {
        Ok(self
            .names(queue, &self.destination)
            .await?
            .into_iter()
            .find(|name| name.starts_with("cover.")))
    }
    pub async fn existing_page(&self, queue: &Queue, chapter: &Path, index: usize) -> Result<bool> {
        Ok(self
            .names(queue, &self.destination.join(chapter))
            .await?
            .iter()
            .any(|name| {
                Path::new(name)
                    .file_stem()
                    .is_some_and(|stem| stem == index.to_string().as_str())
                    && crate::comic_queue::is_image(Path::new(name))
            }))
    }
    pub async fn promote(&mut self, queue: &Queue, cancellation: &HttpCancellation) -> Result<()> {
        check(cancellation)?;
        let files = payload_files(&self.payload())?;
        if self.options.saf {
            let mirror = self.mirror()?;
            ensure!(
                !self.exists(queue, &mirror).await?,
                "SAF staging directory already exists"
            );
            self.mirror_owned = true;
            self.persist()?;
            // A provider copy continues until its receipt. Cancellation is checked afterwards.
            queue
                .platform_operation("copyDirectory", &self.payload(), Some(&mirror))
                .await?;
            check(cancellation)?;
        }
        if !self.options.saf {
            fs::create_dir_all(&self.options.local_path)?;
        }
        self.mkdir(queue, "").await?;
        for relative in files {
            check(cancellation)?;
            let target = self.destination.join(&relative);
            let bytes = fs::read(self.payload().join(&relative))?;
            let digest = format!("{:x}", md5::compute(&bytes));
            if self.exists(queue, &target).await? {
                ensure!(
                    self.digest(queue, &target).await? == digest,
                    "Existing file would be overwritten: {}",
                    target.display()
                );
                continue;
            }
            let parent = relative.parent().context("Missing relative parent")?;
            let mut current = PathBuf::new();
            for component in parent.components() {
                current.push(component);
                self.mkdir(queue, &current.to_string_lossy()).await?;
            }
            self.files.push(OwnedFile {
                relative: relative.to_string_lossy().into_owned(),
                digest,
                created: false,
            });
            self.persist()?;
            if self.options.saf {
                queue
                    .platform_operation("moveFile", &self.mirror()?.join(&relative), Some(&target))
                    .await?;
                self.files.last_mut().unwrap().created = true;
                self.persist()?;
            } else {
                let copy = match fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&target)
                {
                    Ok(mut file) => {
                        self.files.last_mut().unwrap().created = true;
                        self.persist()?;
                        copy_new(&mut file, &bytes, cancellation)
                    }
                    Err(error) => Err(error.into()),
                };
                if copy.as_ref().is_err_and(|error| {
                    error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists)
                }) {
                    self.files.pop();
                } else if copy.is_err() && target.is_file() {
                    self.files.last_mut().unwrap().digest =
                        format!("{:x}", md5::compute(fs::read(&target)?));
                }
                self.persist()?;
                copy?;
            }
        }
        check(cancellation)
    }
    pub async fn rollback(&mut self, queue: &Queue) -> Result<()> {
        if self.committed()? {
            return Ok(());
        }
        while let Some(file) = self.files.last() {
            let target = self.destination.join(crate::archives::safe_relative(
                &file.relative.replace('\\', "/"),
            )?);
            if self.exists(queue, &target).await? {
                ensure!(
                    file.created,
                    "File ownership was not confirmed; cleanup pending: {}",
                    target.display()
                );
                ensure!(
                    self.digest(queue, &target).await? == file.digest,
                    "Owned file was modified; cleanup pending: {}",
                    target.display()
                );
                if self.options.saf {
                    queue
                        .platform_operation("removeFile", &target, None)
                        .await?;
                } else {
                    fs::remove_file(&target)?;
                }
            }
            self.files.pop();
            self.persist()?;
        }
        while let Some(relative) = self.directories.last() {
            if !relative.is_empty() {
                crate::archives::safe_relative(&relative.replace('\\', "/"))?;
            }
            let path = self.destination.join(relative);
            if self.exists(queue, &path).await? {
                // Empty-only deletion preserves files added by users or another caller.
                if self.options.saf {
                    queue
                        .platform_operation("removeEmptyDirectory", &path, None)
                        .await?;
                } else {
                    match fs::remove_dir(&path) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::DirectoryNotEmpty => {}
                        Err(error) => return Err(error.into()),
                    }
                }
            }
            self.directories.pop();
            self.persist()?;
        }
        Ok(())
    }
    pub async fn clean(&mut self, queue: &Queue, discard: bool) -> Result<()> {
        self.rollback(queue).await?;
        if self.mirror_owned {
            let path = self.mirror()?;
            if self.exists(queue, &path).await? {
                queue
                    .platform_operation("removeDirectory", &path, None)
                    .await?;
            }
            self.mirror_owned = false;
            self.persist()?;
        }
        if discard || self.committed()? {
            remove_owned_directory(&self.stage())?;
            if self.legacy_owned {
                remove_owned_directory(&self.legacy_payload())?;
                let archive =
                    root(&self.options).join(format!("{:x}.zip", md5::compute(&self.key)));
                for suffix in ["", ".download", ".download.meta"] {
                    remove_file(&PathBuf::from(format!("{}{suffix}", archive.display())))?;
                }
            }
            remove_file(&manifest(&self.options, &self.token))?;
            crate::local::LocalLibrary::open(&format!("{}/local.db", self.options.data_path))?
                .forget_download(&self.token)?;
            self.files.clear();
            self.directories.clear();
        }
        Ok(())
    }
}

fn copy_new(file: &mut fs::File, bytes: &[u8], cancellation: &HttpCancellation) -> Result<()> {
    for chunk in bytes.chunks(256 * 1024) {
        check(cancellation)?;
        file.write_all(chunk)?;
    }
    file.sync_all()?;
    Ok(())
}
fn check(cancellation: &HttpCancellation) -> Result<()> {
    ensure!(!cancellation.is_cancelled(), "Download cancelled");
    Ok(())
}
fn payload_files(root: &Path) -> Result<Vec<PathBuf>> {
    fn visit(root: &Path, relative: &Path, result: &mut Vec<PathBuf>) -> Result<()> {
        for entry in fs::read_dir(root.join(relative))? {
            let entry = entry?;
            let kind = entry.file_type()?;
            ensure!(
                !kind.is_symlink(),
                "Download payload contains a symbolic link"
            );
            let path = relative.join(entry.file_name());
            if kind.is_dir() {
                visit(root, &path, result)?;
            } else if kind.is_file() {
                result.push(path);
            }
        }
        Ok(())
    }
    let mut result = Vec::new();
    visit(root, Path::new(""), &mut result)?;
    result.sort();
    Ok(result)
}
fn remove_file(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}
fn remove_owned_directory(path: &Path) -> Result<()> {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{local::LocalComic, script::Engine};
    use serde_json::json;
    use std::sync::Arc;

    fn fixture() -> Result<(tempfile::TempDir, Arc<Queue>, Work)> {
        let directory = tempfile::tempdir()?;
        let options: Options = serde_json::from_value(
            json!({"data_path":directory.path(),"cache_path":directory.path(),"local_path":directory.path().join("local"),"saf":false,"threads":1,
            "http":{"proxy":null,"dns_overrides":{},"tls_sni":true,"verify_certificates":true,"connect_timeout_ms":1000,"receive_timeout_ms":1000,"max_redirects":5}}),
        )?;
        let engine = Arc::new(Engine::open(serde_json::from_value(
            json!({"data_path":directory.path(),"version":"1.6.3","locale":"zh_CN","platform":"test","user_agent":"test","http":options.http}),
        )?)?);
        let queue = Queue::open(engine, options.clone(), json!({}))?;
        let item = json!({"_work":uuid::Uuid::new_v4().to_string()});
        let destination = Path::new(&options.local_path).join("book");
        let work = Work::open(options, &item, "source@comic".into(), destination)?;
        Ok((directory, queue, work))
    }
    #[tokio::test]
    async fn rollback_preserves_existing_chapters_and_new_user_files() -> Result<()> {
        let (_directory, queue, mut work) = fixture()?;
        fs::create_dir_all(work.destination.join("a"))?;
        fs::write(work.destination.join("a/0.png"), b"complete")?;
        fs::write(work.destination.join("notes.txt"), b"user")?;
        fs::create_dir(work.payload().join("b"))?;
        fs::write(work.payload().join("b/0.png"), b"new")?;
        work.promote(&queue, &HttpCancellation::new()).await?;
        fs::write(
            work.destination.join("b/user.txt"),
            b"added while downloading",
        )?;
        work.clean(&queue, true).await?;
        assert_eq!(fs::read(work.destination.join("a/0.png"))?, b"complete");
        assert_eq!(fs::read(work.destination.join("notes.txt"))?, b"user");
        assert_eq!(
            fs::read(work.destination.join("b/user.txt"))?,
            b"added while downloading"
        );
        assert!(!work.destination.join("b/0.png").exists());
        assert!(!work.stage().exists());
        assert!(!manifest(&work.options, &work.token).exists());
        Ok(())
    }
    #[tokio::test]
    async fn modified_files_report_cleanup_failure_and_recovery_can_retry() -> Result<()> {
        let (_directory, queue, mut work) = fixture()?;
        fs::write(work.payload().join("0.png"), b"owned")?;
        work.promote(&queue, &HttpCancellation::new()).await?;
        fs::write(work.destination.join("0.png"), b"user modified")?;
        assert!(work.clean(&queue, true).await.is_err());
        assert_eq!(fs::read(work.destination.join("0.png"))?, b"user modified");
        let mut restored = read(&work.options, &work.token)?.unwrap();
        fs::remove_file(work.destination.join("0.png"))?;
        restored.clean(&queue, true).await?;
        assert!(!restored.stage().exists());
        Ok(())
    }
    #[tokio::test]
    async fn committed_download_keeps_files_when_cleanup_is_repeated() -> Result<()> {
        let (_directory, queue, mut work) = fixture()?;
        fs::write(work.payload().join("0.png"), b"complete")?;
        work.promote(&queue, &HttpCancellation::new()).await?;
        let library =
            crate::local::LocalLibrary::open(&format!("{}/local.db", work.options.data_path))?;
        library.save_download(
            LocalComic {
                id: "comic".into(),
                title: "test".into(),
                subtitle: String::new(),
                tags: vec![],
                directory: "book".into(),
                chapters: Value::Null,
                cover: "0.png".into(),
                comic_type: 42,
                downloaded_chapters: vec![],
                created_at: 0,
            },
            &work.token,
        )?;
        let mut restored = read(&work.options, &work.token)?.unwrap();
        restored.clean(&queue, true).await?;
        assert_eq!(fs::read(work.destination.join("0.png"))?, b"complete");
        assert!(library.find("comic", 42)?.is_some());
        restored.clean(&queue, true).await?;
        assert_eq!(fs::read(work.destination.join("0.png"))?, b"complete");
        assert!(read(&work.options, &work.token)?.is_none());
        assert!(!library.download_committed(&work.token)?);
        Ok(())
    }
    #[tokio::test]
    async fn legacy_reserved_artifacts_are_only_removed_for_legacy_owners() -> Result<()> {
        let (_directory, queue, mut work) = fixture()?;
        let archive = root(&work.options).join(format!("{:x}.zip", md5::compute(&work.key)));
        fs::create_dir_all(work.legacy_payload())?;
        fs::write(work.legacy_payload().join("0.png"), b"old partial")?;
        for suffix in ["", ".download", ".download.meta"] {
            fs::write(format!("{}{suffix}", archive.display()), b"checkpoint")?;
        }
        work.clean(&queue, true).await?;
        assert!(archive.exists());
        work.legacy_owned = true;
        work.persist()?;
        work.clean(&queue, true).await?;
        assert!(!work.legacy_payload().exists());
        for suffix in ["", ".download", ".download.meta"] {
            assert!(!Path::new(&format!("{}{suffix}", archive.display())).exists());
        }
        Ok(())
    }
    #[tokio::test]
    async fn pending_cleanup_is_recovered_when_the_queue_reopens() -> Result<()> {
        let (_directory, queue, mut work) = fixture()?;
        fs::write(work.payload().join("0.png"), b"unfinished")?;
        work.promote(&queue, &HttpCancellation::new()).await?;
        let item = json!({"source":"source","comicId":"comic","comicType":42,"_work":work.token,"path":work.destination,"type":"ImagesDownloadTask","comic":null});
        let mut legacy = item.clone();
        legacy.as_object_mut().unwrap().remove("_work");
        atomic_json(
            &Path::new(&work.options.data_path).join("downloading_tasks.json"),
            &vec![legacy],
        )?;
        atomic_json(
            &Path::new(&work.options.data_path).join("download_cleanup.json"),
            &vec![json!({"item":item,"options":work.options})],
        )?;
        let engine = Arc::new(Engine::open(serde_json::from_value(
            json!({"data_path":work.options.data_path,"version":"1.6.3","locale":"zh_CN","platform":"test","user_agent":"test","http":work.options.http}),
        )?)?);
        let restored = Queue::open(engine, work.options.clone(), json!({}))?;
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            while !serde_json::from_str::<Vec<Value>>(&restored.snapshot())
                .unwrap()
                .is_empty()
            {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await?;
        assert!(!work.destination.exists());
        assert!(!work.stage().exists());
        assert!(read(&work.options, &work.token)?.is_none());
        Ok(())
    }
    #[tokio::test]
    async fn an_unconfirmed_file_is_preserved_even_if_its_content_matches() -> Result<()> {
        let (_directory, queue, mut work) = fixture()?;
        fs::create_dir_all(&work.destination)?;
        fs::write(work.destination.join("0.png"), b"same content")?;
        work.files.push(OwnedFile {
            relative: "0.png".into(),
            digest: format!("{:x}", md5::compute(b"same content")),
            created: false,
        });
        work.persist()?;
        assert!(work.clean(&queue, true).await.is_err());
        assert_eq!(fs::read(work.destination.join("0.png"))?, b"same content");
        Ok(())
    }
    #[cfg(windows)]
    #[test]
    fn checkpoint_replacement_retries_a_temporary_windows_lock() -> Result<()> {
        use std::os::windows::fs::OpenOptionsExt;
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("checkpoint.json");
        fs::write(&path, b"old")?;
        let locked = fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&path)?;
        let (ready, started) = std::sync::mpsc::channel();
        let release = std::thread::spawn(move || {
            ready.send(()).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(25));
            drop(locked);
        });
        started.recv()?;
        let result = atomic_json(&path, &json!({"value":"new"}));
        release.join().unwrap();
        result?;
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(path)?)?,
            json!({"value":"new"})
        );
        Ok(())
    }
}
