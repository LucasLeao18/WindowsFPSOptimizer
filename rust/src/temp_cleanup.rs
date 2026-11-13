//! Explicit cleanup of previously inspected direct files in the user's Temp.
//! Handles prevent rename/write races; reparse points and subfolders are skipped.
use std::{
    ffi::OsString,
    fs,
    os::windows::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf, Prefix},
    ptr,
    time::{Duration, SystemTime},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE},
    Storage::FileSystem::*,
    System::Com::CoTaskMemFree,
    UI::Shell::{FOLDERID_LocalAppData, SHGetKnownFolderPath},
};

const MAX_ENTRIES: usize = 100_000;
const MAX_FILES: usize = 10_000;
const WEEK: Duration = Duration::from_secs(7 * 24 * 60 * 60);

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Identity {
    volume: u32,
    index: u64,
    created: u64,
    modified: u64,
    size: u64,
}
#[derive(Clone, Debug)]
struct Candidate {
    name: OsString,
    identity: Identity,
}
#[derive(Clone, Debug)]
pub struct Plan {
    root: PathBuf,
    root_id: Identity,
    files: Vec<Candidate>,
    pub bytes: u64,
    pub skipped: u64,
    pub truncated: bool,
}
impl Plan {
    pub fn files(&self) -> usize {
        self.files.len()
    }
    pub fn folder(&self) -> &Path {
        &self.root
    }
}
#[derive(Default, Debug)]
pub struct Report {
    pub marked: u64,
    pub bytes: u64,
    pub skipped: u64,
}

