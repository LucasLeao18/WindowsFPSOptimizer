//! Read-only page-file discovery. Writing this machine-wide setting requires
//! an elevated, independently protected transaction and is not implemented yet.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Management {
    Automatic,
    Manual,
}

fn unique_state(values: &[Option<bool>]) -> Result<Management, String> {
    match values {
        [Some(true)] => Ok(Management::Automatic),
        [Some(false)] => Ok(Management::Manual),
        _ => Err("Não foi possível confirmar como a memória virtual é gerenciada.".into()),
    }
}

/// Queries only the local machine. Call from a worker thread; WMI can be slow or disabled.
#[cfg(windows)]
pub fn detect() -> Result<Management, String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct ComputerSystem {
        automatic_managed_pagefile: Option<bool>,
    }
    let connection = wmi::WMIConnection::new()
        .map_err(|e| format!("O serviço de gerenciamento do Windows está indisponível: {e}"))?;
    let rows: Vec<ComputerSystem> = connection
        .raw_query("SELECT AutomaticManagedPagefile FROM Win32_ComputerSystem")
        .map_err(|e| format!("Não foi possível consultar a memória virtual: {e}"))?;
    unique_state(
        &rows
            .iter()
            .map(|r| r.automatic_managed_pagefile)
            .collect::<Vec<_>>(),
    )
}

/// WMI can hang indefinitely on damaged or managed systems. A timeout only
/// abandons a read-only query; it must never wrap a system mutation.
#[cfg(windows)]
pub fn detect_with_timeout(timeout: std::time::Duration) -> Result<Management, String> {
    use std::sync::atomic::AtomicBool;
    static IN_FLIGHT: AtomicBool = AtomicBool::new(false);
    query_with_timeout(&IN_FLIGHT, timeout, detect)
}

#[cfg(windows)]
fn query_with_timeout(
    in_flight: &'static std::sync::atomic::AtomicBool,
    timeout: std::time::Duration,
    query: impl FnOnce() -> Result<Management, String> + Send + 'static,
) -> Result<Management, String> {
    use std::sync::{atomic::Ordering, mpsc};
    if in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err("Uma consulta anterior ao Windows ainda está em andamento. Tente novamente mais tarde ou use o perfil Seguro.".into());
    }
    let (tx, rx) = mpsc::sync_channel(1);
    let thread = std::thread::Builder::new()
        .name("pagefile-query".into())
        .spawn(move || {
            struct Release(&'static std::sync::atomic::AtomicBool);
            impl Drop for Release {
                fn drop(&mut self) {
                    self.0.store(false, Ordering::Release);
                }
            }
            let _release = Release(in_flight);
            let _ = tx.send(query());
        });
    if let Err(error) = thread {
        in_flight.store(false, Ordering::Release);
        return Err(format!("Não foi possível iniciar a consulta: {error}"));
    }
    match rx.recv_timeout(timeout) {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => Err("A consulta de memória virtual demorou demais. Nenhuma configuração foi alterada; tente novamente ou use o perfil Seguro.".into()),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err("A consulta de memória virtual foi interrompida.".into()),
    }
}

#[cfg(not(windows))]
pub fn detect_with_timeout(_: std::time::Duration) -> Result<Management, String> {
    detect()
}

#[cfg(not(windows))]
pub fn detect() -> Result<Management, String> {
    Err("Esta consulta requer Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_or_ambiguous_machine_data() {
        assert_eq!(unique_state(&[Some(true)]).unwrap(), Management::Automatic);
        assert_eq!(unique_state(&[Some(false)]).unwrap(), Management::Manual);
        for invalid in [vec![], vec![None], vec![Some(true), Some(false)]] {
            assert!(unique_state(&invalid).is_err());
        }
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "Requires the local Windows WMI service"]
    fn reads_local_pagefile_management() {
        assert!(matches!(
            detect_with_timeout(std::time::Duration::from_secs(8)),
            Ok(Management::Automatic | Management::Manual)
        ));
    }

    #[cfg(windows)]
    #[test]
    fn timeout_prevents_duplicate_hung_queries() {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            mpsc,
        };
        static TEST_GATE: AtomicBool = AtomicBool::new(false);
        let (tx, rx) = mpsc::channel();
        let result = query_with_timeout(
            &TEST_GATE,
            std::time::Duration::from_millis(20),
            move || {
                rx.recv().unwrap();
                Ok(Management::Automatic)
            },
        );
        assert!(result.unwrap_err().contains("demorou"));
        assert!(
            query_with_timeout(&TEST_GATE, std::time::Duration::from_secs(1), || Ok(
                Management::Manual
            ))
            .is_err()
        );
        tx.send(()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while TEST_GATE.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(!TEST_GATE.load(Ordering::Acquire));
    }
}
