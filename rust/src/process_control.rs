//! Explicit, single-process termination with identity and protection checks.
//! Never used by automatic presets.
use crate::session::ProcessIdentity;
use std::{io, os::windows::ffi::OsStringExt, path::PathBuf, ptr};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, ERROR_INSUFFICIENT_BUFFER, ERROR_MORE_DATA, FILETIME, HANDLE, WAIT_OBJECT_0,
        WAIT_TIMEOUT,
    },
    Security::{
        EqualSid, GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TOKEN_USER, TokenElevation,
        TokenUser,
    },
    System::{Services::*, SystemInformation::GetWindowsDirectoryW, Threading::*},
};

#[derive(Debug, Clone)]
pub struct Candidate {
    pub identity: ProcessIdentity,
    pub path: PathBuf,
}
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Termination {
    Exited,
    Requested,
}

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
struct ServiceHandle(SC_HANDLE);
impl Drop for ServiceHandle {
    fn drop(&mut self) {
        unsafe {
            CloseServiceHandle(self.0);
        }
    }
}

fn process(identity: ProcessIdentity, terminate: bool) -> Result<Handle, String> {
    if identity.pid <= 4 || identity.pid == std::process::id() || identity.created == 0 {
        return Err("Este processo é protegido.".into());
    }
    let access = PROCESS_QUERY_LIMITED_INFORMATION
        | PROCESS_SYNCHRONIZE
        | if terminate { PROCESS_TERMINATE } else { 0 };
    let raw = unsafe { OpenProcess(access, 0, identity.pid) };
    if raw.is_null() {
        return Err(format!(
            "Não foi possível acessar o processo: {}",
            io::Error::last_os_error()
        ));
    }
    let handle = Handle(raw);
    let mut created = FILETIME::default();
    let mut exited = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    if unsafe { GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user) } == 0
    {
        return Err("Não foi possível confirmar a identidade do processo.".into());
    }
    let timestamp = ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64;
    if timestamp != identity.created || unsafe { WaitForSingleObject(handle.0, 0) } != WAIT_TIMEOUT
    {
        return Err("O processo terminou ou foi substituído. Atualize a lista.".into());
    }
    Ok(handle)
}

fn token_user(process: HANDLE) -> Result<Vec<usize>, String> {
    let mut token = ptr::null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err("Não foi possível verificar o proprietário do processo.".into());
    }
    let token = Handle(token);
    let mut length = 0u32;
    unsafe {
        GetTokenInformation(token.0, TokenUser, ptr::null_mut(), 0, &mut length);
    }
    if io::Error::last_os_error().raw_os_error() != Some(ERROR_INSUFFICIENT_BUFFER as i32)
        || length < std::mem::size_of::<TOKEN_USER>() as u32
        || length > 65_536
    {
        return Err("Não foi possível verificar o proprietário do processo.".into());
    }
    let mut buffer = vec![0usize; (length as usize).div_ceil(std::mem::size_of::<usize>())];
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            length,
            &mut length,
        )
    } == 0
    {
        return Err("Não foi possível verificar o proprietário do processo.".into());
    }
    Ok(buffer)
}

fn same_user(process: HANDLE) -> Result<bool, String> {
    let target = token_user(process)?;
    let current = token_user(unsafe { GetCurrentProcess() })?;
    let target = unsafe { &*(target.as_ptr().cast::<TOKEN_USER>()) };
    let current = unsafe { &*(current.as_ptr().cast::<TOKEN_USER>()) };
    Ok(unsafe { EqualSid(target.User.Sid, current.User.Sid) } != 0)
}

/// Whether this application runs with an elevated (administrator) token.
pub fn current_process_elevated() -> bool {
    is_elevated(unsafe { GetCurrentProcess() }).unwrap_or(false)
}

fn is_elevated(process: HANDLE) -> Result<bool, String> {
    let mut token = ptr::null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err("Não foi possível verificar o nível de acesso do processo.".into());
    }
    let token = Handle(token);
    let mut elevation = TOKEN_ELEVATION::default();
    let mut size = 0u32;
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenElevation,
            (&mut elevation as *mut TOKEN_ELEVATION).cast(),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        )
    } == 0
    {
        return Err("Não foi possível verificar o nível de acesso do processo.".into());
    }
    Ok(elevation.TokenIsElevated != 0)
}

