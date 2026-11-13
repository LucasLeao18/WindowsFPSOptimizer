//! Recoverable temporary power-plan switch. A backend must use platform APIs;
//! the journal never contains commands or executable paths.
use crate::session::ProcessIdentity;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Scheme {
    pub data1: u32,
    pub data2: u16,
    pub data3: u16,
    pub data4: [u8; 8],
}

/// The built-in High Performance scheme, when present on the machine.
pub const HIGH_PERFORMANCE: Scheme = Scheme {
    data1: 0x8c5e7fda,
    data2: 0xe8bf,
    data3: 0x4a96,
    data4: [0x9a, 0x85, 0xa6, 0xe2, 0x3a, 0x8c, 0x63, 0x5c],
};
const ZERO: Scheme = Scheme {
    data1: 0,
    data2: 0,
    data3: 0,
    data4: [0; 8],
};

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
    pub process: ProcessIdentity,
    pub original: Scheme,
    pub applied: Scheme,
    pub phase: Phase,
}

pub trait Backend {
    fn active(&mut self) -> Result<Scheme, String>;
    fn available(&mut self, scheme: Scheme) -> Result<bool, String>;
    fn set_active(&mut self, expected: Scheme, target: Scheme) -> Result<(), String>;
}

pub trait Store {
    fn load_power(&mut self) -> Result<Option<Journal>, String>;
    fn save_power(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_power(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_power(&mut self) -> Result<(), String>;
}

#[derive(Debug, Eq, PartialEq)]
pub enum BeginResult {
    AlreadyActive,
    Unavailable,
    Applied,
}
#[derive(Debug, Eq, PartialEq)]
pub enum EndResult {
    Restored,
    AlreadyOriginal,
    Conflict,
}

fn validate(journal: &Journal) -> Result<(), String> {
    if journal.schema != 1
        || journal.process.pid == 0
        || journal.process.created == 0
        || journal.original == ZERO
        || journal.original == HIGH_PERFORMANCE
        || journal.applied != HIGH_PERFORMANCE
    {
        return Err("Registro de energia inválido.".into());
    }
    Ok(())
}

/// Existing high-performance plans are used as-is. No plan is created or modified.
pub fn begin<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    process: ProcessIdentity,
) -> Result<BeginResult, String> {
    if process.pid == 0 || process.created == 0 {
        return Err("Identidade do jogo inválida.".into());
    }
    if store.load_power()?.is_some() {
        return Err("Há um registro de energia anterior para restaurar.".into());
    }
    let original = backend.active()?;
    if original == ZERO {
        return Err("Plano de energia atual inválido.".into());
    }
    if original == HIGH_PERFORMANCE {
        return Ok(BeginResult::AlreadyActive);
    }
    if !backend.available(HIGH_PERFORMANCE)? {
        return Ok(BeginResult::Unavailable);
    }
    let mut journal = Journal {
        schema: 1,
        process,
        original,
        applied: HIGH_PERFORMANCE,
        phase: Phase::Pending,
    };
    store.save_power(&journal)?;
    if backend.active()? != original {
        return Err(
            "O plano de energia mudou durante a análise; o registro foi preservado.".into(),
        );
    }
    let mut armed = journal.clone();
    armed.phase = Phase::Armed;
    store.update_power(&journal, &armed)?;
    journal = armed;
    backend.set_active(original, HIGH_PERFORMANCE)?;
    if backend.active()? != HIGH_PERFORMANCE {
        return Err(
            "Não foi possível confirmar o plano de energia; o registro foi preservado.".into(),
        );
    }
    let mut applied = journal.clone();
    applied.phase = Phase::Applied;
    store.update_power(&journal, &applied)?;
    Ok(BeginResult::Applied)
}

pub fn end<B: Backend, S: Store>(backend: &mut B, store: &mut S) -> Result<EndResult, String> {
    let journal = store
        .load_power()?
        .ok_or("Não há registro de energia para restaurar.")?;
    validate(&journal)?;
    let current = backend.active()?;
    if current == journal.original {
        store.clear_power()?;
        return Ok(EndResult::AlreadyOriginal);
    }
    // Armed/Reverting can represent an interrupted write or an external change.
    if current != journal.applied || journal.phase != Phase::Applied {
        return Ok(EndResult::Conflict);
    }
    if !backend.available(journal.original)? {
        return Err("O plano original não está mais disponível; o registro foi preservado.".into());
    }
    let mut reverting = journal.clone();
    reverting.phase = Phase::Reverting;
    store.update_power(&journal, &reverting)?;
    backend.set_active(journal.applied, journal.original)?;
    if backend.active()? != journal.original {
        return Err("Não foi possível confirmar a restauração do plano de energia.".into());
    }
    store.clear_power()?;
    Ok(EndResult::Restored)
}

#[cfg(test)]
mod tests {
    use super::*;
    const ORIGINAL: Scheme = Scheme {
        data1: 1,
        data2: 2,
        data3: 3,
        data4: [4; 8],
    };
    const OTHER: Scheme = Scheme {
        data1: 9,
        ..ORIGINAL
    };
    const GAME: ProcessIdentity = ProcessIdentity {
        pid: 123,
        created: 456,
    };
    struct Fake {
        active: Scheme,
        available: bool,
    }
    impl Backend for Fake {
        fn active(&mut self) -> Result<Scheme, String> {
            Ok(self.active)
        }
        fn available(&mut self, _: Scheme) -> Result<bool, String> {
            Ok(self.available)
        }
        fn set_active(&mut self, expected: Scheme, target: Scheme) -> Result<(), String> {
            if self.active != expected {
                return Err("changed".into());
            }
            self.active = target;
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_power(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_power(&mut self, value: &Journal) -> Result<(), String> {
            if self.0.is_some() {
                return Err("exists".into());
            }
            self.0 = Some(value.clone());
            Ok(())
        }
        fn update_power(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("changed".into());
            }
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_power(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    #[test]
    fn switches_and_restores_the_exact_original_plan() {
        let mut backend = Fake {
            active: ORIGINAL,
            available: true,
        };
        let mut store = Memory::default();
        assert_eq!(
            begin(&mut backend, &mut store, GAME).unwrap(),
            BeginResult::Applied
        );
        assert_eq!(backend.active, HIGH_PERFORMANCE);
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Restored);
        assert_eq!(backend.active, ORIGINAL);
        assert!(store.0.is_none());
    }
    #[test]
    fn absent_or_active_plan_does_not_create_a_journal() {
        let mut backend = Fake {
            active: ORIGINAL,
            available: false,
        };
        let mut store = Memory::default();
        assert_eq!(
            begin(&mut backend, &mut store, GAME).unwrap(),
            BeginResult::Unavailable
        );
        backend.active = HIGH_PERFORMANCE;
        assert_eq!(
            begin(&mut backend, &mut store, GAME).unwrap(),
            BeginResult::AlreadyActive
        );
        assert!(store.0.is_none());
    }
    #[test]
    fn external_and_ambiguous_changes_are_never_overwritten() {
        let mut backend = Fake {
            active: ORIGINAL,
            available: true,
        };
        let mut store = Memory::default();
        begin(&mut backend, &mut store, GAME).unwrap();
        backend.active = OTHER;
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Conflict);
        assert_eq!(backend.active, OTHER);
        backend.active = HIGH_PERFORMANCE;
        store.0.as_mut().unwrap().phase = Phase::Armed;
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Conflict);
        assert_eq!(backend.active, HIGH_PERFORMANCE);
        assert!(store.0.is_some());
    }
    #[test]
    fn missing_original_keeps_backup_and_current_plan() {
        let mut backend = Fake {
            active: ORIGINAL,
            available: true,
        };
        let mut store = Memory::default();
        begin(&mut backend, &mut store, GAME).unwrap();
        backend.available = false;
        assert!(end(&mut backend, &mut store).is_err());
        assert_eq!(backend.active, HIGH_PERFORMANCE);
        assert!(store.0.is_some());
    }
}
