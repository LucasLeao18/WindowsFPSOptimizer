//! Recoverable power-saving overrides on the active power plan (plugged-in
//! values only), as offered by gaming boosters: no core parking, no PCI
//! Express link power saving and no USB selective suspend.
use crate::power_session::Scheme;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum Setting {
    /// Processor performance core parking minimum cores (percent).
    CoreParkingMinimum,
    /// PCI Express Link State Power Management.
    PcieLinkPower,
    /// USB selective suspend.
    UsbSelectiveSuspend,
}

impl Setting {
    pub const ALL: [Self; 3] = [
        Self::CoreParkingMinimum,
        Self::PcieLinkPower,
        Self::UsbSelectiveSuspend,
    ];
    pub fn description(self) -> &'static str {
        match self {
            Self::CoreParkingMinimum => "Estacionamento de núcleos da CPU",
            Self::PcieLinkPower => "Economia de energia do PCI Express",
            Self::UsbSelectiveSuspend => "Suspensão seletiva de USB",
        }
    }
    /// The value that disables the power saving.
    pub fn target(self) -> u32 {
        match self {
            Self::CoreParkingMinimum => 100,
            Self::PcieLinkPower | Self::UsbSelectiveSuspend => 0,
        }
    }
    /// (subgroup, setting) GUIDs.
    pub fn ids(self) -> (Scheme, Scheme) {
        const fn g(data1: u32, data2: u16, data3: u16, data4: [u8; 8]) -> Scheme {
            Scheme {
                data1,
                data2,
                data3,
                data4,
            }
        }
        match self {
            Self::CoreParkingMinimum => (
                g(
                    0x54533251,
                    0x82be,
                    0x4824,
                    [0x96, 0xc1, 0x47, 0xb6, 0x0b, 0x74, 0x0d, 0x00],
                ),
                g(
                    0x0cc5b647,
                    0xc1df,
                    0x4637,
                    [0x89, 0x1a, 0xde, 0xc3, 0x5c, 0x31, 0x85, 0x83],
                ),
            ),
            Self::PcieLinkPower => (
                g(
                    0x501a4d13,
                    0x42af,
                    0x4429,
                    [0x9f, 0xd1, 0xa8, 0x21, 0x8c, 0x26, 0x8e, 0x20],
                ),
                g(
                    0xee12f906,
                    0xd277,
                    0x404b,
                    [0xb6, 0xda, 0xe5, 0xfa, 0x1a, 0x57, 0x6d, 0xf5],
                ),
            ),
            Self::UsbSelectiveSuspend => (
                g(
                    0x2a737441,
                    0x1930,
                    0x4402,
                    [0x8d, 0x77, 0xb2, 0xbe, 0xbb, 0xa3, 0x08, 0xa3],
                ),
                g(
                    0x48e6b7a6,
                    0x50f5,
                    0x4782,
                    [0xa5, 0xd4, 0x53, 0xbb, 0x8f, 0x07, 0xe2, 0x26],
                ),
            ),
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
    pub setting: Setting,
    pub original: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Journal {
    pub schema: u32,
    pub plan: Scheme,
    pub entries: Vec<Entry>,
    pub phase: Phase,
}

pub trait Backend {
    /// `None` when the plan does not expose the setting.
    fn read(&mut self, plan: Scheme, setting: Setting) -> Result<Option<u32>, String>;
    fn write(&mut self, plan: Scheme, setting: Setting, value: u32) -> Result<(), String>;
    /// Makes written values effective when `plan` is the active plan.
    fn commit(&mut self, plan: Scheme) -> Result<(), String>;
}

pub trait Store {
    fn load_power_settings(&mut self) -> Result<Option<Journal>, String>;
    fn save_power_settings(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_power_settings(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_power_settings(&mut self) -> Result<(), String>;
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct RestoreReport {
    pub restored: usize,
    pub conflicts: Vec<Setting>,
}

/// Settings of `plan` that are not yet at their target value.
pub fn pending<B: Backend>(
    backend: &mut B,
    plan: Scheme,
    allowed: &[Setting],
) -> Result<Vec<Setting>, String> {
    let mut changes = Vec::new();
    for setting in allowed {
        if let Some(value) = backend.read(plan, *setting)?
            && value != setting.target()
        {
            changes.push(*setting);
        }
    }
    Ok(changes)
}

fn validate(journal: &Journal) -> Result<(), String> {
    let mut seen = std::collections::HashSet::new();
    if journal.schema != 1
        || journal.entries.is_empty()
        || journal.entries.len() > Setting::ALL.len()
        || !journal
            .entries
            .iter()
            .all(|entry| seen.insert(entry.setting))
    {
        return Err("Backup de ajustes de energia inválido.".into());
    }
    Ok(())
}

pub fn begin<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    plan: Scheme,
    settings: &[Setting],
) -> Result<usize, String> {
    if store.load_power_settings()?.is_some() {
        return Err("Há um backup de ajustes de energia anterior para restaurar.".into());
    }
    let mut entries = Vec::new();
    for setting in settings {
        if let Some(original) = backend.read(plan, *setting)?
            && original != setting.target()
        {
            entries.push(Entry {
                setting: *setting,
                original,
            });
        }
    }
    if entries.is_empty() {
        return Ok(0);
    }
    let journal = Journal {
        schema: 1,
        plan,
        entries,
        phase: Phase::Pending,
    };
    validate(&journal)?;
    store.save_power_settings(&journal)?;
    let mut armed = journal.clone();
    armed.phase = Phase::Armed;
    store.update_power_settings(&journal, &armed)?;
    // A driver may lock a setting's range (AMD X3D does for core parking).
    // A refused write that left the value untouched is skipped, not fatal.
    let mut written = Vec::new();
    for entry in &armed.entries {
        match backend.write(plan, entry.setting, entry.setting.target()) {
            Ok(()) => written.push(entry.clone()),
            Err(error) => {
                if backend.read(plan, entry.setting)? != Some(entry.original) {
                    return Err(format!("{error} O backup foi preservado."));
                }
            }
        }
    }
    if written.is_empty() {
        store.clear_power_settings()?;
        return Ok(0);
    }
    backend.commit(plan)?;
    for entry in &written {
        if backend.read(plan, entry.setting)? != Some(entry.setting.target()) {
            return Err(
                "Não foi possível confirmar os ajustes de energia; o backup foi preservado.".into(),
            );
        }
    }
    let mut applied = armed.clone();
    applied.entries = written;
    applied.phase = Phase::Applied;
    store.update_power_settings(&armed, &applied)?;
    Ok(applied.entries.len())
}

/// Restores each value still at the applied target; values changed by someone
/// else are preserved and reported.
pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
) -> Result<RestoreReport, String> {
    let journal = store
        .load_power_settings()?
        .ok_or("Não há backup de ajustes de energia.")?;
    validate(&journal)?;
    let mut report = RestoreReport::default();
    let mut remaining = Vec::new();
    for entry in &journal.entries {
        match backend.read(journal.plan, entry.setting) {
            Ok(Some(value)) if value == entry.original => {}
            Ok(Some(value)) if value == entry.setting.target() => {
                backend.write(journal.plan, entry.setting, entry.original)?;
                report.restored += 1;
            }
            // The plan was deleted or the value changed elsewhere.
            Ok(None) => {}
            _ => {
                report.conflicts.push(entry.setting);
                remaining.push(entry.clone());
            }
        }
    }
    if report.restored > 0 {
        backend.commit(journal.plan)?;
    }
    if remaining.is_empty() {
        store.clear_power_settings()?;
    } else {
        let mut kept = journal.clone();
        kept.entries = remaining;
        store.update_power_settings(&journal, &kept)?;
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    const PLAN: Scheme = Scheme {
        data1: 1,
        data2: 2,
        data3: 3,
        data4: [4; 8],
    };
    #[derive(Default)]
    struct Fake(HashMap<Setting, u32>, usize, Vec<Setting>);
    impl Backend for Fake {
        fn read(&mut self, plan: Scheme, setting: Setting) -> Result<Option<u32>, String> {
            assert_eq!(plan, PLAN);
            Ok(self.0.get(&setting).copied())
        }
        fn write(&mut self, _: Scheme, setting: Setting, value: u32) -> Result<(), String> {
            if self.2.contains(&setting) {
                return Err("locked".into());
            }
            self.0.insert(setting, value);
            Ok(())
        }
        fn commit(&mut self, _: Scheme) -> Result<(), String> {
            self.1 += 1;
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_power_settings(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_power_settings(&mut self, j: &Journal) -> Result<(), String> {
            self.0 = Some(j.clone());
            Ok(())
        }
        fn update_power_settings(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            assert_eq!(self.0.as_ref(), Some(old));
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_power_settings(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    fn saving() -> Fake {
        let mut fake = Fake::default();
        fake.0.insert(Setting::CoreParkingMinimum, 10);
        fake.0.insert(Setting::PcieLinkPower, 2);
        fake.0.insert(Setting::UsbSelectiveSuspend, 0);
        fake
    }
    #[test]
    fn applies_only_needed_values_and_restores_them() {
        let (mut backend, mut store) = (saving(), Memory::default());
        assert_eq!(
            pending(&mut backend, PLAN, &Setting::ALL).unwrap(),
            vec![Setting::CoreParkingMinimum, Setting::PcieLinkPower]
        );
        assert_eq!(
            begin(&mut backend, &mut store, PLAN, &Setting::ALL).unwrap(),
            2
        );
        assert_eq!(backend.0[&Setting::CoreParkingMinimum], 100);
        assert_eq!(backend.0[&Setting::PcieLinkPower], 0);
        let report = restore(&mut backend, &mut store).unwrap();
        assert_eq!(report.restored, 2);
        assert_eq!(backend.0[&Setting::CoreParkingMinimum], 10);
        assert_eq!(backend.0[&Setting::PcieLinkPower], 2);
        assert!(store.0.is_none());
    }
    #[test]
    fn keeps_external_changes_and_skips_missing_settings() {
        let (mut backend, mut store) = (saving(), Memory::default());
        backend.0.remove(&Setting::UsbSelectiveSuspend);
        begin(
            &mut backend,
            &mut store,
            PLAN,
            &[Setting::PcieLinkPower, Setting::UsbSelectiveSuspend],
        )
        .unwrap();
        backend.0.insert(Setting::PcieLinkPower, 1);
        let report = restore(&mut backend, &mut store).unwrap();
        assert_eq!(report.conflicts, vec![Setting::PcieLinkPower]);
        assert_eq!(backend.0[&Setting::PcieLinkPower], 1);
        assert!(store.0.is_some());
        backend.0.insert(Setting::PcieLinkPower, 2);
        assert!(
            restore(&mut backend, &mut store)
                .unwrap()
                .conflicts
                .is_empty()
        );
        assert!(store.0.is_none());
    }
    #[test]
    fn nothing_to_change_creates_no_backup() {
        let (mut backend, mut store) = (saving(), Memory::default());
        assert_eq!(
            begin(
                &mut backend,
                &mut store,
                PLAN,
                &[Setting::UsbSelectiveSuspend]
            )
            .unwrap(),
            0
        );
        assert!(store.0.is_none());
        assert_eq!(backend.1, 0);
    }
    #[test]
    fn a_locked_setting_is_skipped_without_blocking_the_others() {
        let (mut backend, mut store) = (saving(), Memory::default());
        backend.2.push(Setting::CoreParkingMinimum);
        assert_eq!(
            begin(&mut backend, &mut store, PLAN, &Setting::ALL).unwrap(),
            1
        );
        assert_eq!(backend.0[&Setting::CoreParkingMinimum], 10);
        assert_eq!(backend.0[&Setting::PcieLinkPower], 0);
        assert_eq!(store.0.as_ref().unwrap().entries.len(), 1);
        restore(&mut backend, &mut store).unwrap();
        assert_eq!(backend.0[&Setting::PcieLinkPower], 2);
        let (mut backend, mut store) = (saving(), Memory::default());
        backend.2.extend(Setting::ALL);
        assert_eq!(
            begin(&mut backend, &mut store, PLAN, &Setting::ALL).unwrap(),
            0
        );
        assert!(store.0.is_none());
    }
}
