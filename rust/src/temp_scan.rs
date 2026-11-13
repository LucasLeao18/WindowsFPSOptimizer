//! Read-only estimate of old files directly in the user's Temp folder.
//! Subfolders and reparse points are deliberately not traversed.
use std::{
    fs,
    path::Path,
    time::{Duration, SystemTime},
};

const MAX_ENTRIES: usize = 100_000;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Estimate {
    pub files: u64,
    pub bytes: u64,
    pub skipped: u64,
    pub truncated: bool,
}

#[cfg(windows)]
fn is_reparse(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    metadata.file_attributes() & 0x400 != 0
}
#[cfg(not(windows))]
fn is_reparse(metadata: &fs::Metadata) -> bool {
    metadata.file_type().is_symlink()
}

pub fn estimate(root: &Path, age: Duration, now: SystemTime) -> Result<Estimate, String> {
    let metadata = fs::symlink_metadata(root)
        .map_err(|e| format!("Não foi possível acessar a pasta temporária: {e}"))?;
    if !metadata.is_dir() || is_reparse(&metadata) {
        return Err("A pasta temporária não é uma pasta local comum.".into());
    }
    let entries = fs::read_dir(root)
        .map_err(|e| format!("Não foi possível listar a pasta temporária: {e}"))?;
    let mut estimate = Estimate::default();
    for (index, entry) in entries.enumerate() {
        if index >= MAX_ENTRIES {
            estimate.truncated = true;
            break;
        }
        let Ok(entry) = entry else {
            estimate.skipped += 1;
            continue;
        };
        let Ok(metadata) = fs::symlink_metadata(entry.path()) else {
            estimate.skipped += 1;
            continue;
        };
        if !metadata.is_file() || is_reparse(&metadata) {
            continue;
        }
        let Ok(modified) = metadata.modified() else {
            estimate.skipped += 1;
            continue;
        };
        if now
            .duration_since(modified)
            .is_ok_and(|elapsed| elapsed >= age)
        {
            estimate.files = estimate.files.saturating_add(1);
            estimate.bytes = estimate.bytes.saturating_add(metadata.len());
        }
    }
    Ok(estimate)
}

#[cfg(windows)]
pub fn estimate_user_temp() -> Result<Estimate, String> {
    let local = std::env::var_os("LOCALAPPDATA")
        .filter(|s| !s.is_empty())
        .ok_or("A pasta local do usuário está indisponível.")?;
    let root = std::path::PathBuf::from(local);
    if !root.is_absolute() || root.to_string_lossy().starts_with(r"\\") {
        return Err("A pasta temporária precisa estar em uma unidade local.".into());
    }
    estimate(
        &root.join("Temp"),
        Duration::from_secs(7 * 24 * 60 * 60),
        SystemTime::now(),
    )
}

#[cfg(not(windows))]
pub fn estimate_user_temp() -> Result<Estimate, String> {
    Err("Esta opção requer Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn counts_only_old_direct_files_and_never_visits_subfolders() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("temp-scan-{unique}"));
        fs::create_dir_all(root.join("subfolder")).unwrap();
        fs::write(root.join("direct"), b"abc").unwrap();
        fs::write(root.join("subfolder").join("nested"), b"hidden").unwrap();
        let now = SystemTime::now() + Duration::from_secs(8 * 24 * 60 * 60);
        let result = estimate(&root, Duration::from_secs(7 * 24 * 60 * 60), now).unwrap();
        assert_eq!(result.files, 1);
        assert_eq!(result.bytes, 3);
        fs::remove_dir_all(root).unwrap();
    }
}