fn image_path(handle: HANDLE) -> Result<PathBuf, String> {
    let mut buffer = vec![0u16; 32_768];
    let mut size = buffer.len() as u32;
    if unsafe { QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut size) } == 0
        || size == 0
        || size as usize > buffer.len()
    {
        return Err("Não foi possível verificar o executável do processo.".into());
    }
    Ok(PathBuf::from(std::ffi::OsString::from_wide(
        &buffer[..size as usize],
    )))
}

fn is_windows_image(path: &std::path::Path) -> Result<bool, String> {
    let mut buffer = vec![0u16; 32_768];
    let count = unsafe { GetWindowsDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if count == 0 || count >= buffer.len() {
        return Err("Não foi possível identificar a pasta do Windows.".into());
    }
    let root = PathBuf::from(std::ffi::OsString::from_wide(&buffer[..count]));
    let root =
        std::fs::canonicalize(root).map_err(|_| "A pasta do Windows não pôde ser verificada.")?;
    let root = root
        .to_str()
        .ok_or("A pasta do Windows não pôde ser verificada.")?
        .trim_end_matches(['\\', '/'])
        .to_lowercase();
    let path = path
        .to_str()
        .ok_or("O caminho do processo não pôde ser verificado.")?
        .replace('/', "\\")
        .to_lowercase();
    Ok(path == root || path.starts_with(&(root + "\\")))
}

fn protected_name(path: &std::path::Path) -> bool {
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_ascii_lowercase();
    [
        "explorer.exe",
        "taskmgr.exe",
        "dwm.exe",
        "sihost.exe",
        "csrss.exe",
        "lsass.exe",
        "winlogon.exe",
        "services.exe",
        "svchost.exe",
        "securityhealthsystray.exe",
        "msmpeng.exe",
        "antimalware service executable.exe",
        "easyanticheat.exe",
        "easyanticheat_eos.exe",
        "battleye.exe",
        "beservice.exe",
        "vgc.exe",
        "vgtray.exe",
    ]
    .contains(&name.as_str())
}

fn hosts_service(pid: u32) -> Result<bool, String> {
    let raw = unsafe { OpenSCManagerW(ptr::null(), ptr::null(), SC_MANAGER_ENUMERATE_SERVICE) };
    if raw.is_null() {
        return Err("Não foi possível verificar os serviços; o processo será preservado.".into());
    }
    let scm = ServiceHandle(raw);
    let mut needed = 0u32;
    let mut returned = 0u32;
    unsafe {
        EnumServicesStatusExW(
            scm.0,
            SC_ENUM_PROCESS_INFO,
            SERVICE_WIN32,
            SERVICE_STATE_ALL,
            ptr::null_mut(),
            0,
            &mut needed,
            &mut returned,
            ptr::null_mut(),
            ptr::null(),
        );
    }
    let error = io::Error::last_os_error().raw_os_error();
    if error != Some(ERROR_MORE_DATA as i32) && needed == 0 {
        return Err("Não foi possível verificar os serviços; o processo será preservado.".into());
    }
    for _ in 0..3 {
        if needed == 0 || needed > 8 * 1024 * 1024 {
            return Err("A lista de serviços é indisponível ou grande demais.".into());
        }
        let mut buffer = vec![0usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
        let capacity = (buffer.len() * std::mem::size_of::<usize>()) as u32;
        let mut next_needed = 0u32;
        let mut count = 0u32;
        let ok = unsafe {
            EnumServicesStatusExW(
                scm.0,
                SC_ENUM_PROCESS_INFO,
                SERVICE_WIN32,
                SERVICE_STATE_ALL,
                buffer.as_mut_ptr().cast(),
                capacity,
                &mut next_needed,
                &mut count,
                ptr::null_mut(),
                ptr::null(),
            )
        };
        if ok != 0 {
            if (count as usize)
                > (capacity as usize / std::mem::size_of::<ENUM_SERVICE_STATUS_PROCESSW>())
            {
                return Err("A lista de serviços é inválida.".into());
            }
            let entries = unsafe {
                std::slice::from_raw_parts(
                    buffer.as_ptr().cast::<ENUM_SERVICE_STATUS_PROCESSW>(),
                    count as usize,
                )
            };
            return Ok(entries
                .iter()
                .any(|entry| entry.ServiceStatusProcess.dwProcessId == pid));
        }
        if io::Error::last_os_error().raw_os_error() != Some(ERROR_MORE_DATA as i32) {
            return Err(
                "Não foi possível verificar os serviços; o processo será preservado.".into(),
            );
        }
        needed = capacity.saturating_add(next_needed).saturating_add(4096);
    }
    Err("A lista de serviços mudou durante a verificação. Tente novamente.".into())
}

fn check(handle: &Handle, identity: ProcessIdentity) -> Result<PathBuf, String> {
    let mut critical = 0i32;
    if unsafe { IsProcessCritical(handle.0, &mut critical) } == 0 || critical != 0 {
        return Err("O processo é crítico ou não pôde ser verificado.".into());
    }
    if !same_user(handle.0)? {
        return Err("Só é possível selecionar processos do usuário atual.".into());
    }
    if is_elevated(handle.0)? {
        return Err("Processos executados como administrador são protegidos.".into());
    }
    let path = image_path(handle.0)?;
    if !path.is_absolute() || protected_name(&path) {
        return Err("Este processo ou serviço é protegido pelo aplicativo.".into());
    }
    // Resolve aliases, short names and junctions before checking the Windows directory.
    // Failure to establish the real path must not permit a termination.
    let path = std::fs::canonicalize(path)
        .map_err(|_| "Não foi possível confirmar o caminho real do executável.")?;
    if !path.is_absolute()
        || protected_name(&path)
        || is_windows_image(&path)?
        || hosts_service(identity.pid)?
    {
        return Err("Este processo ou serviço é protegido pelo aplicativo.".into());
    }
    Ok(path)
}

/// Read-only inspection. The user must approve the returned process before termination.
pub fn inspect(identity: ProcessIdentity) -> Result<Candidate, String> {
    let handle = process(identity, false)?;
    Ok(Candidate {
        identity,
        path: check(&handle, identity)?,
    })
}

/// Rechecks identity and protection on the same process handle immediately before the request.
pub fn terminate(candidate: &Candidate) -> Result<Termination, String> {
    let handle = process(candidate.identity, true)?;
    if check(&handle, candidate.identity)? != candidate.path {
        return Err("O executável mudou desde a análise. Atualize a lista.".into());
    }
    if unsafe { TerminateProcess(handle.0, 1) } == 0 {
        return Err(format!(
            "Não foi possível encerrar o processo: {}",
            io::Error::last_os_error()
        ));
    }
    match unsafe { WaitForSingleObject(handle.0, 2_000) } {
        WAIT_OBJECT_0 => Ok(Termination::Exited),
        WAIT_TIMEOUT => Ok(Termination::Requested),
        _ => {
            Err("O encerramento foi solicitado, mas não foi possível confirmar o resultado.".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_self_system_and_protected_names() {
        assert!(
            process(
                ProcessIdentity {
                    pid: std::process::id(),
                    created: 1
                },
                false
            )
            .is_err()
        );
        assert!(process(ProcessIdentity { pid: 4, created: 1 }, false).is_err());
        assert!(protected_name(std::path::Path::new(
            r"C:\Elsewhere\Explorer.EXE"
        )));
        assert!(protected_name(std::path::Path::new(
            r"C:\Elsewhere\EasyAntiCheat.exe"
        )));
        assert!(!protected_name(std::path::Path::new(r"C:\Games\game.exe")));
    }
    #[test]
    fn detects_resolved_windows_directory() {
        let mut buffer = vec![0u16; 32_768];
        let count =
            unsafe { GetWindowsDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
        assert!(count > 0 && count < buffer.len());
        let root = PathBuf::from(std::ffi::OsString::from_wide(&buffer[..count]));
        let resolved = std::fs::canonicalize(root).unwrap();
        assert!(is_windows_image(&resolved).unwrap());
        assert!(is_windows_image(&resolved.join("System32")).unwrap());
        let unrelated = std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap();
        assert!(!is_windows_image(&unrelated).unwrap());
    }
    #[test]
    #[ignore = "Terminates only an explicitly built, isolated test fixture"]
    fn terminates_isolated_fixture_after_identity_checks() {
        let path =
            std::env::var_os("WFO_TEST_GAME").expect("set WFO_TEST_GAME to the isolated fixture");
        let identity = crate::windows_process::launch(std::path::Path::new(&path)).unwrap();
        let candidate = inspect(identity).unwrap();
        assert!(
            candidate
                .path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .eq_ignore_ascii_case("idle_game.exe")
        );
        assert_eq!(terminate(&candidate).unwrap(), Termination::Exited);
        assert!(terminate(&candidate).is_err());
    }
}
