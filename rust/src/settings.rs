use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{fs, io::Write, path::Path, sync::Mutex};

// Serializes writes within this process, including callers on FRB's worker pool.
static WRITES: Mutex<()> = Mutex::new(());
const DEVICE_ONLY: &[&str] = &[
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
];

fn atomic_json(path: &Path, data: &Value) -> Result<()> {
    let parent = path.parent().context("settings path has no parent")?;
    fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer(file.as_file_mut(), data)?;
    file.as_file_mut().flush()?;
    file.as_file_mut().sync_all()?;
    file.persist(path)?;
    Ok(())
}

fn read_optional(path: &Path) -> Result<Option<Value>> {
    match fs::read(path) {
        Ok(bytes) => {
            Ok(Some(serde_json::from_slice(&bytes).with_context(|| {
                format!("Invalid JSON in {}", path.display())
            })?))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

pub fn load(directory: &str) -> Result<Value> {
    let data =
        read_optional(&Path::new(directory).join("appdata.json"))?.unwrap_or_else(|| json!({}));
    let mut settings = crate::settings_edits::normalize(&data["settings"]);
    if settings["deviceId"].as_str().unwrap_or_default().is_empty() {
        settings["deviceId"] = uuid::Uuid::new_v4().to_string().into();
    }
    let history = data["searchHistory"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut implicit = load_implicit(directory)?;
    if !implicit["webdavAutoSync"].is_boolean() {
        implicit["webdavAutoSync"] = json!(settings["webdav"]
            .as_array()
            .is_some_and(|settings| !settings.is_empty()));
    }
    Ok(json!({ "settings":settings, "searchHistory": history, "implicitData": implicit }))
}

fn excluded(settings: &Value) -> Vec<String> {
    settings["disableSyncFields"]
        .as_str()
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

pub fn save(directory: &str, data: Value) -> Result<()> {
    let _guard = WRITES
        .lock()
        .map_err(|_| anyhow::anyhow!("settings lock poisoned"))?;
    save_locked(directory, data)
}

fn save_locked(directory: &str, mut data: Value) -> Result<()> {
    ensure!(
        data["settings"].is_object() && data["searchHistory"].is_array(),
        "Invalid appdata snapshot"
    );
    // A UI snapshot taken during a WebDAV upload must not rewind its revision.
    if let Some(previous) = read_optional(&Path::new(directory).join("appdata.json"))? {
        if let Some(version) = previous["settings"]["dataVersion"].as_u64() {
            if version > data["settings"]["dataVersion"].as_u64().unwrap_or(0) {
                data["settings"]["dataVersion"] = version.into();
            }
        }
    }
    // syncdata always exists, even with no custom exclusions.
    atomic_json(
        &Path::new(directory).join("syncdata.json"),
        &sync_snapshot(data.clone()),
    )?;
    atomic_json(&Path::new(directory).join("appdata.json"), &data)?;
    Ok(())
}

pub fn sync_snapshot(mut data: Value) -> Value {
    let exclusions = excluded(&data["settings"]);
    if let Some(settings) = data["settings"].as_object_mut() {
        for key in exclusions {
            if key != "dataVersion" {
                settings.remove(&key);
            }
        }
        for key in DEVICE_ONLY {
            settings.remove(*key);
        }
    }
    if let Some(data) = data.as_object_mut() {
        data.remove("implicitData");
    }
    data
}

pub fn advance_revision(directory: &str, webdav: &Value, version: u64) -> Result<()> {
    let _guard = WRITES
        .lock()
        .map_err(|_| anyhow::anyhow!("settings lock poisoned"))?;
    let mut data = load(directory)?;
    ensure!(
        &data["settings"]["webdav"] == webdav,
        "WebDAV configuration changed during upload"
    );
    if data["settings"]["dataVersion"].as_u64().unwrap_or(0) < version {
        data["settings"]["dataVersion"] = version.into();
        data.as_object_mut().unwrap().remove("implicitData");
        save_locked(directory, data)?;
    }
    Ok(())
}

pub fn edit(directory: &str, edits: Vec<crate::settings_edits::Edit>) -> Result<String> {
    let _guard = WRITES
        .lock()
        .map_err(|_| anyhow::anyhow!("settings lock poisoned"))?;
    let mut data = load(directory)?;
    let before = data.clone();
    let rejected = crate::settings_edits::apply(&mut data, edits, false)?;
    let root = Path::new(directory);
    let changed = data != before;
    let mut persisted = data.clone();
    persisted.as_object_mut().unwrap().remove("implicitData");
    if read_optional(&root.join("appdata.json"))?.as_ref() != Some(&persisted)
        || read_optional(&root.join("syncdata.json"))?.as_ref()
            != Some(&sync_snapshot(persisted.clone()))
    {
        save_locked(directory, persisted)?;
    }
    let mut implicit = load_implicit(directory)?;
    if !implicit["webdavAutoSync"].is_boolean() {
        implicit["webdavAutoSync"] = before["implicitData"]["webdavAutoSync"].clone();
        atomic_json(&root.join("implicitData.json"), &implicit)?;
        data["implicitData"] = implicit;
    }
    Ok(json!({"data":data,"changed":changed,"rejected":rejected}).to_string())
}

fn load_implicit(directory: &str) -> Result<Value> {
    let value = read_optional(&Path::new(directory).join("implicitData.json"))?
        .unwrap_or_else(|| json!({}));
    ensure!(value.is_object(), "Invalid implicit data");
    Ok(value)
}

pub fn edit_implicit(directory: &str, changes: serde_json::Map<String, Value>) -> Result<String> {
    let _guard = WRITES
        .lock()
        .map_err(|_| anyhow::anyhow!("settings lock poisoned"))?;
    if let Some(value) = changes.get("webdavAutoSync") {
        ensure!(
            value.is_null() || value.is_boolean(),
            "Invalid automatic WebDAV setting"
        );
    }
    let mut data = load_implicit(directory)?;
    data.as_object_mut().unwrap().extend(changes);
    atomic_json(&Path::new(directory).join("implicitData.json"), &data)?;
    Ok(data.to_string())
}

pub fn merge(mut current: Value, incoming: Value) -> Result<Value> {
    let excluded = excluded(&current["settings"]);
    let settings = current["settings"]
        .as_object_mut()
        .context("Invalid local settings")?;
    if let Some(incoming) = incoming["settings"].as_object() {
        for (key, value) in incoming {
            if !DEVICE_ONLY.contains(&key.as_str())
                && (key == "dataVersion" || !excluded.contains(key))
            {
                if let Some(value) = crate::settings_edits::normalized_value(key, value) {
                    settings.insert(key.clone(), value);
                }
            }
        }
    }
    current["settings"] = crate::settings_edits::normalize(&current["settings"]);
    if let Some(history) = incoming["searchHistory"].as_array() {
        current["searchHistory"] = history
            .iter()
            .filter(|value| value.is_string())
            .take(50)
            .cloned()
            .collect::<Vec<_>>()
            .into();
    }
    Ok(current)
}

pub fn search_history(
    mut history: Vec<String>,
    keyword: Option<String>,
    remove: bool,
) -> Vec<String> {
    let Some(keyword) = keyword else {
        return Vec::new();
    };
    history.retain(|item| item != &keyword);
    if !remove {
        history.insert(0, keyword);
        history.truncate(50);
    }
    history
}

pub fn reader_setting<'a>(settings: &'a Value, comic_key: Option<&str>, key: &str) -> &'a Value {
    if let Some(comic) = comic_key {
        let values = &settings["comicSpecificSettings"][comic];
        if values["enabled"] == true && !values[key].is_null() {
            return &values[key];
        }
    }
    if let Some(device) = settings["deviceId"].as_str().filter(|id| !id.is_empty()) {
        let values = &settings["deviceSpecificSettings"][device];
        if values["enabled"] == true && !values[key].is_null() {
            return &values[key];
        }
    }
    &settings[key]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persisted_settings_and_sync_exclusions() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let directory = temp.path().to_str().unwrap();
        let loaded = load(directory)?;
        assert!(!loaded["settings"]["deviceId"].as_str().unwrap().is_empty());
        let local = json!({"settings":{"proxy":"local","deviceId":"device","theme_mode":"dark","disableSyncFields":"language, color","language":"zh-CN"},"searchHistory":["one"]});
        save(directory, local.clone())?;
        save(directory, local.clone())?;
        let sync = read_optional(&temp.path().join("syncdata.json"))?.unwrap();
        for key in ["language", "proxy", "deviceId", "disableSyncFields"] {
            assert!(
                sync["settings"].get(key).is_none(),
                "{key} must not be uploaded"
            );
        }
        assert_eq!(sync["settings"]["theme_mode"], "dark");
        let result = merge(
            local,
            json!({"settings":{"proxy":"remote","deviceId":"other","language":"en-US","theme_mode":"light"},"searchHistory":["two"]}),
        )?;
        assert_eq!(result["settings"]["proxy"], "local");
        assert_eq!(result["settings"]["language"], "zh-CN");
        assert_eq!(result["settings"]["theme_mode"], "light");
        assert_eq!(load(directory)?["settings"]["deviceId"], "device");
        Ok(())
    }

    #[test]
    fn legacy_settings_keep_valid_list_items_and_dns_entries() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let directory = temp.path().to_str().unwrap();
        atomic_json(
            &temp.path().join("appdata.json"),
            &json!({
                "settings": {
                    "blockedWords": ["keep", 123],
                    "dnsOverrides": {"valid.example": "127.0.0.1", "": ""},
                    "downloadThreads": "wrong type",
                    "legacyOption": true
                },
                "searchHistory": ["valid", null]
            }),
        )?;
        let loaded = load(directory)?;
        assert_eq!(loaded["settings"]["blockedWords"], json!(["keep"]));
        assert_eq!(
            loaded["settings"]["dnsOverrides"],
            json!({"valid.example": "127.0.0.1"})
        );
        assert_eq!(loaded["settings"]["downloadThreads"], 5);
        assert_eq!(loaded["settings"]["legacyOption"], true);
        assert_eq!(loaded["searchHistory"], json!(["valid"]));
        Ok(())
    }

    #[test]
    fn reader_edits_resolve_and_reset_in_scope_order() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let directory = temp.path().to_str().unwrap();
        let result: Value = serde_json::from_str(&edit(
            directory,
            serde_json::from_value(json!([
                {"scope":"global","key":"readerScreenPicNumberForPortrait","change":{"action":"set","value":2}},
                {"scope":"device","edit":{"key":"enabled","value":true}},
                {"scope":"device","edit":{"key":"readerScreenPicNumberForPortrait","value":3}},
                {"scope":"comic","owner":"c@s","edit":{"key":"enabled","value":true}},
                {"scope":"comic","owner":"c@s","edit":{"key":"readerScreenPicNumberForPortrait","value":4}}
            ]))?,
        )?)?;
        let key = "readerScreenPicNumberForPortrait";
        assert_eq!(
            reader_setting(&result["data"]["settings"], Some("c@s"), key),
            4
        );
        assert_eq!(
            reader_setting(&result["data"]["settings"], Some("other"), key),
            3
        );
        edit(
            directory,
            serde_json::from_value(json!([
                {"scope":"comic","owner":"c@s"}, {"scope":"device"}
            ]))?,
        )?;
        assert_eq!(
            reader_setting(&load(directory)?["settings"], Some("c@s"), key),
            2
        );
        assert_eq!(
            load(directory)?["settings"]["deviceId"],
            result["data"]["settings"]["deviceId"]
        );
        Ok(())
    }

    #[test]
    fn reader_precedence_and_search_limit() {
        let settings = json!({"x":1,"deviceId":"d","deviceSpecificSettings":{"d":{"enabled":true,"x":2}},"comicSpecificSettings":{"c@s":{"enabled":true,"x":3}}});
        assert_eq!(reader_setting(&settings, Some("c@s"), "x"), 3);
        assert_eq!(reader_setting(&settings, Some("other"), "x"), 2);
        let history = search_history(
            (0..60).map(|i| i.to_string()).collect(),
            Some("10".into()),
            false,
        );
        assert_eq!(history.len(), 50);
        assert_eq!(history[0], "10");
        assert_eq!(history.iter().filter(|s| *s == "10").count(), 1);
    }
}
