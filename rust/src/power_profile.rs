//! Recoverable, persistent power change used by the Maximum profile. Unlike the
//! game session, it is not tied to a process: it stays until restored.
//!
//! Desktops usually offer the built-in High Performance plan. Many laptops
//! (Modern Standby) only offer Balanced; there the Windows power mode
//! ("Best performance" overlay) is the supported equivalent.
use crate::power_session::{HIGH_PERFORMANCE, Scheme};
use serde::{Deserialize, Serialize};

pub const BALANCED: Scheme = Scheme {
    data1: 0x381b4222,
    data2: 0xf694,
    data3: 0x41f0,
    data4: [0x96, 0x85, 0xff, 0x5b, 0xb2, 0x60, 0xdf, 0x2e],
};
/// Power mode "Best performance".
pub const BEST_PERFORMANCE: Scheme = Scheme {
    data1: 0xded574b5,
    data2: 0x45a0,
    data3: 0x4f42,
    data4: [0x87, 0x37, 0x46, 0x34, 0x5c, 0x09, 0xc2, 0x38],
};
const ZERO: Scheme = Scheme {
    data1: 0,
    data2: 0,
    data3: 0,
    data4: [0; 8],
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Kind {
    /// The active power plan.
    Plan,
    /// The power mode overlay on top of the Balanced plan.
    Mode,
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
    pub kind: Kind,
    pub original: Scheme,
    pub applied: Scheme,
    pub phase: Phase,
}

pub trait Backend {
    fn active_plan(&mut self) -> Result<Scheme, String>;
    fn plan_available(&mut self, plan: Scheme) -> Result<bool, String>;
    fn set_plan(&mut self, expected: Scheme, target: Scheme) -> Result<(), String>;
    /// `None` when this Windows does not expose the power mode.
    fn mode(&mut self) -> Result<Option<Scheme>, String>;
    fn set_mode(&mut self, expected: Scheme, target: Scheme) -> Result<(), String>;
}

pub trait Store {
    fn load_power_profile(&mut self) -> Result<Option<Journal>, String>;
    fn save_power_profile(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_power_profile(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_power_profile(&mut self) -> Result<(), String>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Plan {
    /// Already at the highest available setting.
    AlreadyMaximum,
    /// Neither the High Performance plan nor the power mode is available, or a
    /// custom plan is active (it is never replaced automatically).
    Unavailable,
    Change {
        kind: Kind,
        from: Scheme,
        to: Scheme,
    },
}

#[derive(Debug, Eq, PartialEq)]
pub enum RestoreResult {
    Restored,
    AlreadyOriginal,
    Conflict,
}

/// Decides the change without writing anything.
pub fn plan<B: Backend>(backend: &mut B) -> Result<Plan, String> {
    let active = backend.active_plan()?;
    if active == ZERO {
        return Err("Plano de energia atual inválido.".into());
    }
    if active == HIGH_PERFORMANCE {
        return Ok(Plan::AlreadyMaximum);
    }
    if active != BALANCED {
        // A custom or manufacturer plan may hold deliberate thermal limits.
        return Ok(Plan::Unavailable);
    }
    if backend.plan_available(HIGH_PERFORMANCE)? {
        return Ok(Plan::Change {
            kind: Kind::Plan,
            from: active,
            to: HIGH_PERFORMANCE,
        });
    }
    match backend.mode()? {
        Some(mode) if mode == BEST_PERFORMANCE => Ok(Plan::AlreadyMaximum),
        Some(mode) => Ok(Plan::Change {
            kind: Kind::Mode,
            from: mode,
            to: BEST_PERFORMANCE,
        }),
        None => Ok(Plan::Unavailable),
    }
}

pub fn validate(journal: &Journal) -> Result<(), String> {
    let valid = journal.schema == 1
        && journal.original != journal.applied
        && match journal.kind {
            Kind::Plan => journal.original == BALANCED && journal.applied == HIGH_PERFORMANCE,
            Kind::Mode => journal.applied == BEST_PERFORMANCE,
        };
    if !valid {
        return Err("Backup de energia inválido.".into());
    }
    Ok(())
}

fn read<B: Backend>(backend: &mut B, kind: Kind) -> Result<Scheme, String> {
    match kind {
        Kind::Plan => backend.active_plan(),
        Kind::Mode => {
            if backend.active_plan()? != BALANCED {
                return Err("O plano de energia mudou; o modo de energia não foi alterado.".into());
            }
            backend
                .mode()?
                .ok_or_else(|| "O modo de energia não está disponível.".to_string())
        }
    }
}

fn write<B: Backend>(
    backend: &mut B,
    kind: Kind,
    expected: Scheme,
    target: Scheme,
) -> Result<(), String> {
    match kind {
        Kind::Plan => backend.set_plan(expected, target),
        Kind::Mode => backend.set_mode(expected, target),
    }
}

/// Applies a change returned by [`plan`]; refuses if the state moved since.
pub fn begin<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    kind: Kind,
    from: Scheme,
    to: Scheme,
) -> Result<(), String> {
    if store.load_power_profile()?.is_some() {
        return Err("Há um backup de energia anterior para restaurar.".into());
    }
    let mut journal = Journal {
        schema: 1,
        kind,
        original: from,
        applied: to,
        phase: Phase::Pending,
    };
    validate(&journal)?;
    if read(backend, kind)? != from {
        return Err("A configuração de energia mudou desde a análise.".into());
    }
    store.save_power_profile(&journal)?;
    let mut armed = journal.clone();
    armed.phase = Phase::Armed;
    store.update_power_profile(&journal, &armed)?;
    journal = armed;
    write(backend, kind, from, to)?;
    if read(backend, kind)? != to {
        return Err(
            "Não foi possível confirmar a configuração de energia; o backup foi preservado.".into(),
        );
    }
    let mut applied = journal.clone();
    applied.phase = Phase::Applied;
    store.update_power_profile(&journal, &applied)?;
    Ok(())
}

pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
) -> Result<RestoreResult, String> {
    let journal = store
        .load_power_profile()?
        .ok_or("Não há backup de energia.")?;
    validate(&journal)?;
    let current = match read(backend, journal.kind) {
        Ok(current) => current,
        Err(_) => return Ok(RestoreResult::Conflict),
    };
    if current == journal.original {
        store.clear_power_profile()?;
        return Ok(RestoreResult::AlreadyOriginal);
    }
    // Armed means the write may or may not have happened: only an exact match
    // with the applied value proves the current state came from this app.
    if !matches!(journal.phase, Phase::Applied | Phase::Armed) || current != journal.applied {
        return Ok(RestoreResult::Conflict);
    }
    let mut reverting = journal.clone();
    reverting.phase = Phase::Reverting;
    store.update_power_profile(&journal, &reverting)?;
    write(backend, journal.kind, journal.applied, journal.original)?;
    if read(backend, journal.kind)? != journal.original {
        return Err(
            "Não foi possível confirmar a energia restaurada; o backup foi preservado.".into(),
        );
    }
    store.clear_power_profile()?;
    Ok(RestoreResult::Restored)
}

#[cfg(test)]
mod tests {
    use super::*;
    const CUSTOM: Scheme = Scheme {
        data1: 7,
        data2: 7,
        data3: 7,
        data4: [7; 8],
    };
    struct Fake {
        plans: Vec<Scheme>,
        active: Scheme,
        mode: Option<Scheme>,
        fail_write: bool,
    }
    impl Backend for Fake {
        fn active_plan(&mut self) -> Result<Scheme, String> {
            Ok(self.active)
        }
        fn plan_available(&mut self, plan: Scheme) -> Result<bool, String> {
            Ok(self.plans.contains(&plan))
        }
        fn set_plan(&mut self, expected: Scheme, target: Scheme) -> Result<(), String> {
            assert_eq!(self.active, expected);
            if self.fail_write {
                return Err("denied".into());
            }
            self.active = target;
            Ok(())
        }
        fn mode(&mut self) -> Result<Option<Scheme>, String> {
            Ok(self.mode)
        }
        fn set_mode(&mut self, expected: Scheme, target: Scheme) -> Result<(), String> {
            assert_eq!(self.mode, Some(expected));
            if self.fail_write {
                return Err("denied".into());
            }
            self.mode = Some(target);
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_power_profile(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_power_profile(&mut self, j: &Journal) -> Result<(), String> {
            assert!(self.0.is_none());
            self.0 = Some(j.clone());
            Ok(())
        }
        fn update_power_profile(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            assert_eq!(self.0.as_ref(), Some(old));
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_power_profile(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    fn desktop() -> Fake {
        Fake {
            plans: vec![BALANCED, HIGH_PERFORMANCE],
            active: BALANCED,
            mode: Some(ZERO),
            fail_write: false,
        }
    }
    fn laptop() -> Fake {
        Fake {
            plans: vec![BALANCED],
            active: BALANCED,
            mode: Some(ZERO),
            fail_write: false,
        }
    }
    fn apply(backend: &mut Fake, store: &mut Memory) -> Result<(), String> {
        let Plan::Change { kind, from, to } = plan(backend)? else {
            panic!("expected a change");
        };
        begin(backend, store, kind, from, to)
    }
    #[test]
    fn desktop_switches_plan_and_restores() {
        let (mut backend, mut store) = (desktop(), Memory::default());
        apply(&mut backend, &mut store).unwrap();
        assert_eq!(backend.active, HIGH_PERFORMANCE);
        assert_eq!(plan(&mut backend).unwrap(), Plan::AlreadyMaximum);
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::Restored
        );
        assert_eq!(backend.active, BALANCED);
        assert!(store.0.is_none());
    }
    #[test]
    fn laptop_without_plan_uses_power_mode_and_restores() {
        let (mut backend, mut store) = (laptop(), Memory::default());
        apply(&mut backend, &mut store).unwrap();
        assert_eq!(backend.active, BALANCED);
        assert_eq!(backend.mode, Some(BEST_PERFORMANCE));
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::Restored
        );
        assert_eq!(backend.mode, Some(ZERO));
    }
    #[test]
    fn custom_plans_and_missing_mode_are_left_alone() {
        let mut custom = desktop();
        custom.active = CUSTOM;
        assert_eq!(plan(&mut custom).unwrap(), Plan::Unavailable);
        let mut old = laptop();
        old.mode = None;
        assert_eq!(plan(&mut old).unwrap(), Plan::Unavailable);
        let mut best = laptop();
        best.mode = Some(BEST_PERFORMANCE);
        assert_eq!(plan(&mut best).unwrap(), Plan::AlreadyMaximum);
    }
    #[test]
    fn external_changes_are_preserved() {
        let (mut backend, mut store) = (desktop(), Memory::default());
        apply(&mut backend, &mut store).unwrap();
        backend.active = CUSTOM;
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::Conflict
        );
        assert_eq!(backend.active, CUSTOM);
        assert!(store.0.is_some());
        backend.active = BALANCED;
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::AlreadyOriginal
        );
        assert!(store.0.is_none());
    }
    #[test]
    fn failed_write_leaves_a_clearable_record_and_stale_plans_are_refused() {
        let (mut backend, mut store) = (laptop(), Memory::default());
        backend.fail_write = true;
        assert!(apply(&mut backend, &mut store).is_err());
        assert_eq!(store.0.as_ref().unwrap().phase, Phase::Armed);
        assert_eq!(
            restore(&mut backend, &mut store).unwrap(),
            RestoreResult::AlreadyOriginal
        );
        let mut backend = laptop();
        assert!(
            begin(
                &mut backend,
                &mut store,
                Kind::Mode,
                BEST_PERFORMANCE,
                BEST_PERFORMANCE
            )
            .is_err()
        );
        backend.mode = Some(CUSTOM);
        assert!(begin(&mut backend, &mut store, Kind::Mode, ZERO, BEST_PERFORMANCE).is_err());
        assert!(store.0.is_none());
    }
    #[test]
    fn tampered_journals_are_rejected() {
        let mut store = Memory(Some(Journal {
            schema: 1,
            kind: Kind::Plan,
            original: BALANCED,
            applied: CUSTOM,
            phase: Phase::Applied,
        }));
        assert!(restore(&mut desktop(), &mut store).is_err());
    }
}
