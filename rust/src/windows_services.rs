//! Native Service Control Manager adapter; no shell and no boot-mode changes.
use crate::services::{Backend, Service, Status};
use std::{
    io, ptr, thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{Foundation::ERROR_SERVICE_DOES_NOT_EXIST, System::Services::*};

struct Handle(SC_HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseServiceHandle(self.0);
        }
    }
}
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn open(service: Service, access: u32) -> Result<Option<Handle>, String> {
    let manager = unsafe { OpenSCManagerW(ptr::null(), ptr::null(), SC_MANAGER_CONNECT) };
    if manager.is_null() {
        return Err(format!(
            "Não foi possível acessar serviços do Windows: {}",
            io::Error::last_os_error()
        ));
    }
    let manager = Handle(manager);
    let raw = unsafe {
        OpenServiceW(
            manager.0,
            wide(service.name()).as_ptr(),
            access | SERVICE_QUERY_STATUS,
        )
    };
    if raw.is_null() {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_SERVICE_DOES_NOT_EXIST as i32) {
            return Ok(None);
        }
        return Err(format!(
            "Não foi possível acessar {}: {error}. A alteração pode exigir administrador.",
            service.title()
        ));
    }
    Ok(Some(Handle(raw)))
}
fn query(handle: &Handle) -> Result<SERVICE_STATUS_PROCESS, String> {
    let mut state = SERVICE_STATUS_PROCESS::default();
    let mut size = 0u32;
    if unsafe {
        QueryServiceStatusEx(
            handle.0,
            SC_STATUS_PROCESS_INFO,
            (&mut state as *mut SERVICE_STATUS_PROCESS).cast(),
            std::mem::size_of::<SERVICE_STATUS_PROCESS>() as u32,
            &mut size,
        )
    } == 0
    {
        return Err(format!(
            "Não foi possível consultar o serviço: {}",
            io::Error::last_os_error()
        ));
    }
    if state.dwServiceType & SERVICE_WIN32 == 0 {
        return Err("O serviço não é um serviço de usuário do Windows suportado.".into());
    }
    Ok(state)
}
fn status(state: &SERVICE_STATUS_PROCESS) -> Status {
    match state.dwCurrentState {
        SERVICE_RUNNING => Status::Running,
        SERVICE_STOPPED => Status::Stopped,
        _ => Status::Transitioning,
    }
}
fn wait(handle: &Handle, wanted: Status) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if status(&query(handle)?) == wanted {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("O Windows não confirmou a mudança do serviço no tempo esperado; o backup foi preservado.".into());
        }
        thread::sleep(Duration::from_millis(250));
    }
}
#[derive(Default)]
pub struct WindowsServices;
pub type Inventory = Vec<(Service, Result<Option<Status>, String>)>;

