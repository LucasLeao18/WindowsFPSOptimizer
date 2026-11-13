//! A headless instance watches the saved game identity after the UI closes.
//! It only uses journals under this user's own state directory.
use crate::app::{self, SessionCheck};
use std::{process::Command, thread, time::Duration};

pub fn launch() -> Result<(), String> {
    let executable = std::env::current_exe().map_err(|e| format!("Monitor indisponível: {e}"))?;
    Command::new(executable)
        .arg("--session-monitor")
        .spawn()
        .map_err(|e| format!("Não foi possível iniciar o monitor da sessão: {e}"))?;
    Ok(())
}

pub fn run() {
    let mut errors = 0u32;
    loop {
        match app::check_session() {
            Ok(SessionCheck::None | SessionCheck::Finished) => break,
            Ok(SessionCheck::Running) => errors = 0,
            Err(_) => {
                errors += 1;
                // Preserve unresolved journals for the user instead of leaving
                // an invisible process running forever after persistent errors.
                if errors >= 12 {
                    break;
                }
            }
        }
        thread::sleep(Duration::from_secs(5));
    }
}
