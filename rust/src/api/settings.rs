use anyhow::Result;
use serde_json::{json, Value};

#[flutter_rust_bridge::frb(sync)]
pub fn default_settings_json() -> String {
    crate::settings_edits::DEFAULTS.to_string()
}

pub fn load_app_data(directory: String) -> Result<String> {
    let _storage = crate::backup_storage::access();
    Ok(crate::settings::load(&directory)?.to_string())
}

/// Apply the intents to a UI snapshot immediately. Disk writes reapply them
/// against the latest saved state and return its canonical value.
#[flutter_rust_bridge::frb(sync)]
pub fn preview_app_data_edits(
    data_json: String,
    edits_json: String,
    strict: bool,
) -> Result<String> {
    let mut data: Value = serde_json::from_str(&data_json)?;
    let rejected =
        crate::settings_edits::apply(&mut data, serde_json::from_str(&edits_json)?, strict)?;
    Ok(json!({"data":data,"rejected":rejected}).to_string())
}

pub fn apply_app_data_edits(directory: String, edits_json: String) -> Result<String> {
    let _storage = crate::backup_storage::access();
    crate::settings::edit(&directory, serde_json::from_str(&edits_json)?)
}

pub fn apply_implicit_data_edits(directory: String, changes_json: String) -> Result<String> {
    let _storage = crate::backup_storage::access();
    crate::settings::edit_implicit(&directory, serde_json::from_str(&changes_json)?)
}

#[flutter_rust_bridge::frb(sync)]
pub fn reader_setting(
    settings_json: String,
    comic_key: Option<String>,
    key: String,
) -> Result<String> {
    let settings = serde_json::from_str(&settings_json)?;
    Ok(crate::settings::reader_setting(&settings, comic_key.as_deref(), &key).to_string())
}