fn wide(path: &Path) -> Result<Vec<u16>, String> {
    let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
    if value.contains(&0) {
        return Err("Caminho inválido.".into());
    }
    value.push(0);
    Ok(value)
}
fn open(path: &Path, access: u32, share: u32, directory: bool) -> Result<Handle, String> {
    let flags = FILE_FLAG_OPEN_REPARSE_POINT
        | if directory {
            FILE_FLAG_BACKUP_SEMANTICS
        } else {
            0
        };
    let raw = unsafe {
        CreateFileW(
            wide(path)?.as_ptr(),
            access,
            share,
            ptr::null(),
            OPEN_EXISTING,
            flags,
            ptr::null_mut(),
        )
    };
    if raw == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(Handle(raw))
}
fn info(handle: &Handle) -> Result<(Identity, u32), String> {
    let mut value = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(handle.0, &mut value) } == 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let pair = |high: u32, low: u32| (u64::from(high) << 32) | u64::from(low);
    Ok((
        Identity {
            volume: value.dwVolumeSerialNumber,
            index: pair(value.nFileIndexHigh, value.nFileIndexLow),
            created: pair(
                value.ftCreationTime.dwHighDateTime,
                value.ftCreationTime.dwLowDateTime,
            ),
            modified: pair(
                value.ftLastWriteTime.dwHighDateTime,
                value.ftLastWriteTime.dwLowDateTime,
            ),
            size: pair(value.nFileSizeHigh, value.nFileSizeLow),
        },
        value.dwFileAttributes,
    ))
}
fn final_path(handle: &Handle) -> Result<PathBuf, String> {
    let mut buffer = vec![0u16; 32768];
    let n =
        unsafe { GetFinalPathNameByHandleW(handle.0, buffer.as_mut_ptr(), buffer.len() as u32, 0) }
            as usize;
    if n == 0 || n >= buffer.len() {
        return Err("Não foi possível confirmar o caminho do arquivo.".into());
    }
    Ok(PathBuf::from(OsString::from_wide(&buffer[..n])))
}
fn local(path: &Path) -> bool {
    matches!(path.components().next(), Some(std::path::Component::Prefix(prefix)) if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_)))
}
fn same_path(a: &Path, b: &Path) -> bool {
    match (a.to_str(), b.to_str()) {
        (Some(a), Some(b)) => a.to_lowercase() == b.to_lowercase(),
        _ => false,
    }
}
fn root_handle(root: &Path) -> Result<(Handle, Identity, PathBuf), String> {
    let handle = open(
        root,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        true,
    )?;
    let (id, flags) = info(&handle)?;
    let path = final_path(&handle)?;
    if id.index == 0
        || flags & FILE_ATTRIBUTE_DIRECTORY == 0
        || flags & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || !local(&path)
    {
        return Err("A pasta temporária não é uma pasta local comum.".into());
    }
    Ok((handle, id, path))
}
fn direct_file(handle: &Handle, root: &Path) -> Result<Identity, String> {
    let (id, flags) = info(handle)?;
    if flags & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) != 0 || id.index == 0 {
        return Err("Item não é um arquivo comum.".into());
    }
    let path = final_path(handle)?;
    if !path.parent().is_some_and(|parent| same_path(parent, root)) {
        return Err("Arquivo fora da pasta temporária.".into());
    }
    Ok(id)
}
fn cutoff(now: SystemTime, age: Duration) -> Result<u64, String> {
    let instant = now
        .checked_sub(age)
        .ok_or("Data inválida.")?
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(|_| "Data inválida.")?;
    (instant
        .as_secs()
        .checked_add(11_644_473_600)
        .and_then(|s| s.checked_mul(10_000_000))
        .and_then(|v| v.checked_add(u64::from(instant.subsec_nanos() / 100))))
    .ok_or("Data inválida.".into())
}
fn plan_at(root: &Path, age: Duration, now: SystemTime) -> Result<Plan, String> {
    let (_root_guard, root_id, root) = root_handle(root)
        .map_err(|e| format!("Não foi possível verificar a pasta temporária: {e}"))?;
    let cutoff = cutoff(now, age)?;
    let mut plan = Plan {
        root: root.clone(),
        root_id,
        files: Vec::new(),
        bytes: 0,
        skipped: 0,
        truncated: false,
    };
    let entries = fs::read_dir(&root)
        .map_err(|e| format!("Não foi possível listar a pasta temporária: {e}"))?;
    for (index, entry) in entries.enumerate() {
        if index >= MAX_ENTRIES || plan.files.len() >= MAX_FILES {
            plan.truncated = true;
            break;
        }
        let Ok(entry) = entry else {
            plan.skipped += 1;
            continue;
        };
        let Ok(handle) = open(
            &entry.path(),
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            false,
        ) else {
            plan.skipped += 1;
            continue;
        };
        let Ok(identity) = direct_file(&handle, &root) else {
            plan.skipped += 1;
            continue;
        };
        if identity.modified <= cutoff {
            plan.bytes = plan.bytes.saturating_add(identity.size);
            plan.files.push(Candidate {
                name: entry.file_name(),
                identity,
            });
        }
    }
    Ok(plan)
}
fn user_root() -> Result<PathBuf, String> {
    let mut raw = ptr::null_mut();
    let status =
        unsafe { SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, ptr::null_mut(), &mut raw) };
    if status < 0 || raw.is_null() {
        if !raw.is_null() {
            unsafe {
                CoTaskMemFree(raw.cast());
            }
        }
        return Err("A pasta local do usuário está indisponível.".into());
    }
    let mut len = 0usize;
    while len < 32768 && unsafe { *raw.add(len) } != 0 {
        len += 1;
    }
    let path = if len == 32768 {
        Err("Caminho local inválido.".into())
    } else {
        Ok(PathBuf::from(OsString::from_wide(unsafe {
            std::slice::from_raw_parts(raw, len)
        }))
        .join("Temp"))
    };
    unsafe {
        CoTaskMemFree(raw.cast());
    }
    path
}
pub fn plan_user_temp() -> Result<Plan, String> {
    plan_at(&user_root()?, WEEK, SystemTime::now())
}

