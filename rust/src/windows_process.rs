//! Native process identity and priority adapter; no shell or command scripts.
use crate::session::{Priority, ProcessBackend, ProcessIdentity};
use std::io;
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, ERROR_INVALID_PARAMETER, FILETIME, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT,
    },
    System::Threading::*,
};

/// Start exactly the selected executable without a command interpreter. If the
/// game delegates to a launcher, only this original process is managed.
pub fn launch(path: &std::path::Path) -> Result<ProcessIdentity, String> {
    if !path.is_absolute()
        || !path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("exe"))
    {
        return Err("Selecione um arquivo .exe com caminho absoluto.".into());
    }
    if !path.is_file() {
        return Err("O executável selecionado não está disponível.".into());
    }
    let parent = path.parent().ok_or("Pasta do jogo inválida.")?;
    let child = std::process::Command::new(path)
        .current_dir(parent)
        .spawn()
        .map_err(|e| format!("Não foi possível iniciar o jogo: {e}"))?;
    identity(child.id()).map_err(|e| {
        format!("O executável foi iniciado, mas não foi possível acompanhar seu processo: {e}")
    })
}

pub struct WindowsProcess;
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn open(pid: u32, write: bool) -> Result<Option<Handle>, String> {
    let access = PROCESS_QUERY_LIMITED_INFORMATION
        | PROCESS_SYNCHRONIZE
        | if write { PROCESS_SET_INFORMATION } else { 0 };
    let handle = unsafe { OpenProcess(access, 0, pid) };
    if handle.is_null() {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32) {
            return Ok(None);
        }
        return Err(format!("Não foi possível acessar o processo: {error}"));
    }
    Ok(Some(Handle(handle)))
}

