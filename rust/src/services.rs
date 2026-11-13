//! Individually selected optional services. Names are an enum, never supplied
//! by a journal or by a command line. Stopping does not change boot settings.
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum Service {
    Spooler,
    Fax,
    Bluetooth,
    OfflineMaps,
    Location,
    TouchInput,
    Biometrics,
    RetailDemo,
    XboxAuth,
    XboxAccessories,
    #[cfg(test)]
    Fixture,
}
impl Service {
    pub const ALL: [Self; 10] = [
        Self::Spooler,
        Self::Fax,
        Self::Bluetooth,
        Self::OfflineMaps,
        Self::Location,
        Self::TouchInput,
        Self::Biometrics,
        Self::RetailDemo,
        Self::XboxAuth,
        Self::XboxAccessories,
    ];
    pub fn name(self) -> &'static str {
        match self {
            Self::Spooler => "Spooler",
            Self::Fax => "Fax",
            Self::Bluetooth => "bthserv",
            Self::OfflineMaps => "MapsBroker",
            Self::Location => "lfsvc",
            Self::TouchInput => "TabletInputService",
            Self::Biometrics => "WbioSrvc",
            Self::RetailDemo => "RetailDemo",
            Self::XboxAuth => "XblAuthManager",
            Self::XboxAccessories => "XboxGipSvc",
            #[cfg(test)]
            Self::Fixture => "WindowsFPSOptimizerRustValidation",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::Spooler => "Impressão",
            Self::Fax => "Fax",
            Self::Bluetooth => "Bluetooth",
            Self::OfflineMaps => "Mapas offline",
            Self::Location => "Localização",
            Self::TouchInput => "Teclado virtual e caneta",
            Self::Biometrics => "Biometria do Windows",
            Self::RetailDemo => "Demonstração comercial",
            Self::XboxAuth => "Autenticação Xbox",
            Self::XboxAccessories => "Acessórios Xbox",
            #[cfg(test)]
            Self::Fixture => "Serviço de teste isolado",
        }
    }
    pub fn impact(self) -> &'static str {
        match self {
            Self::Spooler => "Impressoras e impressão em PDF podem parar.",
            Self::Fax => "O envio e recebimento de fax podem parar.",
            Self::Bluetooth => "Controles, fones, teclados e mouses Bluetooth podem desconectar.",
            Self::OfflineMaps => "Aplicativos que usam mapas offline podem ser afetados.",
            Self::Location => "Aplicativos que usam localização podem ser afetados.",
            Self::TouchInput => "Teclado virtual, toque e caneta podem ser afetados.",
            Self::Biometrics => "A entrada biométrica do Windows pode parar.",
            Self::RetailDemo => "O modo de demonstração de loja pode parar.",
            Self::XboxAuth => "Login Xbox, conquistas e jogos da Microsoft Store podem falhar.",
            Self::XboxAccessories => "Controles e acessórios Xbox podem deixar de funcionar.",
            #[cfg(test)]
            Self::Fixture => "Nenhum impacto fora da máquina de teste.",
        }
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Running,
    Stopped,
    Transitioning,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    Pending,
    Armed,
    Applied,
    Reverting,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub service: Service,
    pub phase: Phase,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Journal {
    pub schema: u32,
    pub entries: Vec<Entry>,
}
pub trait Backend {
    /// None means this optional service is not installed.
    fn status(&mut self, service: Service) -> Result<Option<Status>, String>;
    fn stop_if_running(&mut self, service: Service) -> Result<(), String>;
    fn start_if_stopped(&mut self, service: Service) -> Result<(), String>;
}
pub trait Store {
    fn load_services(&mut self) -> Result<Option<Journal>, String>;
    fn save_services(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_services(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_services(&mut self) -> Result<(), String>;
}
#[derive(Debug, Eq, PartialEq)]
pub enum StopResult {
    Stopped,
    AlreadyStopped,
}
#[derive(Debug, Eq, PartialEq)]
pub enum RestoreResult {
    Started,
    AlreadyRunning,
    Conflict,
}

pub fn validate(journal: &Journal) -> Result<(), String> {
    if journal.schema != 1 || journal.entries.len() > Service::ALL.len() {
        return Err("Registro de serviços inválido.".into());
    }
    let mut seen = HashSet::new();
    if journal
        .entries
        .iter()
        .any(|entry| !seen.insert(entry.service))
    {
        return Err("Serviço duplicado no backup.".into());
    }
    Ok(())
}
pub fn stop<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    service: Service,
) -> Result<StopResult, String> {
    let previous = store.load_services()?;
    let mut journal = previous.clone().unwrap_or(Journal {
        schema: 1,
        entries: Vec::new(),
    });
    validate(&journal)?;
    if journal.entries.iter().any(|entry| entry.service == service) {
        return Err("Este serviço já possui um registro para restaurar.".into());
    }
    match backend.status(service)? {
        None => return Err("Este serviço não está instalado neste computador.".into()),
        Some(Status::Stopped) => return Ok(StopResult::AlreadyStopped),
        Some(Status::Transitioning) => {
            return Err("O serviço está mudando de estado. Tente novamente.".into());
        }
        Some(Status::Running) => {}
    }
    journal.entries.push(Entry {
        service,
        phase: Phase::Pending,
    });
    if let Some(old) = previous {
        store.update_services(&old, &journal)?;
    } else {
        store.save_services(&journal)?;
    }
    if backend.status(service)? != Some(Status::Running) {
        return Err("O serviço mudou durante a análise; o registro foi preservado.".into());
    }
    let mut armed = journal.clone();
    armed.entries.last_mut().unwrap().phase = Phase::Armed;
    store.update_services(&journal, &armed)?;
    backend.stop_if_running(service)?;
    if backend.status(service)? != Some(Status::Stopped) {
        return Err("Não foi possível confirmar a parada; o registro foi preservado.".into());
    }
    let mut applied = armed.clone();
    applied.entries.last_mut().unwrap().phase = Phase::Applied;
    store.update_services(&armed, &applied)?;
    Ok(StopResult::Stopped)
}
pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    service: Service,
) -> Result<RestoreResult, String> {
    let journal = store
        .load_services()?
        .ok_or("Não há serviço para restaurar.")?;
    validate(&journal)?;
    let index = journal
        .entries
        .iter()
        .position(|entry| entry.service == service)
        .ok_or("Serviço não encontrado no backup.")?;
    let status = backend.status(service)?;
    let result = if status == Some(Status::Running) {
        RestoreResult::AlreadyRunning
    } else if status != Some(Status::Stopped) || journal.entries[index].phase != Phase::Applied {
        return Ok(RestoreResult::Conflict);
    } else {
        let mut reverting = journal.clone();
        reverting.entries[index].phase = Phase::Reverting;
        store.update_services(&journal, &reverting)?;
        backend.start_if_stopped(service)?;
        if backend.status(service)? != Some(Status::Running) {
            return Err(
                "Não foi possível confirmar a restauração; o registro foi preservado.".into(),
            );
        }
        let mut done = reverting.clone();
        done.entries.remove(index);
        if done.entries.is_empty() {
            store.clear_services()?;
        } else {
            store.update_services(&reverting, &done)?;
        }
        return Ok(RestoreResult::Started);
    };
    let mut done = journal.clone();
    done.entries.remove(index);
    if done.entries.is_empty() {
        store.clear_services()?;
    } else {
        store.update_services(&journal, &done)?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    #[derive(Default)]
    struct Fake(HashMap<Service, Status>);
    impl Backend for Fake {
        fn status(&mut self, service: Service) -> Result<Option<Status>, String> {
            Ok(self.0.get(&service).copied())
        }
        fn stop_if_running(&mut self, service: Service) -> Result<(), String> {
            if self.status(service)? != Some(Status::Running) {
                return Err("changed".into());
            }
            self.0.insert(service, Status::Stopped);
            Ok(())
        }
        fn start_if_stopped(&mut self, service: Service) -> Result<(), String> {
            if self.status(service)? != Some(Status::Stopped) {
                return Err("changed".into());
            }
            self.0.insert(service, Status::Running);
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_services(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_services(&mut self, value: &Journal) -> Result<(), String> {
            if self.0.is_some() {
                return Err("exists".into());
            }
            self.0 = Some(value.clone());
            Ok(())
        }
        fn update_services(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("changed".into());
            }
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_services(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    #[test]
    fn stops_and_restores_each_selected_service() {
        let mut backend = Fake::default();
        backend.0.insert(Service::Fax, Status::Running);
        backend.0.insert(Service::OfflineMaps, Status::Running);
        let mut store = Memory::default();
        assert_eq!(
            stop(&mut backend, &mut store, Service::Fax).unwrap(),
            StopResult::Stopped
        );
        stop(&mut backend, &mut store, Service::OfflineMaps).unwrap();
        assert_eq!(
            restore(&mut backend, &mut store, Service::Fax).unwrap(),
            RestoreResult::Started
        );
        assert_eq!(store.0.as_ref().unwrap().entries.len(), 1);
        assert_eq!(
            restore(&mut backend, &mut store, Service::OfflineMaps).unwrap(),
            RestoreResult::Started
        );
        assert!(store.0.is_none());
    }
    #[test]
    fn never_starts_previously_stopped_or_unknown_services() {
        let mut backend = Fake::default();
        backend.0.insert(Service::Fax, Status::Stopped);
        let mut store = Memory::default();
        assert_eq!(
            stop(&mut backend, &mut store, Service::Fax).unwrap(),
            StopResult::AlreadyStopped
        );
        assert!(stop(&mut backend, &mut store, Service::Bluetooth).is_err());
        assert!(store.0.is_none());
    }
    #[test]
    fn interrupted_and_external_changes_are_preserved() {
        let mut backend = Fake::default();
        backend.0.insert(Service::Fax, Status::Stopped);
        let mut store = Memory(Some(Journal {
            schema: 1,
            entries: vec![Entry {
                service: Service::Fax,
                phase: Phase::Armed,
            }],
        }));
        assert_eq!(
            restore(&mut backend, &mut store, Service::Fax).unwrap(),
            RestoreResult::Conflict
        );
        assert_eq!(backend.0[&Service::Fax], Status::Stopped);
        backend.0.insert(Service::Fax, Status::Running);
        assert_eq!(
            restore(&mut backend, &mut store, Service::Fax).unwrap(),
            RestoreResult::AlreadyRunning
        );
        assert!(store.0.is_none());
    }
    #[test]
    fn unknown_service_names_cannot_be_deserialized() {
        assert!(
            serde_json::from_str::<Journal>(
                r#"{"schema":1,"entries":[{"service":"WinDefend","phase":"Applied"}]}"#
            )
            .is_err()
        );
    }
    #[test]
    fn archived_service_backup_can_be_reactivated_after_reopening() {
        use crate::storage::FileStore;
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("services-store-{unique}"));
        let mut backend = Fake::default();
        backend.0.insert(Service::Fax, Status::Running);
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            stop(&mut backend, &mut store, Service::Fax).unwrap();
            let archive = store.archive_services().unwrap();
            let outside = directory.join("outside.json");
            std::fs::copy(&archive, &outside).unwrap();
            assert!(store.activate_services(&outside).is_err());
            store.activate_services(&archive).unwrap();
            assert!(store.activate_services(&archive).is_err());
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                restore(&mut backend, &mut store, Service::Fax).unwrap(),
                RestoreResult::Started
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
