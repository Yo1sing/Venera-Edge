use crate::{
    api::http::{HttpCancellation, HttpHeader, HttpUpload},
    script::Engine,
};
use anyhow::{anyhow, ensure, Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

#[derive(Clone, Serialize)]
pub struct Source {
    #[serde(flatten)]
    metadata: Value,
    file_path: String,
    #[serde(skip)]
    code: String,
}

impl Source {
    fn key(&self) -> &str {
        self.metadata["key"].as_str().expect("validated source key")
    }
}
#[derive(Default)]
struct State {
    sources: Vec<Source>,
    updates: HashMap<String, String>,
    revision: u64,
}
pub struct Manager {
    engine: Arc<Engine>,
    directory: PathBuf,
    state: Arc<Mutex<State>>,
    mutations: Arc<tokio::sync::Mutex<()>>,
}
#[derive(Clone)]
pub(crate) struct Shared {
    directory: PathBuf,
    state: Arc<Mutex<State>>,
    mutations: Arc<tokio::sync::Mutex<()>>,
}

fn check_cancel(cancel: &HttpCancellation) -> Result<()> {
    ensure!(!cancel.is_cancelled(), "Source operation cancelled");
    Ok(())
}
fn evaluate(engine: &Engine, code: &str) -> Result<Value> {
    crate::script::unpack(&serde_json::from_str(&engine.evaluate(code)?)?)
}
fn atomic_write(path: &Path, code: &str) -> Result<()> {
    let mut file =
        tempfile::NamedTempFile::new_in(path.parent().context("Missing source directory")?)?;
    file.write_all(code.as_bytes())?;
    file.as_file().sync_all()?;
    file.persist(path)?;
    Ok(())
}

struct Prepared<'a> {
    engine: &'a Engine,
    metadata: Value,
}
impl Drop for Prepared<'_> {
    fn drop(&mut self) {
        let _ = self
            .engine
            .evaluate(&format!("__sources.discard({})", self.metadata["token"]));
    }
}
struct Blocked<'a> {
    engine: &'a Engine,
    key: String,
}
impl Drop for Blocked<'_> {
    fn drop(&mut self) {
        let _ = self
            .engine
            .evaluate(&format!("__sources.unblock({})", json!(self.key)));
    }
}

