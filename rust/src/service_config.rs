//! Recoverable start-type changes for a fixed list of services that gaming
//! boosters disable (SysMain/Superfetch and Windows Search). Unlike the
//! optional-service controls, the change survives restarts until restored.
use serde::{Deserialize, Serialize};

pub const DISABLED: u32 = 4;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum Service {
    SysMain,
    WindowsSearch,
}

impl Service {
    pub const ALL: [Self; 2] = [Self::SysMain, Self::WindowsSearch];
    pub fn name(self) -> &'static str {
        match self {
            Self::SysMain => "SysMain",
            Self::WindowsSearch => "WSearch",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::SysMain => "SysMain (Superfetch)",
            Self::WindowsSearch => "Windows Search (indexação)",
        }
    }
    pub fn impact(self) -> &'static str {
        match self {
            Self::SysMain => {
                "programas usados com frequência podem abrir um pouco mais devagar, principalmente em HD"
            }
            Self::WindowsSearch => {
                "a pesquisa do menu Iniciar, do Explorador e do Outlook fica lenta ou incompleta"
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    Pending,
    Armed,
    Applied,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub service: Service,
    pub start_type: u32,
    pub was_running: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Journal {
    pub schema: u32,
    pub entries: Vec<Entry>,
    pub phase: Phase,
}

pub trait Backend {
    /// `None` when the service is not installed.
    fn start_type(&mut self, service: Service) -> Result<Option<u32>, String>;
    fn set_start_type(&mut self, service: Service, start_type: u32) -> Result<(), String>;
    fn running(&mut self, service: Service) -> Result<bool, String>;
    fn stop(&mut self, service: Service) -> Result<(), String>;
    fn start(&mut self, service: Service) -> Result<(), String>;
}

pub trait Store {
    fn load_service_config(&mut self) -> Result<Option<Journal>, String>;
    fn save_service_config(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_service_config(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_service_config(&mut self) -> Result<(), String>;
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct RestoreReport {
    pub restored: Vec<Service>,
    pub conflicts: Vec<Service>,
}

fn valid_start_type(value: u32) -> bool {
    // Boot and system start types belong to drivers, never to these services.
    matches!(value, 2..=4)
}

fn validate(journal: &Journal) -> Result<(), String> {
    let mut seen = std::collections::HashSet::new();
    if journal.schema != 1
        || journal.entries.is_empty()
        || !journal.entries.iter().all(|entry| {
            seen.insert(entry.service)
                && valid_start_type(entry.start_type)
                && entry.start_type != DISABLED
        })
    {
        return Err("Backup de serviços do perfil inválido.".into());
    }
    Ok(())
}

/// Services from `wanted` that are installed and not yet disabled.
pub fn pending<B: Backend>(backend: &mut B, wanted: &[Service]) -> Result<Vec<Service>, String> {
    let mut found = Vec::new();
    for service in wanted {
        if let Some(start_type) = backend.start_type(*service)?
            && start_type != DISABLED
            && valid_start_type(start_type)
        {
            found.push(*service);
        }
    }
    Ok(found)
}

pub fn begin<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    wanted: &[Service],
) -> Result<usize, String> {
    if store.load_service_config()?.is_some() {
        return Err("Há um backup de serviços do perfil para restaurar.".into());
    }
    let mut entries = Vec::new();
    for service in pending(backend, wanted)? {
        entries.push(Entry {
            service,
            start_type: backend.start_type(service)?.ok_or("Serviço removido.")?,
            was_running: backend.running(service)?,
        });
    }
    if entries.is_empty() {
        return Ok(0);
    }
    let journal = Journal {
        schema: 1,
        entries,
        phase: Phase::Pending,
    };
    validate(&journal)?;
    store.save_service_config(&journal)?;
    let mut armed = journal.clone();
    armed.phase = Phase::Armed;
    store.update_service_config(&journal, &armed)?;
    for entry in &armed.entries {
        backend.set_start_type(entry.service, DISABLED)?;
        if backend.running(entry.service)? {
            backend.stop(entry.service)?;
        }
    }
    let mut applied = armed.clone();
    applied.phase = Phase::Applied;
    store.update_service_config(&armed, &applied)?;
    Ok(applied.entries.len())
}

pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
) -> Result<RestoreReport, String> {
    let journal = store
        .load_service_config()?
        .ok_or("Não há backup de serviços do perfil.")?;
    validate(&journal)?;
    let mut report = RestoreReport::default();
    let mut remaining = Vec::new();
    for entry in &journal.entries {
        match backend.start_type(entry.service)? {
            Some(DISABLED) => {
                backend.set_start_type(entry.service, entry.start_type)?;
                if entry.was_running && !backend.running(entry.service)? {
                    backend.start(entry.service)?;
                }
                report.restored.push(entry.service);
            }
            Some(current) if current == entry.start_type => {}
            None => {}
            Some(_) => {
                report.conflicts.push(entry.service);
                remaining.push(entry.clone());
            }
        }
    }
    if remaining.is_empty() {
        store.clear_service_config()?;
    } else {
        let mut kept = journal.clone();
        kept.entries = remaining;
        store.update_service_config(&journal, &kept)?;
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    #[derive(Default)]
    struct Fake(HashMap<Service, (u32, bool)>);
    impl Backend for Fake {
        fn start_type(&mut self, service: Service) -> Result<Option<u32>, String> {
            Ok(self.0.get(&service).map(|v| v.0))
        }
        fn set_start_type(&mut self, service: Service, start_type: u32) -> Result<(), String> {
            self.0.get_mut(&service).unwrap().0 = start_type;
            Ok(())
        }
        fn running(&mut self, service: Service) -> Result<bool, String> {
            Ok(self.0[&service].1)
        }
        fn stop(&mut self, service: Service) -> Result<(), String> {
            self.0.get_mut(&service).unwrap().1 = false;
            Ok(())
        }
        fn start(&mut self, service: Service) -> Result<(), String> {
            self.0.get_mut(&service).unwrap().1 = true;
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_service_config(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_service_config(&mut self, j: &Journal) -> Result<(), String> {
            self.0 = Some(j.clone());
            Ok(())
        }
        fn update_service_config(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            assert_eq!(self.0.as_ref(), Some(old));
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_service_config(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    #[test]
    fn disables_stops_and_restores_original_state() {
        let mut backend = Fake::default();
        backend.0.insert(Service::SysMain, (2, true));
        backend.0.insert(Service::WindowsSearch, (3, false));
        let mut store = Memory::default();
        assert_eq!(begin(&mut backend, &mut store, &Service::ALL).unwrap(), 2);
        assert_eq!(backend.0[&Service::SysMain], (DISABLED, false));
        let report = restore(&mut backend, &mut store).unwrap();
        assert_eq!(report.restored.len(), 2);
        assert_eq!(backend.0[&Service::SysMain], (2, true));
        assert_eq!(backend.0[&Service::WindowsSearch], (3, false));
        assert!(store.0.is_none());
    }
    #[test]
    fn missing_disabled_and_changed_services_are_respected() {
        let mut backend = Fake::default();
        backend.0.insert(Service::SysMain, (DISABLED, false));
        let mut store = Memory::default();
        assert_eq!(begin(&mut backend, &mut store, &Service::ALL).unwrap(), 0);
        assert!(store.0.is_none());
        backend.0.insert(Service::SysMain, (2, true));
        begin(&mut backend, &mut store, &[Service::SysMain]).unwrap();
        backend.0.insert(Service::SysMain, (3, false));
        let report = restore(&mut backend, &mut store).unwrap();
        assert_eq!(report.conflicts, vec![Service::SysMain]);
        assert_eq!(backend.0[&Service::SysMain], (3, false));
        assert!(store.0.is_some());
    }
}
