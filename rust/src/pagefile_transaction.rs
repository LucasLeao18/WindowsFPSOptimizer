//! Recoverable pagefile-management change. Platform writes must compare the
//! complete expected state and keep manual settings for restoration.
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Setting {
    pub name: String,
    pub initial_mb: u32,
    pub maximum_mb: u32,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct State {
    pub automatic: bool,
    pub settings: Vec<Setting>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    Pending,
    Armed,
    Applied,
    Reverting,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Journal {
    pub schema: u32,
    pub original: State,
    pub applied: Option<State>,
    pub phase: Phase,
}

pub trait Backend {
    fn snapshot(&mut self) -> Result<State, String>;
    fn set_automatic(&mut self, expected: &State) -> Result<(), String>;
    /// Must recheck the expected state and preserve all listed manual settings.
    fn restore_exact(&mut self, expected: &State, original: &State) -> Result<(), String>;
}
pub trait Store {
    fn load_pagefile(&mut self) -> Result<Option<Journal>, String>;
    fn save_pagefile(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_pagefile(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_pagefile(&mut self) -> Result<(), String>;
}
#[derive(Debug, Eq, PartialEq)]
pub enum BeginResult {
    Applied,
    AlreadyAutomatic,
}
#[derive(Debug, Eq, PartialEq)]
pub enum RestoreResult {
    Restored,
    AlreadyOriginal,
    Conflict,
}

/// Only conventional drive-root pagefiles are accepted; unknown layouts are
/// left untouched until their restore behavior is verified.
pub fn normalize(mut state: State) -> Result<State, String> {
    if state.settings.len() > 26 {
        return Err("Configuração de memória virtual não suportada.".into());
    }
    let mut names = HashSet::new();
    for setting in &mut state.settings {
        let bytes = setting.name.as_bytes();
        if bytes.len() != 15
            || !bytes[0].is_ascii_alphabetic()
            || bytes[1] != b':'
            || bytes[2] != b'\\'
            || !setting.name[3..].eq_ignore_ascii_case("pagefile.sys")
        {
            return Err(
                "Local de arquivo de paginação não suportado; nenhuma alteração será feita.".into(),
            );
        }
        setting.name.make_ascii_uppercase();
        if !names.insert(setting.name.clone()) {
            return Err("Arquivo de paginação duplicado.".into());
        }
    }
    state.settings.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(state)
}
pub fn validate(journal: &Journal) -> Result<(), String> {
    if journal.schema != 1
        || journal.original.automatic
        || normalize(journal.original.clone())? != journal.original
    {
        return Err("Backup de memória virtual inválido.".into());
    }
    if let Some(applied) = &journal.applied
        && (!applied.automatic || normalize(applied.clone())? != *applied)
    {
        return Err("Backup de memória virtual inválido.".into());
    }
    if matches!(journal.phase, Phase::Applied | Phase::Reverting) != journal.applied.is_some() {
        return Err("Backup de memória virtual incompleto.".into());
    }
    Ok(())
}
pub fn begin<B: Backend, S: Store>(backend: &mut B, store: &mut S) -> Result<BeginResult, String> {
    if store.load_pagefile()?.is_some() {
        return Err("Há um backup de memória virtual anterior para revisar.".into());
    }
    let original = normalize(backend.snapshot()?)?;
    if original.automatic {
        return Ok(BeginResult::AlreadyAutomatic);
    }
    let mut journal = Journal {
        schema: 1,
        original: original.clone(),
        applied: None,
        phase: Phase::Pending,
    };
    validate(&journal)?;
    store.save_pagefile(&journal)?;
    if normalize(backend.snapshot()?)? != original {
        return Err("A memória virtual mudou durante a análise; o backup foi preservado.".into());
    }
    let mut armed = journal.clone();
    armed.phase = Phase::Armed;
    store.update_pagefile(&journal, &armed)?;
    journal = armed;
    backend.set_automatic(&original)?;
    let applied = normalize(backend.snapshot()?)?;
    if !applied.automatic {
        return Err(
            "Não foi possível confirmar o gerenciamento automático; o backup foi preservado."
                .into(),
        );
    }
    let mut complete = journal.clone();
    complete.phase = Phase::Applied;
    complete.applied = Some(applied);
    validate(&complete)?;
    store.update_pagefile(&journal, &complete)?;
    Ok(BeginResult::Applied)
}
pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
) -> Result<RestoreResult, String> {
    let journal = store
        .load_pagefile()?
        .ok_or("Não há backup de memória virtual.")?;
    validate(&journal)?;
    let current = normalize(backend.snapshot()?)?;
    if current == journal.original {
        store.clear_pagefile()?;
        return Ok(RestoreResult::AlreadyOriginal);
    }
    if journal.phase != Phase::Applied || journal.applied.as_ref() != Some(&current) {
        return Ok(RestoreResult::Conflict);
    }
    let mut reverting = journal.clone();
    reverting.phase = Phase::Reverting;
    store.update_pagefile(&journal, &reverting)?;
    backend.restore_exact(&current, &journal.original)?;
    if normalize(backend.snapshot()?)? != journal.original {
        return Err(
            "Não foi possível confirmar a memória virtual restaurada; o backup foi preservado."
                .into(),
        );
    }
    store.clear_pagefile()?;
    Ok(RestoreResult::Restored)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn manual() -> State {
        normalize(State {
            automatic: false,
            settings: vec![
                Setting {
                    name: r"C:\pagefile.sys".into(),
                    initial_mb: 4096,
                    maximum_mb: 8192,
                },
                Setting {
                    name: r"D:\pagefile.sys".into(),
                    initial_mb: 0,
                    maximum_mb: 0,
                },
            ],
        })
        .unwrap()
    }
    struct Fake {
        state: State,
        fail_after_write: bool,
    }
    impl Backend for Fake {
        fn snapshot(&mut self) -> Result<State, String> {
            Ok(self.state.clone())
        }
        fn set_automatic(&mut self, expected: &State) -> Result<(), String> {
            if &self.state != expected {
                return Err("changed".into());
            }
            self.state = State {
                automatic: true,
                settings: Vec::new(),
            };
            if self.fail_after_write {
                return Err("interrupted".into());
            }
            Ok(())
        }
        fn restore_exact(&mut self, expected: &State, original: &State) -> Result<(), String> {
            if &self.state != expected {
                return Err("changed".into());
            }
            self.state = original.clone();
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_pagefile(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_pagefile(&mut self, value: &Journal) -> Result<(), String> {
            if self.0.is_some() {
                return Err("exists".into());
            }
            self.0 = Some(value.clone());
            Ok(())
        }
        fn update_pagefile(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("changed".into());
            }
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_pagefile(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    #[test]
    fn restores_all_original_manual_pagefiles() {
        let original = manual();
        let mut backend = Fake {
            state: original.clone(),
            fail_after_write: false,
        };
        let mut store = Memory::default();
        assert_eq!(
            begin(&mut backend, &mut store).unwrap(),
            BeginResult::Applied
        );
        assert!(backend.state.automatic);
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::Restored
        );
        assert_eq!(backend.state, original);
        assert!(store.0.is_none());
    }
    #[test]
    fn preserves_external_and_interrupted_changes() {
        let original = manual();
        let mut backend = Fake {
            state: original.clone(),
            fail_after_write: true,
        };
        let mut store = Memory::default();
        assert!(begin(&mut backend, &mut store).is_err());
        assert_eq!(store.0.as_ref().unwrap().phase, Phase::Armed);
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::Conflict
        );
        backend.state = original;
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::AlreadyOriginal
        );
        assert!(store.0.is_none());
    }
    #[test]
    fn refuses_unknown_paths_and_tampered_journals() {
        let mut unknown = manual();
        unknown.settings[0].name = r"C:\Other\pagefile.sys".into();
        assert!(normalize(unknown).is_err());
        let mut duplicate = manual();
        duplicate.settings.push(duplicate.settings[0].clone());
        assert!(normalize(duplicate).is_err());
        let mut backend = Fake {
            state: manual(),
            fail_after_write: false,
        };
        let mut store = Memory::default();
        begin(&mut backend, &mut store).unwrap();
        store
            .0
            .as_mut()
            .unwrap()
            .applied
            .as_mut()
            .unwrap()
            .automatic = false;
        assert!(restore(&mut backend, &mut store).is_err());
        assert!(backend.state.automatic);
    }
    #[test]
    fn archived_pagefile_backup_can_be_reactivated_after_restart() {
        use crate::storage::FileStore;
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("pagefile-store-{unique}"));
        let original = manual();
        let mut backend = Fake {
            state: original.clone(),
            fail_after_write: false,
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            begin(&mut backend, &mut store).unwrap();
            let archive = store.archive_pagefile().unwrap();
            let outside = directory.join("outside.json");
            std::fs::copy(&archive, &outside).unwrap();
            assert!(store.activate_pagefile(&outside).is_err());
            store.activate_pagefile(&archive).unwrap();
            assert!(store.activate_pagefile(&archive).is_err());
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                restore(&mut backend, &mut store).unwrap(),
                RestoreResult::Restored
            );
            assert_eq!(backend.state, original);
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