/// The SCM is an external service and can become unresponsive. Only this
/// read-only inventory may time out; mutations are never abandoned this way.
pub fn inventory_with_timeout(timeout: Duration) -> Result<Inventory, String> {
    use std::sync::atomic::AtomicBool;
    static IN_FLIGHT: AtomicBool = AtomicBool::new(false);
    query_with_timeout(&IN_FLIGHT, timeout, || {
        let mut backend = WindowsServices;
        Ok(Service::ALL
            .into_iter()
            .map(|service| (service, backend.status(service)))
            .collect())
    })
}
fn query_with_timeout(
    in_flight: &'static std::sync::atomic::AtomicBool,
    timeout: Duration,
    query: impl FnOnce() -> Result<Inventory, String> + Send + 'static,
) -> Result<Inventory, String> {
    use std::sync::{atomic::Ordering, mpsc};
    if in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err("Uma consulta anterior aos serviços ainda está em andamento.".into());
    }
    let (sender, receiver) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name("services-inventory".into())
        .spawn(move || {
            struct Release(&'static std::sync::atomic::AtomicBool);
            impl Drop for Release {
                fn drop(&mut self) {
                    self.0.store(false, Ordering::Release);
                }
            }
            let _release = Release(in_flight);
            let _ = sender.send(query());
        });
    if let Err(error) = thread {
        in_flight.store(false, Ordering::Release);
        return Err(format!(
            "Não foi possível iniciar a consulta de serviços: {error}"
        ));
    }
    match receiver.recv_timeout(timeout) {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            Err("A consulta de serviços demorou demais; nenhuma alteração foi feita.".into())
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            Err("A consulta de serviços foi interrompida.".into())
        }
    }
}
impl Backend for WindowsServices {
    fn status(&mut self, service: Service) -> Result<Option<Status>, String> {
        let Some(handle) = open(service, 0)? else {
            return Ok(None);
        };
        query(&handle).map(|state| Some(status(&state)))
    }
    fn stop_if_running(&mut self, service: Service) -> Result<(), String> {
        let handle = open(service, SERVICE_STOP)?.ok_or("O serviço deixou de estar disponível.")?;
        let state = query(&handle)?;
        if status(&state) != Status::Running || state.dwControlsAccepted & SERVICE_ACCEPT_STOP == 0
        {
            return Err("O serviço mudou ou não aceita parada no momento.".into());
        }
        let mut result = SERVICE_STATUS::default();
        if unsafe { ControlService(handle.0, SERVICE_CONTROL_STOP, &mut result) } == 0 {
            return Err(format!(
                "Não foi possível parar o serviço: {}",
                io::Error::last_os_error()
            ));
        }
        wait(&handle, Status::Stopped)
    }
    fn start_if_stopped(&mut self, service: Service) -> Result<(), String> {
        let handle =
            open(service, SERVICE_START)?.ok_or("O serviço deixou de estar disponível.")?;
        if status(&query(&handle)?) != Status::Stopped {
            return Err("O serviço mudou antes da restauração.".into());
        }
        if unsafe { StartServiceW(handle.0, 0, ptr::null()) } == 0 {
            return Err(format!(
                "Não foi possível iniciar o serviço: {}",
                io::Error::last_os_error()
            ));
        }
        wait(&handle, Status::Running)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn queries_optional_services_without_changes() {
        let mut backend = WindowsServices;
        let mut readable = 0;
        for service in Service::ALL {
            if backend.status(service).is_ok() {
                readable += 1;
            }
        }
        assert!(readable > 0);
    }
    #[test]
    fn stalled_inventory_does_not_start_duplicate_queries() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            mpsc,
        };
        static GATE: AtomicBool = AtomicBool::new(false);
        let (tx, rx) = mpsc::channel();
        assert!(
            query_with_timeout(&GATE, Duration::from_millis(20), move || {
                rx.recv().unwrap();
                Ok(Vec::new())
            })
            .is_err()
        );
        assert!(query_with_timeout(&GATE, Duration::from_secs(1), || Ok(Vec::new())).is_err());
        tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while GATE.load(Ordering::Acquire) && Instant::now() < deadline {
            thread::yield_now();
        }
        assert!(!GATE.load(Ordering::Acquire));
    }
    #[test]
    #[ignore = "Installs and controls only a dedicated fixture service on a disposable administrator runner"]
    fn disposable_service_round_trip() {
        use crate::{
            services::{self, RestoreResult, StopResult},
            storage::FileStore,
        };
        let executable = std::path::PathBuf::from(
            std::env::var_os("WFO_TEST_SERVICE_EXE")
                .expect("set WFO_TEST_SERVICE_EXE to the isolated CI fixture"),
        );
        assert!(executable.is_absolute() && executable.is_file());
        assert!(
            open(Service::Fixture, 0).unwrap().is_none(),
            "Fixture service already exists; refusing to touch it"
        );
        let manager = unsafe {
            OpenSCManagerW(
                ptr::null(),
                ptr::null(),
                SC_MANAGER_CREATE_SERVICE | SC_MANAGER_CONNECT,
            )
        };
        assert!(
            !manager.is_null(),
            "Fixture service requires a disposable administrator runner"
        );
        let manager = Handle(manager);
        let bin = format!("\"{}\"", executable.display());
        let raw = unsafe {
            CreateServiceW(
                manager.0,
                wide(Service::Fixture.name()).as_ptr(),
                wide("Windows FPS Optimizer Test Fixture").as_ptr(),
                SERVICE_ALL_ACCESS,
                SERVICE_WIN32_OWN_PROCESS,
                SERVICE_DEMAND_START,
                SERVICE_ERROR_NORMAL,
                wide(&bin).as_ptr(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
            )
        };
        assert!(
            !raw.is_null(),
            "Failed to create isolated service: {}",
            io::Error::last_os_error()
        );
        struct Cleanup(Handle);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let mut state = SERVICE_STATUS::default();
                unsafe {
                    ControlService(self.0.0, SERVICE_CONTROL_STOP, &mut state);
                }
                let _ = wait(&self.0, Status::Stopped);
                unsafe {
                    DeleteService(self.0.0);
                }
            }
        }
        let _cleanup = Cleanup(Handle(raw));
        let mut backend = WindowsServices;
        backend.start_if_stopped(Service::Fixture).unwrap();
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("service-test-{unique}"));
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                services::stop(&mut backend, &mut store, Service::Fixture).unwrap(),
                StopResult::Stopped
            );
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                services::restore(&mut backend, &mut store, Service::Fixture).unwrap(),
                RestoreResult::Started
            );
        }
        let game = crate::windows_process::identity(std::process::id()).unwrap();
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                services::stop_for_game(&mut backend, &mut store, Service::Fixture, game).unwrap(),
                StopResult::Stopped
            );
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                services::restore_game(&mut backend, &mut store, game).unwrap(),
                vec![(Service::Fixture, Ok(RestoreResult::Started))]
            );
        }
        let target = std::fs::canonicalize(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target"),
        )
        .unwrap();
        let resolved = std::fs::canonicalize(directory).unwrap();
        assert_eq!(resolved.parent(), Some(target.as_path()));
        std::fs::remove_dir_all(resolved).unwrap();
    }
}
