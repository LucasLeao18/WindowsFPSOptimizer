//! Point-in-time, read-only process inventory. Names and PIDs may become stale.
#[derive(Debug, Clone)]
pub struct Process {
    pub pid: u32,
    pub name: String,
    pub threads: u32,
    pub identity: Option<crate::session::ProcessIdentity>,
}

#[derive(Debug, Clone)]
pub struct Inventory {
    pub processes: Vec<Process>,
    pub truncated: bool,
}

#[cfg(windows)]
pub fn collect() -> Result<Inventory, String> {
    use windows_sys::Win32::{
        Foundation::{
            CloseHandle, ERROR_NO_MORE_FILES, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
        },
        System::Diagnostics::ToolHelp::*,
    };
    struct Snapshot(HANDLE);
    impl Drop for Snapshot {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    let raw = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if raw == INVALID_HANDLE_VALUE {
        return Err(format!(
            "Não foi possível listar os processos: {}",
            std::io::Error::last_os_error()
        ));
    }
    let snapshot = Snapshot(raw);
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut result = Inventory {
        processes: Vec::new(),
        truncated: false,
    };
    let mut ok = unsafe { Process32FirstW(snapshot.0, &mut entry) };
    while ok != 0 {
        if result.processes.len() == 8192 {
            result.truncated = true;
            break;
        }
        let end = entry
            .szExeFile
            .iter()
            .position(|c| *c == 0)
            .unwrap_or(entry.szExeFile.len());
        result.processes.push(Process {
            pid: entry.th32ProcessID,
            name: String::from_utf16_lossy(&entry.szExeFile[..end]),
            threads: entry.cntThreads,
            identity: crate::windows_process::identity(entry.th32ProcessID).ok(),
        });
        ok = unsafe { Process32NextW(snapshot.0, &mut entry) };
    }
    if !result.truncated && unsafe { GetLastError() } != ERROR_NO_MORE_FILES {
        return Err(format!(
            "A lista de processos está incompleta: {}",
            std::io::Error::last_os_error()
        ));
    }
    result
        .processes
        .sort_by_cached_key(|p| (p.name.to_lowercase(), p.pid));
    Ok(result)
}

#[cfg(not(windows))]
pub fn collect() -> Result<Inventory, String> {
    Err("Esta opção requer Windows.".into())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    #[test]
    fn snapshot_includes_the_test_process() {
        let snapshot = collect().unwrap();
        assert!(
            snapshot
                .processes
                .iter()
                .any(|p| p.pid == std::process::id() && !p.name.is_empty())
        );
    }
}
