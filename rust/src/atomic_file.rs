use anyhow::{Context, Result};
use serde::Serialize;
use std::{io::Write, path::Path};
use tempfile::NamedTempFile;

pub(crate) fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    write(path, &serde_json::to_vec(value)?)
}

pub(crate) fn write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)?;
    let mut temporary = NamedTempFile::new_in(parent)?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    persist(temporary, path)
}

pub(crate) fn persist(mut temporary: NamedTempFile, path: &Path) -> Result<()> {
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
                return Err(error).with_context(|| format!("Cannot replace {}", path.display()));
            }
        }
    }
    unreachable!()
}
