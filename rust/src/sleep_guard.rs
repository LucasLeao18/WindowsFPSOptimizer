//! Temporary sleep prevention tied to the selected game process and this app.
//! No power plan or persistent system setting is changed.
use std::{
    sync::{Mutex, OnceLock, mpsc},
    thread,
    time::Duration,
};
use windows_fps_optimizer::{session::ProcessIdentity, windows_process};
use windows_sys::Win32::System::Power::{
    ES_CONTINUOUS, ES_SYSTEM_REQUIRED, SetThreadExecutionState,
};

struct Guard {
    stop: mpsc::Sender<()>,
    thread: thread::JoinHandle<()>,
}
static GUARD: OnceLock<Mutex<Option<Guard>>> = OnceLock::new();

pub fn stop() {
    if let Ok(mut current) = GUARD.get_or_init(|| Mutex::new(None)).lock()
        && let Some(guard) = current.take()
    {
        let _ = guard.stop.send(());
        let _ = guard.thread.join();
    }
}

pub fn start(process: ProcessIdentity) -> Result<(), String> {
    stop();
    let mut current = GUARD
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| "Não foi possível controlar a suspensão temporária.")?;
    let (stop, receiver) = mpsc::channel();
    let (ready, response) = mpsc::sync_channel(1);
    let thread = thread::Builder::new()
        .name("game-sleep-guard".into())
        .spawn(move || {
            if windows_process::identity(process.pid).ok() != Some(process) {
                let _ = ready.send(Err(
                    "O processo terminou antes de impedir a suspensão.".to_owned()
                ));
                return;
            }
            if unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) } == 0 {
                let _ = ready.send(Err(
                    "O Windows não aceitou impedir a suspensão durante a sessão.".to_owned(),
                ));
                return;
            }
            let _ = ready.send(Ok(()));
            loop {
                match receiver.recv_timeout(Duration::from_secs(1)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        if windows_process::identity(process.pid).ok() != Some(process) {
                            break;
                        }
                    }
                }
            }
            unsafe {
                SetThreadExecutionState(ES_CONTINUOUS);
            }
        })
        .map_err(|e| format!("Não foi possível impedir a suspensão: {e}"))?;
    match response.recv() {
        Ok(Ok(())) => {
            *current = Some(Guard { stop, thread });
            Ok(())
        }
        Ok(Err(error)) => {
            let _ = thread.join();
            Err(error)
        }
        Err(_) => {
            let _ = thread.join();
            Err("A proteção contra suspensão foi interrompida.".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "Temporarily requests that a disposable Windows runner stay awake"]
    fn temporary_sleep_guard_checks_identity_and_stops() {
        let process = windows_process::identity(std::process::id()).unwrap();
        let stale = ProcessIdentity {
            created: process.created ^ 1,
            ..process
        };
        assert!(start(stale).is_err());
        start(process).unwrap();
        stop();
        start(process).unwrap();
        stop();
    }
}
