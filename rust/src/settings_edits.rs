use anyhow::{bail, ensure, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::LazyLock;

pub static DEFAULTS: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../settings_defaults.json")).expect("valid bundled settings")
});

#[derive(Deserialize)]
#[serde(
    tag = "scope",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Edit {
    Global {
        key: String,
        change: Change,
    },
    Comic {
        owner: String,
        edit: Option<ReaderEdit>,
    },
    Device {
        edit: Option<ReaderEdit>,
    },
    WebDav {
        previous: Value,
        previous_exclusions: String,
        config: Value,
        exclusions: String,
    },
    Search {
        keyword: Option<String>,
        remove: bool,
    },
}

#[derive(Deserialize)]
pub struct ReaderEdit {
    key: String,
    value: Value,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum Change {
    Set { value: Value },
    Reset,
    Add { value: String },
    Remove { value: String },
    Replace { previous: Value, value: Value },
}

fn validate_choice(value: &Value, choices: &[&str]) -> bool {
    value.as_str().is_some_and(|value| choices.contains(&value))
}

fn valid_source_list_url(value: &str) -> bool {
    url::Url::parse(value)
        .is_ok_and(|url| matches!(url.scheme(), "http" | "https") && url.has_host())
}

fn deprecated_source_list_url(value: &str) -> bool {
    url::Url::parse(value)
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
        .as_deref()
        == Some("git.nyne.dev")
}

/// Filters invalid or duplicate entries and replaces the retired mirror with
/// the bundled default repository.
fn normalized_source_list_urls(values: &[Value]) -> Vec<Value> {
    let fallback = DEFAULTS["comicSourceListUrl"].as_str().unwrap_or_default();
    let mut seen = HashSet::new();
    values
        .iter()
        .filter_map(Value::as_str)
        .filter(|value| valid_source_list_url(value))
        .map(|value| {
            if deprecated_source_list_url(value) {
                fallback
            } else {
                value
            }
        })
        .filter(|value| !value.is_empty() && seen.insert((*value).to_owned()))
        .map(|value| Value::String(value.to_owned()))
        .collect()
}

fn sync_legacy_source_list_url(settings: &mut Value) {
    let first = settings["comicSourceListUrls"]
        .as_array()
        .and_then(|values| values.first())
        .cloned()
        .unwrap_or_else(|| json!(""));
    settings["comicSourceListUrl"] = first;
}

pub fn valid(key: &str, value: &Value) -> bool {
    match key {
        "searchSources" => value.is_null() || strings(value),
        "defaultSearchTarget" | "quickFavorite" | "followUpdatesFolder" => {
            value.is_null() || value.is_string()
        }
        "explore_pages" | "categories" | "favorites" | "blockedWords" | "blockedCommentWords" => {
            strings(value)
        }
        "webdav" => value.as_array().is_some_and(|values| {
            values.is_empty()
                || (values.len() == 3
                    && strings(value)
                    && url::Url::parse(values[0].as_str().unwrap()).is_ok_and(|url| {
                        matches!(url.scheme(), "http" | "https") && url.has_host()
                    }))
        }),
        "comicSourceListUrl" => value
            .as_str()
            .is_some_and(|value| value.is_empty() || valid_source_list_url(value)),
        "comicSourceListUrls" => value.as_array().is_some_and(|values| {
            values
                .iter()
                .all(|value| value.as_str().is_some_and(valid_source_list_url))
        }),
        "proxy" => value.as_str().is_some_and(|value| {
            matches!(value, "system" | "direct") || {
                let address = if value.contains("://") {
                    value.to_owned()
                } else {
                    format!("http://{value}")
                };
                url::Url::parse(&address).is_ok_and(|url| {
                    matches!(
                        url.scheme(),
                        "http" | "https" | "socks4" | "socks4a" | "socks5" | "socks5h"
                    ) && url.has_host()
                        && matches!(url.path(), "" | "/")
                        && url.query().is_none()
                        && url.fragment().is_none()
                })
            }
        }),
        "dnsOverrides" => value.as_object().is_some_and(|overrides| {
            overrides
                .iter()
                .all(|(host, address)| valid_dns_override(host, address))
        }),
        "theme_mode" => validate_choice(value, &["system", "light", "dark"]),
        "language" => validate_choice(value, &["system", "zh-CN", "zh-TW", "en-US"]),
        "color" => validate_choice(
            value,
            &["system", "red", "pink", "purple", "green", "orange", "blue"],
        ),
        "comicDisplayMode" => validate_choice(value, &["detailed", "brief"]),
        "comicListDisplayMode" => validate_choice(value, &["paging", "Continuous"]),
        "initialPage" => validate_choice(value, &["0", "1", "2", "3"]),
        "quickCollectImage" => validate_choice(value, &["No", "DoubleTap", "Swipe"]),
        "autoAddLanguageFilter" => {
            validate_choice(value, &["none", "chinese", "english", "japanese"])
        }
        "newFavoriteAddTo" => validate_choice(value, &["start", "end"]),
        "moveFavoriteAfterRead" => validate_choice(value, &["none", "start", "end"]),
        "onClickFavorite" => validate_choice(value, &["viewDetail", "read"]),
        "longPressZoomPosition" => validate_choice(value, &["press", "center"]),
        "readerMode" => validate_choice(
            value,
            &[
                "galleryLeftToRight",
                "galleryRightToLeft",
                "galleryTopToBottom",
                "continuousLeftToRight",
                "continuousRightToLeft",
                "continuousTopToBottom",
            ],
        ),
        "autoPageTurningInterval" => value
            .as_u64()
            .is_some_and(|value| (1..=20).contains(&value)),
        "downloadThreads" => value
            .as_u64()
            .is_some_and(|value| (1..=16).contains(&value)),
        "readerScreenPicNumberForLandscape" | "readerScreenPicNumberForPortrait" => {
            value.as_u64().is_some_and(|value| (1..=5).contains(&value))
        }
        "readerScrollSpeed" => value
            .as_f64()
            .is_some_and(|value| (0.5..=3.0).contains(&value)),
        "comicTileScale" => value
            .as_f64()
            .is_some_and(|value| (0.5..=1.5).contains(&value)),
        // Floating-point slider output can be at the limits with small rounding errors.
        "cacheSize" | "preloadImageCount" | "dataVersion" => value.as_u64().is_some(),
        "comicSpecificSettings" | "deviceSpecificSettings" => value.is_object(),
        _ => DEFAULTS.get(key).is_some_and(|default| {
            (default.is_boolean() && value.is_boolean())
                || (default.is_string() && value.is_string())
                || (default.is_number() && value.is_number())
                || (default.is_object() && value.is_object())
                || (default.is_array() && value.is_array())
        }),
    }
}

fn valid_dns_override(host: &str, address: &Value) -> bool {
    !host.is_empty()
        && url::Host::parse(host).is_ok()
        && address
            .as_str()
            .is_some_and(|value| value.parse::<std::net::IpAddr>().is_ok())
}

fn strings(value: &Value) -> bool {
    value
        .as_array()
        .is_some_and(|values| values.iter().all(Value::is_string))
}

fn reader_key(key: &str) -> bool {
    matches!(
        key,
        "readerMode"
            | "autoPageTurningInterval"
            | "readerScreenPicNumberForLandscape"
            | "readerScreenPicNumberForPortrait"
            | "enableTapToTurnPages"
            | "reverseTapToTurnPages"
            | "enablePageAnimation"
            | "enableLongPressToZoom"
            | "longPressZoomPosition"
            | "limitImageWidth"
            | "enableTurnPageByVolumeKey"
            | "enableClockAndBatteryInfoInReader"
            | "quickCollectImage"
            | "preloadImageCount"
            | "showPageNumberInReader"
            | "showSingleImageOnFirstPage"
            | "enableDoubleTapToZoom"
            | "showSystemStatusBar"
            | "readerScrollSpeed"
            | "showChapterComments"
            | "showChapterCommentsAtEnd"
    )
}

fn normalize_override(value: &Value) -> Value {
    let mut owners = serde_json::Map::new();
    if let Some(value) = value.as_object() {
        for (owner, record) in value {
            let Some(record) = record.as_object() else {
                continue;
            };
            let fields = record
                .iter()
                .filter(|(key, value)| {
                    (key.as_str() == "enabled" && value.is_boolean())
                        || (reader_key(key) && valid(key, value))
                })
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect();
            owners.insert(owner.clone(), Value::Object(fields));
        }
    }
    Value::Object(owners)
}

pub fn normalized_value(key: &str, value: &Value) -> Option<Value> {
    match key {
        "comicSpecificSettings" | "deviceSpecificSettings" if value.is_object() => {
            Some(normalize_override(value))
        }
        "dnsOverrides" => Some(Value::Object(
            value
                .as_object()?
                .iter()
                .filter(|(host, address)| valid_dns_override(host, address))
                .map(|(host, address)| (host.clone(), address.clone()))
                .collect(),
        )),
        "searchSources"
        | "explore_pages"
        | "categories"
        | "favorites"
        | "blockedWords"
        | "blockedCommentWords"
            if value.is_array() =>
        {
            Some(Value::Array(
                value
                    .as_array()?
                    .iter()
                    .filter(|entry| entry.is_string())
                    .cloned()
                    .collect(),
            ))
        }
        "comicSourceListUrls" => Some(Value::Array(normalized_source_list_urls(value.as_array()?))),
        _ if DEFAULTS.get(key).is_none() || valid(key, value) => Some(value.clone()),
        _ => None,
    }
}

pub fn normalize(saved: &Value) -> Value {
    let mut restored = DEFAULTS.clone();
    let saved_object = saved.as_object();
    if let Some(saved) = saved_object {
        for (key, value) in saved {
            if let Some(value) = normalized_value(key, value) {
                restored[key] = value;
            }
        }
    }
    // Older versions stored a single repository. Seed the list from it unless
    // the saved data already contains an explicit list (even an empty one).
    let has_list = saved_object
        .and_then(|saved| saved.get("comicSourceListUrls"))
        .is_some_and(Value::is_array);
    if !has_list {
        let legacy = match saved_object.and_then(|saved| saved.get("comicSourceListUrl")) {
            Some(Value::String(value)) if value.is_empty() => String::new(),
            Some(Value::String(value)) if valid_source_list_url(value) => value.clone(),
            _ => DEFAULTS["comicSourceListUrl"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
        };
        restored["comicSourceListUrls"] =
            Value::Array(normalized_source_list_urls(&[Value::String(legacy)]));
    }
    // Keep the legacy single-value setting in step with the list so older
    // builds and older synced clients still see the primary repository.
    sync_legacy_source_list_url(&mut restored);
    restored
}

pub fn apply(data: &mut Value, edits: Vec<Edit>, strict: bool) -> Result<Vec<String>> {
    let mut rejected = Vec::new();
    for edit in edits {
        if let Err(error) = apply_one(data, edit) {
            if strict {
                return Err(error);
            }
            rejected.push(error.to_string());
        }
    }
    Ok(rejected)
}

fn apply_one(data: &mut Value, edit: Edit) -> Result<()> {
    match edit {
        Edit::Search { keyword, remove } => {
            let history = serde_json::from_value(data["searchHistory"].clone())?;
            data["searchHistory"] =
                json!(super::settings::search_history(history, keyword, remove));
        }
        Edit::Global { key, change } => change_global(&mut data["settings"], &key, change)?,
        Edit::WebDav {
            previous,
            previous_exclusions,
            config,
            exclusions,
        } => {
            let settings = &mut data["settings"];
            ensure!(
                settings["webdav"] == previous
                    && settings["disableSyncFields"] == previous_exclusions,
                "WebDAV configuration changed while editing"
            );
            ensure!(valid("webdav", &config), "Invalid WebDAV configuration");
            settings["webdav"] = config;
            settings["disableSyncFields"] = exclusions.into();
        }
        Edit::Comic { owner, edit } => {
            ensure!(!owner.is_empty(), "Missing comic key");
            change_reader(&mut data["settings"]["comicSpecificSettings"], &owner, edit)?;
        }
        Edit::Device { edit } => {
            let owner = data["settings"]["deviceId"]
                .as_str()
                .filter(|id| !id.is_empty())
                .context("Missing device identity")?
                .to_owned();
            change_reader(
                &mut data["settings"]["deviceSpecificSettings"],
                &owner,
                edit,
            )?;
        }
    }
    Ok(())
}

fn change_global(settings: &mut Value, key: &str, change: Change) -> Result<()> {
    ensure!(
        !matches!(
            key,
            "deviceId" | "dataVersion" | "comicSpecificSettings" | "deviceSpecificSettings"
        ),
        "Setting is managed by the backend: {key}"
    );
    let default = DEFAULTS
        .get(key)
        .with_context(|| format!("Unknown setting: {key}"))?;
    let value = match change {
        Change::Set { value } => {
            ensure!(
                !value.is_array() && !value.is_object(),
                "Use a collection edit for {key}"
            );
            ensure!(
                !settings[key].is_array() && !settings[key].is_object(),
                "Use a collection edit for {key}"
            );
            value
        }
        Change::Reset => default.clone(),
        Change::Replace { previous, value } => {
            ensure!(
                settings[key] == previous || settings[key] == value,
                "Setting changed while editing: {key}"
            );
            value
        }
        Change::Add { value } => {
            let item = match key {
                "blockedWords" | "blockedCommentWords" => {
                    ensure!(!value.trim().is_empty(), "Invalid blocked word");
                    Value::String(value)
                }
                "comicSourceListUrls" => {
                    ensure!(valid_source_list_url(&value), "Invalid source list URL");
                    Value::String(value)
                }
                _ => bail!("Invalid list setting"),
            };
            let list = settings[key]
                .as_array_mut()
                .context("Setting is not a list")?;
            if !list.contains(&item) {
                list.push(item);
            }
            sync_legacy_source_list_url(settings);
            return Ok(());
        }
        Change::Remove { value } => {
            ensure!(
                matches!(
                    key,
                    "blockedWords" | "blockedCommentWords" | "comicSourceListUrls"
                ),
                "Invalid list setting"
            );
            settings[key]
                .as_array_mut()
                .context("Setting is not a list")?
                .retain(|item| item.as_str() != Some(&value));
            sync_legacy_source_list_url(settings);
            return Ok(());
        }
    };
    ensure!(valid(key, &value), "Invalid value for {key}");
    settings[key] = value;
    apply_reader_dependencies(settings, key);
    if key == "comicSourceListUrls" {
        sync_legacy_source_list_url(settings);
    }
    Ok(())
}

fn change_reader(settings: &mut Value, owner: &str, edit: Option<ReaderEdit>) -> Result<()> {
    let owners = settings
        .as_object_mut()
        .context("Invalid reader settings")?;
    let Some(ReaderEdit { key, value }) = edit else {
        owners.remove(owner);
        return Ok(());
    };
    let valid = if key == "enabled" {
        value.is_boolean()
    } else {
        reader_key(&key) && valid(&key, &value)
    };
    if !valid {
        bail!("Invalid reader setting: {key}");
    }
    let record = owners.entry(owner).or_insert_with(|| json!({}));
    record[&key] = value;
    apply_reader_dependencies(record, &key);
    Ok(())
}

fn apply_reader_dependencies(settings: &mut Value, key: &str) {
    match key {
        "readerMode"
            if settings[key]
                .as_str()
                .is_some_and(|mode| mode.starts_with("continuous")) =>
        {
            settings["readerScreenPicNumberForLandscape"] = json!(1);
            settings["readerScreenPicNumberForPortrait"] = json!(1);
        }
        "showChapterComments" if settings[key] == false => {
            settings["showChapterCommentsAtEnd"] = json!(false);
        }
        _ => {}
    }
}