impl Manager {
    pub fn open(engine: Arc<Engine>) -> Result<Self> {
        let directory = Path::new(&engine.options()?.data_path).join("comic_source");
        fs::create_dir_all(&directory)?;
        let shared = {
            let mut shared = engine
                .source_management
                .lock()
                .map_err(|_| anyhow!("Source state poisoned"))?;
            shared
                .get_or_insert_with(|| Shared {
                    directory,
                    state: Arc::new(Mutex::new(State::default())),
                    mutations: Arc::new(tokio::sync::Mutex::new(())),
                })
                .clone()
        };
        Ok(Self {
            engine,
            directory: shared.directory,
            state: shared.state,
            mutations: shared.mutations,
        })
    }
    pub fn snapshot(&self) -> Result<String> {
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?;
        Ok(
            json!({"sources":state.sources,"updates":state.updates,"revision":state.revision})
                .to_string(),
        )
    }
    fn find(&self, key: &str) -> Result<Source> {
        self.state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?
            .sources
            .iter()
            .find(|source| source.key() == key)
            .cloned()
            .context("Comic source not found")
    }
    async fn validate(
        &self,
        code: &str,
        expected: Option<&str>,
        cancel: &HttpCancellation,
    ) -> Result<Value> {
        check_cancel(cancel)?;
        let mut options = self.engine.options()?;
        options.validation = true;
        let worker = Engine::open(options)?;
        let result = evaluate(
            &worker,
            &format!("__sources.prepare({},{})", json!(code), json!(expected)),
        );
        worker.shutdown().await;
        check_cancel(cancel)?;
        result
    }
    fn prepare<'a>(&'a self, code: &str, expected: Option<&str>) -> Result<Prepared<'a>> {
        let wire = self.engine.prepare_source(format!(
            "__venera.evaluate({})",
            json!(format!(
                "__sources.prepare({},{})",
                json!(code),
                json!(expected)
            ))
        ))?;
        let metadata = crate::script::unpack(&serde_json::from_str(&wire)?)?;
        Ok(Prepared {
            engine: &self.engine,
            metadata,
        })
    }
    async fn block(&self, key: &str, cancel: &HttpCancellation) -> Result<Blocked<'_>> {
        loop {
            check_cancel(cancel)?;
            if evaluate(&self.engine, &format!("__sources.tryBlock({})", json!(key)))? == true {
                return Ok(Blocked {
                    engine: &self.engine,
                    key: key.into(),
                });
            }
            tokio::select! {
                _=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),
                _=tokio::time::sleep(Duration::from_millis(20))=>{}
            }
        }
    }
    fn available_path(&self, name: &str) -> Result<PathBuf> {
        let name = crate::archives::safe_relative(name)?;
        ensure!(
            name.components().count() == 1,
            "Source name must be a file name"
        );
        let stem = name
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("source");
        for index in 0..10000 {
            let name = if index == 0 {
                format!("{stem}.js")
            } else {
                format!("{stem}({index}).js")
            };
            let path = self.directory.join(name);
            if !path.exists() {
                return Ok(path);
            }
        }
        Err(anyhow!("Too many source files with the same name"))
    }
    /// Validation and waiting remain cancellable. Once commit starts, finish the
    /// disk/runtime transaction and return its actual outcome.
    async fn commit(
        &self,
        code: String,
        name: &str,
        expected: Option<&str>,
        cancel: &HttpCancellation,
    ) -> Result<String> {
        let metadata = self.validate(&code, expected, cancel).await?;
        let key = metadata["key"]
            .as_str()
            .context("Missing source key")?
            .to_owned();
        let _storage = tokio::select! {
            _ = cancel.cancelled() => anyhow::bail!("Source operation cancelled"),
            guard = crate::backup_storage::OPERATIONS.read() => guard,
        };
        let _mutation = tokio::select! {_=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),guard=self.mutations.lock()=>guard};
        let previous = if let Some(expected) = expected {
            Some(self.find(expected)?)
        } else {
            None
        };
        if previous.is_none() {
            ensure!(
                !self
                    .state
                    .lock()
                    .map_err(|_| anyhow!("Source state poisoned"))?
                    .sources
                    .iter()
                    .any(|source| source.key() == key),
                "key({key}) already exists"
            );
            ensure!(
                evaluate(
                    &self.engine,
                    &format!(
                        "Object.prototype.hasOwnProperty.call(ComicSource.sources,{})",
                        json!(key)
                    )
                )? != true,
                "key({key}) already exists"
            );
        }
        let lock = self.engine.source_lock(&key);
        let _exclusive = tokio::select! {_=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),guard=lock.write_owned()=>guard};
        let _blocked = self.block(&key, cancel).await?;
        let prepared = self.prepare(&code, expected)?;
        let path = match &previous {
            Some(source) => PathBuf::from(&source.file_path),
            None => self.available_path(name)?,
        };
        check_cancel(cancel)?;
        atomic_write(&path, &code)?;
        let mut activated = match evaluate(
            &self.engine,
            &format!("__sources.activate({})", prepared.metadata["token"]),
        ) {
            Ok(metadata) => metadata,
            Err(error) => {
                let rollback = match &previous {
                    Some(source) => atomic_write(&path, &source.code),
                    None => fs::remove_file(&path).map_err(Into::into),
                };
                rollback.context(format!(
                    "Runtime commit failed ({error:#}); source file rollback failed"
                ))?;
                return Err(error);
            }
        };
        activated
            .as_object_mut()
            .context("Invalid metadata")?
            .remove("token");
        let source = Source {
            metadata: activated,
            file_path: path.to_string_lossy().into_owned(),
            code,
        };
        let result = serde_json::to_string(&source)?;
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| anyhow!("Source state poisoned"))?;
            if let Some(index) = state.sources.iter().position(|s| s.key() == key) {
                state.sources[index] = source;
            } else {
                state.sources.push(source);
            }
            state.updates.remove(&key);
            state.revision += 1;
        }
        drop(_blocked);
        let _ = self
            .engine
            .evaluate(&format!("__sources.init({})", json!(key)));
        Ok(result)
    }
    pub async fn install(
        &self,
        code: String,
        name: String,
        cancel: &HttpCancellation,
    ) -> Result<String> {
        self.commit(code, &name, None, cancel).await
    }
    pub async fn save(
        &self,
        key: String,
        code: String,
        cancel: &HttpCancellation,
    ) -> Result<String> {
        self.commit(code, "source.js", Some(&key), cancel).await
    }
    pub fn read(&self, key: &str) -> Result<String> {
        Ok(fs::read_to_string(self.find(key)?.file_path)?)
    }
    pub fn begin_edit(&self, key: &str) -> Result<String> {
        let directory = self.directory.join(".edits");
        fs::create_dir_all(&directory)?;
        let mut file = tempfile::Builder::new()
            .prefix("source-")
            .suffix(".js")
            .tempfile_in(directory)?;
        file.write_all(self.read(key)?.as_bytes())?;
        let (_, path) = file.keep()?;
        Ok(path.to_string_lossy().into_owned())
    }
    fn edit_path(&self, path: &str) -> Result<PathBuf> {
        let path = Path::new(path).canonicalize()?;
        ensure!(
            path.parent() == Some(self.directory.join(".edits").canonicalize()?.as_path()),
            "Invalid source edit path"
        );
        Ok(path)
    }
    pub async fn save_edit(
        &self,
        key: String,
        path: String,
        cancel: &HttpCancellation,
    ) -> Result<String> {
        let code = fs::read_to_string(self.edit_path(&path)?)?;
        self.save(key, code, cancel).await
    }
    pub fn discard_edit(&self, path: &str) -> Result<()> {
        fs::remove_file(self.edit_path(path)?)?;
        Ok(())
    }
    pub async fn remove(&self, key: &str, cancel: &HttpCancellation) -> Result<()> {
        let _storage = tokio::select! {
            _ = cancel.cancelled() => anyhow::bail!("Source operation cancelled"),
            guard = crate::backup_storage::OPERATIONS.read() => guard,
        };
        let _mutation = tokio::select! {_=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),guard=self.mutations.lock()=>guard};
        let source = self.find(key)?;
        let lock = self.engine.source_lock(key);
        let _exclusive = tokio::select! {_=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),guard=lock.write_owned()=>guard};
        let _blocked = self.block(key, cancel).await?;
        check_cancel(cancel)?;
        fs::remove_file(&source.file_path)?;
        if let Err(error) = self
            .engine
            .evaluate(&format!("__sources.remove({})", json!(key)))
        {
            atomic_write(Path::new(&source.file_path), &source.code)
                .context("Unable to restore removed source")?;
            return Err(error);
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?;
        state.sources.retain(|source| source.key() != key);
        state.updates.remove(key);
        state.revision += 1;
        Ok(())
    }
    async fn download(&self, url: &str, cancel: &HttpCancellation) -> Result<Vec<u8>> {
        let parsed = url::Url::parse(url)?;
        ensure!(
            ["http", "https"].contains(&parsed.scheme()),
            "Source URL must use HTTP or HTTPS"
        );
        let options = self.engine.options()?;
        let response = crate::api::http::http_request(
            url.into(),
            "GET".into(),
            vec![
                HttpHeader {
                    name: "cache-time".into(),
                    value: "no".into(),
                },
                HttpHeader {
                    name: "User-Agent".into(),
                    value: options.user_agent,
                },
            ],
            None,
            &HttpUpload::new(),
            false,
            options.http,
            cancel,
        )
        .await?;
        if response.status() != 200 {
            let status = response.status();
            response.close().await;
            return Err(anyhow!("Source download failed: HTTP {status}"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.next_chunk(cancel).await? {
            bytes.extend(chunk);
        }
        check_cancel(cancel)?;
        Ok(bytes)
    }
    pub async fn install_url(&self, url: String, cancel: &HttpCancellation) -> Result<String> {
        let parsed = url::Url::parse(&url)?;
        let name = parsed
            .path_segments()
            .and_then(|mut segments| segments.next_back())
            .filter(|name| !name.is_empty())
            .unwrap_or("source.js")
            .to_owned();
        let code = String::from_utf8(self.download(&url, cancel).await?)?;
        self.install(code, name, cancel).await
    }
    pub async fn update(&self, key: String, cancel: &HttpCancellation) -> Result<String> {
        let source = self.find(&key)?;
        let url = source.metadata["url"]
            .as_str()
            .context("Invalid source URL")?;
        let code = String::from_utf8(self.download(url, cancel).await?)?;
        self.save(key, code, cancel).await
    }
    pub async fn catalog(&self, url: String, cancel: &HttpCancellation) -> Result<String> {
        let bytes = self.download(&url, cancel).await?;
        let mut entries: Vec<Value> = serde_json::from_slice(&bytes)?;
        let base = url::Url::parse(&url)?;
        let mut keys = HashSet::new();
        for entry in &mut entries {
            let key = entry["key"]
                .as_str()
                .context("Catalog entry requires key")?
                .to_owned();
            ensure!(keys.insert(key), "Duplicate source key in catalog");
            for field in ["name", "version"] {
                ensure!(entry[field].is_string(), "Catalog entry requires {field}");
            }
            let explicit = entry["url"]
                .as_str()
                .and_then(|value| url::Url::parse(value).ok())
                .filter(|url| ["http", "https"].contains(&url.scheme()));
            let resolved = match explicit {
                Some(url) => url,
                None => base.join(
                    entry["fileName"]
                        .as_str()
                        .context("Catalog entry requires URL or fileName")?,
                )?,
            };
            ensure!(
                ["http", "https"].contains(&resolved.scheme()),
                "Invalid catalog source URL"
            );
            entry["url"] = resolved.to_string().into();
        }
        Ok(serde_json::to_string(&entries)?)
    }
    pub async fn check_updates(&self, url: String, cancel: &HttpCancellation) -> Result<String> {
        let entries: Vec<Value> = serde_json::from_str(&self.catalog(url, cancel).await?)?;
        let _mutation = tokio::select! {_=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),guard=self.mutations.lock()=>guard};
        let sources = self
            .state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?
            .sources
            .clone();
        let mut updates = HashMap::new();
        for source in sources {
            if let Some(entry) = entries
                .iter()
                .find(|entry| entry["key"] == source.metadata["key"])
            {
                if evaluate(
                    &self.engine,
                    &format!(
                        "__sources.newer({},{})",
                        entry["version"], source.metadata["version"]
                    ),
                )? == true
                {
                    updates.insert(
                        source.key().to_owned(),
                        entry["version"].as_str().unwrap().to_owned(),
                    );
                }
            }
        }
        check_cancel(cancel)?;
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| anyhow!("Source state poisoned"))?;
            state.updates = updates.clone();
            state.revision += 1;
        }
        Ok(serde_json::to_string(&updates)?)
    }
    pub async fn load(&self, cancel: &HttpCancellation) -> Result<String> {
        let _mutation = self.mutations.lock().await;
        let mut paths = fs::read_dir(&self.directory)?
            .map(|entry| entry.map(|entry| entry.path()))
            .collect::<std::io::Result<Vec<_>>>()?;
        paths.retain(|path| {
            path.is_file() && path.extension().is_some_and(|extension| extension == "js")
        });
        paths.sort();
        let mut candidates = Vec::new();
        let mut errors = Vec::new();
        let mut keys = HashSet::new();
        for path in paths {
            let result = async {
                let code = fs::read_to_string(&path)?;
                let metadata = self.validate(&code, None, cancel).await?;
                let key = metadata["key"].as_str().context("Missing key")?.to_owned();
                ensure!(keys.insert(key), "Duplicate installed source key");
                Ok::<_, anyhow::Error>((path, code, metadata))
            }
            .await;
            match result {
                Ok(candidate) => candidates.push(candidate),
                Err(error) => {
                    check_cancel(cancel)?;
                    errors.push(format!("{error:#}"));
                }
            }
        }
        // A reload of an existing registry fails before touching any live source.
        if !self
            .state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?
            .sources
            .is_empty()
        {
            ensure!(
                errors.is_empty(),
                "Source reload failed: {}",
                errors.join("\n")
            );
        }
        let old = self
            .state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?
            .sources
            .clone();
        let mut all_keys: Vec<String> = old
            .iter()
            .map(|s| s.key().to_owned())
            .chain(
                candidates
                    .iter()
                    .map(|(_, _, metadata)| metadata["key"].as_str().unwrap().to_owned()),
            )
            .collect();
        all_keys.sort();
        all_keys.dedup();
        let mut exclusive = Vec::new();
        let mut blocked = Vec::new();
        for key in &all_keys {
            let lock = self.engine.source_lock(key);
            exclusive.push(tokio::select! {_=cancel.cancelled()=>return Err(anyhow!("Source operation cancelled")),guard=lock.write_owned()=>guard});
            blocked.push(self.block(key, cancel).await?);
        }
        let prepared = candidates
            .iter()
            .map(|(_, code, _)| self.prepare(code, None))
            .collect::<Result<Vec<_>>>()?;
        check_cancel(cancel)?;
        let tokens: Vec<_> = prepared
            .iter()
            .map(|candidate| candidate.metadata["token"].clone())
            .collect();
        let removed: Vec<_> = old
            .iter()
            .filter(|source| !keys.contains(source.key()))
            .map(|source| source.key().to_owned())
            .collect();
        let activated = evaluate(
            &self.engine,
            &format!(
                "__sources.activateAll({},{})",
                json!(tokens),
                json!(removed)
            ),
        )?;
        let mut sources = Vec::new();
        for ((path, code, _), metadata) in candidates
            .iter()
            .zip(activated.as_array().context("Invalid activated sources")?)
        {
            sources.push(Source {
                metadata: metadata.clone(),
                file_path: path.to_string_lossy().into_owned(),
                code: code.clone(),
            });
        }
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| anyhow!("Source state poisoned"))?;
            state.sources = sources.clone();
            state.updates.clear();
            state.revision += 1;
        }
        drop(blocked);
        drop(exclusive);
        for source in sources {
            let _ = self
                .engine
                .evaluate(&format!("__sources.init({})", json!(source.key())));
        }
        Ok(
            json!({"snapshot":serde_json::from_str::<Value>(&self.snapshot()?)?,"errors":errors})
                .to_string(),
        )
    }
    pub fn reconcile_pages(&self, settings: Value, added: Option<&str>) -> Result<String> {
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow!("Source state poisoned"))?;
        let mut result = json!({});
        for field in ["explore_pages", "categories", "favorites", "searchSources"] {
            let mut available = Vec::new();
            let mut additions = Vec::new();
            for source in &state.sources {
                let pages = match field {
                    "explore_pages" => source.metadata["explore_titles"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default(),
                    "categories" => source.metadata["category_title"]
                        .as_str()
                        .map(|s| vec![json!(s)])
                        .unwrap_or_default(),
                    "favorites" => source.metadata["favorites_title"]
                        .as_str()
                        .map(|s| vec![json!(s)])
                        .unwrap_or_default(),
                    _ => {
                        if source.metadata["search_enabled"] == true {
                            vec![json!(source.key())]
                        } else {
                            vec![]
                        }
                    }
                };
                if added == Some(source.key()) {
                    additions.extend(pages.clone());
                }
                available.extend(pages);
            }
            let mut selected = if field == "searchSources" && settings[field].is_null() {
                available.clone()
            } else {
                settings[field].as_array().cloned().unwrap_or_default()
            };
            selected.retain(|value| available.contains(value));
            for page in additions {
                if !selected.contains(&page) {
                    selected.push(page);
                }
            }
            let mut seen = HashSet::new();
            selected.retain(|value| seen.insert(value.to_string()));
            result[field] = selected.into();
        }
        Ok(result.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn code(version: &str) -> String {
        format!("class Sample extends ComicSource {{ name='Sample';key='sample';version={};comic={{loadInfo:()=>({{title:'usable',cover:'cover',tags:{{}}}})}};}}",json!(version))
    }
    fn fixture() -> Result<(tempfile::TempDir, Arc<Manager>)> {
        let directory = tempfile::tempdir()?;
        let options = serde_json::from_value(
            json!({"data_path":directory.path(),"version":"1.6.3","locale":"zh_CN","platform":"test","user_agent":"test",
            "http":{"proxy":null,"dns_overrides":{},"tls_sni":true,"verify_certificates":true,"connect_timeout_ms":1000,"receive_timeout_ms":1000,"max_redirects":5}}),
        )?;
        let manager = Arc::new(Manager::open(Arc::new(Engine::open(options)?))?);
        Ok((directory, manager))
    }
    fn version(manager: &Manager) -> Result<Value> {
        evaluate(&manager.engine, "ComicSource.sources.sample.version")
    }
    #[tokio::test]
    async fn invalid_updates_duplicate_keys_and_version_limits_preserve_old_source() -> Result<()> {
        let (_directory, manager) = fixture()?;
        let cancel = HttpCancellation::new();
        manager
            .install(code("1.0.0"), "sample.js".into(), &cancel)
            .await?;
        let old = manager.read("sample")?;
        let invalid=vec![
            "invalid script".to_owned(),
            code("2.0.0").replace("key='sample'","key='other'"),
            code("2.0.0").replace("comic={","minAppVersion='99.0.0';comic={"),
            code("2.0.0").replace("comic={","explore=[{title:'Broken',type:'unknown'}];comic={"),
            code("2.0.0").replace("comic={","settings={bad:1};comic={"),
            code("2.0.0").replace("comic={","search={optionList:[{options:[],type:5}]};comic={"),
            code("2.0.0").replace("comic={","category={title:'Categories',parts:[{name:'part',type:'fixed',categories:[{label:'bad',target:'search'}]}]};comic={"),
            code("2.0.0").replace("comic={","account={registerWebsite:5};comic={"),
            code("2.0.0").replace("comic={","constructor(){super();this.saveData('sideEffect',true);}comic={"),
            // Isolated validation succeeds, but preparation in the live registry fails.
            code("2.0.0").replace("comic={","constructor(){super();if(ComicSource.sources.sample)throw Error('live preparation failed');}comic={"),
        ];
        for candidate in invalid {
            assert!(manager
                .save("sample".into(), candidate, &cancel)
                .await
                .is_err());
            assert_eq!(manager.read("sample")?, old);
            assert_eq!(version(&manager)?, "1.0.0");
            assert_eq!(
                evaluate(
                    &manager.engine,
                    "ComicSource.sources.sample.comic.loadInfo().title"
                )?,
                "usable"
            );
        }
        assert!(manager
            .install(code("2.0.0"), "duplicate.js".into(), &cancel)
            .await
            .is_err());
        assert_eq!(fs::read_dir(&manager.directory)?.count(), 1);
        assert!(
            crate::script::source_data(_directory.path().to_str().unwrap(), "sample")?
                ["sideEffect"]
                .is_null()
        );
        Ok(())
    }
    #[tokio::test]
    async fn installs_keep_existing_filenames_and_edits_commit_only_valid_scripts() -> Result<()> {
        let (_directory, manager) = fixture()?;
        let cancel = HttpCancellation::new();
        manager
            .install(code("1.0.0"), "custom-name.js".into(), &cancel)
            .await?;
        let path = manager.find("sample")?.file_path;
        let draft = manager.begin_edit("sample")?;
        fs::write(&draft, "invalid")?;
        assert!(manager
            .save_edit("sample".into(), draft.clone(), &cancel)
            .await
            .is_err());
        assert_eq!(version(&manager)?, "1.0.0");
        fs::write(&draft, code("2.0.0"))?;
        manager
            .save_edit("sample".into(), draft.clone(), &cancel)
            .await?;
        assert_eq!(manager.find("sample")?.file_path, path);
        assert_eq!(version(&manager)?, "2.0.0");
        manager.discard_edit(&draft)?;
        assert!(!Path::new(&draft).exists());
        assert!(manager.discard_edit(&path).is_err());
        manager.remove("sample", &cancel).await?;
        assert!(!Path::new(&path).exists());
        assert!(evaluate(&manager.engine, "ComicSource.sources.sample==null")? == true);
        Ok(())
    }
    #[tokio::test]
    async fn cancelling_a_waiting_update_preserves_files_and_unblocks_source_calls() -> Result<()> {
        let (_directory, manager) = fixture()?;
        manager
            .install(code("1.0.0"), "sample.js".into(), &HttpCancellation::new())
            .await?;
        let read = manager.engine.source_lock("sample").read_owned().await;
        let cancel = Arc::new(HttpCancellation::new());
        let worker = manager.clone();
        let token = cancel.clone();
        let update = crate::script::executor()
            .spawn(async move { worker.save("sample".into(), code("2.0.0"), &token).await });
        tokio::time::sleep(Duration::from_millis(30)).await;
        cancel.cancel();
        assert!(tokio::time::timeout(Duration::from_secs(2), update)
            .await??
            .is_err());
        assert_eq!(version(&manager)?, "1.0.0");
        assert_eq!(manager.read("sample")?, code("1.0.0"));
        drop(read);
        manager
            .save("sample".into(), code("2.0.0"), &HttpCancellation::new())
            .await?;
        assert_eq!(version(&manager)?, "2.0.0");
        Ok(())
    }
    #[tokio::test]
    async fn update_waits_for_javascript_calls_and_rejects_retired_callback_handles() -> Result<()>
    {
        let (_directory, manager) = fixture()?;
        let old=code("1.0.0").replace("comic={","get settings(){return {action:{callback:()=>new Promise(resolve=>globalThis.finishSourceCall=()=>resolve('old'))}}} comic={");
        manager
            .install(old, "sample.js".into(), &HttpCancellation::new())
            .await?;
        let handle: Value = serde_json::from_str(
            &manager
                .engine
                .evaluate("ComicSource.sources.sample.settings.action.callback")?,
        )?;
        let promise: Value = serde_json::from_str(
            &manager
                .engine
                .evaluate("ComicSource.sources.sample.settings.action.callback()")?,
        )?;
        let worker = manager.clone();
        let update = crate::script::executor().spawn(async move {
            worker
                .save("sample".into(), code("2.0.0"), &HttpCancellation::new())
                .await
        });
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(version(&manager)?, "1.0.0");
        manager.engine.evaluate("finishSourceCall()")?;
        manager.engine.promise(promise[1].as_u64().unwrap()).await?;
        tokio::time::timeout(Duration::from_secs(2), update).await???;
        assert_eq!(version(&manager)?, "2.0.0");
        assert!(manager
            .engine
            .query(format!("__venera.call({},['array',[]])", handle[1]))
            .is_err());
        Ok(())
    }
    #[tokio::test]
    async fn load_handles_legacy_filenames_and_reports_duplicate_or_invalid_files() -> Result<()> {
        let (_directory, manager) = fixture()?;
        fs::write(manager.directory.join("a-legacy-name.js"), code("1.0.0"))?;
        fs::write(manager.directory.join("b-duplicate.js"), code("2.0.0"))?;
        fs::write(manager.directory.join("c-invalid.js"), "invalid")?;
        let result: Value = serde_json::from_str(&manager.load(&HttpCancellation::new()).await?)?;
        assert_eq!(result["snapshot"]["sources"].as_array().unwrap().len(), 1);
        assert_eq!(result["errors"].as_array().unwrap().len(), 2);
        assert_eq!(version(&manager)?, "1.0.0");
        assert!(manager.load(&HttpCancellation::new()).await.is_err());
        assert_eq!(version(&manager)?, "1.0.0");
        Ok(())
    }
    #[tokio::test]
    async fn category_and_option_compatibility_rules_execute_in_the_backend() -> Result<()> {
        let (_directory, manager) = fixture()?;
        let source=code("1.0.0").replace("comic={",r#"category={title:'Categories',parts:[{name:'genre',type:'fixed',categories:['action'],itemType:'search_with_namespace'}]};
            search={optionList:[{label:'Sort',options:['new-New-first','invalid']}],load:()=>({comics:[]})};
            explore=[{title:'Explore',type:'multiPageComicList',load:()=>({comics:[]})}];comic={"#);
        manager
            .install(source, "sample.js".into(), &HttpCancellation::new())
            .await?;
        assert_eq!(evaluate(&manager.engine,"ComicSource.sources.sample.category.parts[0].categories[0].target.attributes.keyword")?,"genre:action");
        assert_eq!(
            evaluate(
                &manager.engine,
                "ComicSource.sources.sample.search.optionList[0]._options"
            )?,
            json!({"new":"New-first"})
        );
        let pages: Value = serde_json::from_str(&manager.reconcile_pages(
            json!({"explore_pages":["removed","Explore","Explore"]}),
            Some("sample"),
        )?)?;
        assert_eq!(
            pages,
            json!({"explore_pages":["Explore"],"categories":["Categories"],"favorites":[],"searchSources":["sample"]})
        );
        Ok(())
    }
    #[tokio::test]
    async fn concurrent_installs_commit_one_copy_and_cancelled_installs_create_no_files(
    ) -> Result<()> {
        let (_directory, manager) = fixture()?;
        let cancel = HttpCancellation::new();
        cancel.cancel();
        assert!(manager
            .install(code("1.0.0"), "sample.js".into(), &cancel)
            .await
            .is_err());
        assert_eq!(fs::read_dir(&manager.directory)?.count(), 0);
        let first = manager.clone();
        let second = Arc::new(Manager::open(manager.engine.clone())?);
        let first = crate::script::executor().spawn(async move {
            first
                .install(code("1.0.0"), "sample.js".into(), &HttpCancellation::new())
                .await
        });
        let second = crate::script::executor().spawn(async move {
            second
                .install(code("2.0.0"), "another.js".into(), &HttpCancellation::new())
                .await
        });
        let (first, second) = tokio::join!(first, second);
        assert_ne!(first?.is_ok(), second?.is_ok());
        assert_eq!(fs::read_dir(&manager.directory)?.count(), 1);
        assert_eq!(manager.state.lock().unwrap().sources.len(), 1);
        Ok(())
    }
    #[cfg(windows)]
    #[tokio::test]
    async fn file_replacement_failure_does_not_change_runtime_registration() -> Result<()> {
        use std::os::windows::fs::OpenOptionsExt;
        let (_directory, manager) = fixture()?;
        let cancel = HttpCancellation::new();
        manager
            .install(code("1.0.0"), "sample.js".into(), &cancel)
            .await?;
        let path = manager.find("sample")?.file_path;
        let locked = fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&path)?;
        assert!(manager
            .save("sample".into(), code("2.0.0"), &cancel)
            .await
            .is_err());
        assert_eq!(version(&manager)?, "1.0.0");
        assert_eq!(
            evaluate(
                &manager.engine,
                "ComicSource.sources.sample.comic.loadInfo().title"
            )?,
            "usable"
        );
        drop(locked);
        assert_eq!(manager.read("sample")?, code("1.0.0"));
        assert_eq!(fs::read_dir(&manager.directory)?.count(), 1);
        Ok(())
    }
}