fn creation(handle: &Handle) -> Result<u64, String> {
    let mut created = FILETIME::default();
    let mut exited = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    if unsafe { GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user) } == 0
    {
        return Err(format!(
            "Não foi possível identificar o processo: {}",
            io::Error::last_os_error()
        ));
    }
    Ok(((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64)
}

fn alive(handle: &Handle) -> Result<bool, String> {
    match unsafe { WaitForSingleObject(handle.0, 0) } {
        WAIT_OBJECT_0 => Ok(false),
        WAIT_TIMEOUT => Ok(true),
        _ => Err(format!(
            "Não foi possível consultar o processo: {}",
            io::Error::last_os_error()
        )),
    }
}

pub fn identity(pid: u32) -> Result<ProcessIdentity, String> {
    let handle = open(pid, false)?.ok_or("O processo já terminou.")?;
    if !alive(&handle)? {
        return Err("O processo já terminou.".into());
    }
    Ok(ProcessIdentity {
        pid,
        created: creation(&handle)?,
    })
}

fn checked(process: ProcessIdentity, write: bool) -> Result<Option<Handle>, String> {
    let Some(handle) = open(process.pid, write)? else {
        return Ok(None);
    };
    if !alive(&handle)? || creation(&handle)? != process.created {
        return Ok(None);
    }
    Ok(Some(handle))
}

fn raw_priority(value: Priority) -> u32 {
    match value {
        Priority::Idle => IDLE_PRIORITY_CLASS,
        Priority::BelowNormal => BELOW_NORMAL_PRIORITY_CLASS,
        Priority::Normal => NORMAL_PRIORITY_CLASS,
        Priority::AboveNormal => ABOVE_NORMAL_PRIORITY_CLASS,
        Priority::High => HIGH_PRIORITY_CLASS,
        Priority::Realtime => REALTIME_PRIORITY_CLASS,
    }
}

impl ProcessBackend for WindowsProcess {
    fn priority(&mut self, process: ProcessIdentity) -> Result<Option<Priority>, String> {
        let Some(handle) = checked(process, false)? else {
            return Ok(None);
        };
        let raw = unsafe { GetPriorityClass(handle.0) };
        if raw == 0 {
            return Err(format!(
                "Não foi possível consultar a prioridade: {}",
                io::Error::last_os_error()
            ));
        }
        for value in [
            Priority::Idle,
            Priority::BelowNormal,
            Priority::Normal,
            Priority::AboveNormal,
            Priority::High,
            Priority::Realtime,
        ] {
            if raw_priority(value) == raw {
                return Ok(Some(value));
            }
        }
        Err("A prioridade atual não é reconhecida; nenhuma mudança será feita.".into())
    }
    fn set_priority(
        &mut self,
        process: ProcessIdentity,
        expected: Priority,
        priority: Priority,
    ) -> Result<(), String> {
        let handle = checked(process, true)?.ok_or("O processo já terminou ou foi substituído.")?;
        if unsafe { GetPriorityClass(handle.0) } != raw_priority(expected) {
            return Err("A prioridade mudou antes da gravação.".into());
        }
        if unsafe { SetPriorityClass(handle.0, raw_priority(priority)) } == 0 {
            return Err(format!(
                "Não foi possível alterar a prioridade: {}",
                io::Error::last_os_error()
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identifies_current_process_and_rejects_reused_identity() {
        let actual = identity(std::process::id()).unwrap();
        assert!(WindowsProcess.priority(actual).unwrap().is_some());
        let stale = ProcessIdentity {
            created: actual.created ^ 1,
            ..actual
        };
        assert_eq!(WindowsProcess.priority(stale).unwrap(), None);
        assert!(
            WindowsProcess
                .set_priority(stale, Priority::Normal, Priority::Normal)
                .is_err()
        );
    }
    #[test]
    #[ignore = "Temporarily changes only this isolated test process's priority"]
    fn changes_and_restores_own_process_priority() {
        let process = identity(std::process::id()).unwrap();
        let mut backend = WindowsProcess;
        let original = backend.priority(process).unwrap().unwrap();
        assert!(matches!(
            original,
            Priority::Idle | Priority::BelowNormal | Priority::Normal
        ));
        struct Guard(ProcessIdentity, Priority);
        impl Drop for Guard {
            fn drop(&mut self) {
                let _ = WindowsProcess.set_priority(self.0, Priority::AboveNormal, self.1);
            }
        }
        let _guard = Guard(process, original);
        backend
            .set_priority(process, original, Priority::AboveNormal)
            .unwrap();
        assert_eq!(
            backend.priority(process).unwrap(),
            Some(Priority::AboveNormal)
        );
        backend
            .set_priority(process, Priority::AboveNormal, original)
            .unwrap();
        assert_eq!(backend.priority(process).unwrap(), Some(original));
    }

    #[test]
    #[ignore = "Temporarily changes only this isolated test process's priority"]
    fn recovers_priority_from_a_reopened_journal() {
        use crate::{
            session::{self, EndResult},
            storage::FileStore,
        };
        let process = identity(std::process::id()).unwrap();
        let mut backend = WindowsProcess;
        let original = backend.priority(process).unwrap().unwrap();
        assert!(matches!(
            original,
            Priority::Idle | Priority::BelowNormal | Priority::Normal
        ));
        struct Guard(ProcessIdentity, Priority);
        impl Drop for Guard {
            fn drop(&mut self) {
                let _ = WindowsProcess.set_priority(self.0, Priority::AboveNormal, self.1);
            }
        }
        let _guard = Guard(process, original);
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("session-recovery-{unique}"));
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            session::begin(&mut backend, &mut store, process).unwrap();
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                session::end(&mut backend, &mut store).unwrap(),
                EndResult::Restored
            );
        }
        assert_eq!(backend.priority(process).unwrap(), Some(original));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    #[ignore = "Requires an explicitly built isolated game fixture"]
    fn launches_fixture_and_restores_session() {
        use crate::{
            session::{self, EndResult},
            storage::FileStore,
        };
        let path = std::env::var_os("WFO_TEST_GAME")
            .expect("set WFO_TEST_GAME to the test fixture executable");
        let process = launch(std::path::Path::new(&path)).unwrap();
        let mut backend = WindowsProcess;
        let original = backend.priority(process).unwrap().unwrap();
        assert!(matches!(
            original,
            Priority::Idle | Priority::BelowNormal | Priority::Normal
        ));
        struct Guard(ProcessIdentity, Priority);
        impl Drop for Guard {
            fn drop(&mut self) {
                let _ = WindowsProcess.set_priority(self.0, Priority::AboveNormal, self.1);
            }
        }
        let _guard = Guard(process, original);
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("session-launch-{unique}"));
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            session::begin(&mut backend, &mut store, process).unwrap();
            assert_eq!(
                backend.priority(process).unwrap(),
                Some(Priority::AboveNormal)
            );
            assert_eq!(
                session::end(&mut backend, &mut store).unwrap(),
                EndResult::Restored
            );
            assert_eq!(backend.priority(process).unwrap(), Some(original));
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