/// Deletes only identities recorded in the preview, after rechecking the root and file.
pub fn apply(plan: &Plan) -> Result<Report, String> {
    let (_root_guard, id, root) = root_handle(&plan.root)?;
    if id.volume != plan.root_id.volume
        || id.index != plan.root_id.index
        || id.created != plan.root_id.created
        || !same_path(&root, &plan.root)
    {
        return Err(
            "A pasta temporária mudou desde a análise; nenhuma remoção foi iniciada.".into(),
        );
    }
    let mut report = Report::default();
    for candidate in &plan.files {
        let path = root.join(&candidate.name);
        let Ok(handle) = open(&path, DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, false) else {
            report.skipped += 1;
            continue;
        };
        if direct_file(&handle, &root).ok() != Some(candidate.identity) {
            report.skipped += 1;
            continue;
        }
        let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
        if unsafe {
            SetFileInformationByHandle(
                handle.0,
                FileDispositionInfo,
                (&disposition as *const FILE_DISPOSITION_INFO).cast(),
                std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32,
            )
        } == 0
        {
            report.skipped += 1;
            continue;
        }
        report.marked += 1;
        report.bytes = report.bytes.saturating_add(candidate.identity.size);
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn remove_fixture(path: &Path) {
        let target =
            fs::canonicalize(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target")).unwrap();
        let resolved = fs::canonicalize(path).unwrap();
        assert_eq!(resolved.parent(), Some(target.as_path()));
        fs::remove_dir_all(resolved).unwrap();
    }
    #[test]
    #[ignore = "Read-only scan of the current user's Temp folder"]
    fn user_temp_preview_is_read_only() {
        let plan = plan_user_temp().unwrap();
        assert!(plan.files() <= MAX_FILES);
    }
    #[test]
    fn only_unchanged_direct_fixture_files_are_removed() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("cleanup-fixture-{unique}"));
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("old"), b"abc").unwrap();
        fs::write(root.join("changed"), b"first").unwrap();
        fs::write(root.join("in-use"), b"locked").unwrap();
        fs::write(root.join("replaced"), b"same").unwrap();
        fs::write(root.join("nested").join("keep"), b"keep").unwrap();
        let linked =
            std::os::windows::fs::symlink_file(root.join("nested").join("keep"), root.join("link"))
                .is_ok();
        let plan = plan_at(
            &root,
            Duration::ZERO,
            SystemTime::now() + Duration::from_secs(1),
        )
        .unwrap();
        assert_eq!(plan.files(), 4);
        let _busy = fs::OpenOptions::new()
            .write(true)
            .open(root.join("in-use"))
            .unwrap();
        fs::write(root.join("changed"), b"changed after preview").unwrap();
        fs::remove_file(root.join("replaced")).unwrap();
        fs::write(root.join("replaced"), b"same").unwrap();
        fs::write(root.join("new"), b"new").unwrap();
        let report = apply(&plan).unwrap();
        assert_eq!(report.marked, 1);
        assert_eq!(report.skipped, 3);
        assert!(!root.join("old").exists());
        assert!(root.join("in-use").exists());
        assert!(root.join("replaced").exists());
        if linked {
            assert!(root.join("link").exists());
        }
        drop(_busy);
        assert!(
            root.join("changed").exists()
                && root.join("new").exists()
                && root.join("nested").join("keep").exists()
        );
        remove_fixture(&root);
    }
    #[test]
    fn replaced_root_never_receives_cleanup() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let container = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("cleanup-root-fixture-{unique}"));
        let root = container.join("temp");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("item"), b"original").unwrap();
        let plan = plan_at(
            &root,
            Duration::ZERO,
            SystemTime::now() + Duration::from_secs(1),
        )
        .unwrap();
        fs::rename(&root, container.join("original")).unwrap();
        fs::create_dir(&root).unwrap();
        fs::write(root.join("item"), b"replacement").unwrap();
        assert!(apply(&plan).is_err());
        assert_eq!(fs::read(root.join("item")).unwrap(), b"replacement");
        assert_eq!(
            fs::read(container.join("original").join("item")).unwrap(),
            b"original"
        );
        remove_fixture(&container);
    }
}
