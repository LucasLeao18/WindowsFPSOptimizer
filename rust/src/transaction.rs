//! Reversible changes. A journal is committed before the first system write.
//! Only known setting identifiers can be deserialized; paths are never trusted
//! from a journal file.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum Setting {
    GameMode,
    Transparency,
    GameCapturePolicy,
    WindowAnimations,
    ClientAreaAnimations,
    MenuAnimations,
    MenuFade,
    SelectionFade,
    TooltipAnimations,
    TooltipFade,
    ComboBoxAnimations,
    SmoothListScrolling,
}

impl Setting {
    pub fn is_system_parameter(self) -> bool {
        matches!(
            self,
            Self::WindowAnimations
                | Self::ClientAreaAnimations
                | Self::MenuAnimations
                | Self::MenuFade
                | Self::SelectionFade
                | Self::TooltipAnimations
                | Self::TooltipFade
                | Self::ComboBoxAnimations
                | Self::SmoothListScrolling
        )
    }
    pub fn description(self) -> &'static str {
        match self {
            Self::GameMode => "Modo de Jogo",
            Self::Transparency => "Transparência",
            Self::GameCapturePolicy => "Política de capturas",
            Self::WindowAnimations => "Animações de janelas",
            Self::ClientAreaAnimations => "Animações da interface",
            Self::MenuAnimations => "Animações de menus",
            Self::MenuFade => "Transição de menus",
            Self::SelectionFade => "Transição de seleção",
            Self::TooltipAnimations => "Animação de dicas",
            Self::TooltipFade => "Transição de dicas",
            Self::ComboBoxAnimations => "Animações de listas suspensas",
            Self::SmoothListScrolling => "Rolagem suave de listas",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Value {
    pub kind: u32,
    pub bytes: Vec<u8>,
}

impl Value {
    pub fn dword(value: u32) -> Self {
        Self {
            kind: 4,
            bytes: value.to_le_bytes().to_vec(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub setting: Setting,
    pub original: Option<Value>,
    pub applied: Value,
    #[serde(default)]
    pub phase: Phase,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    /// Older backups have no phase; ownership of a value is ambiguous.
    #[default]
    Uncertain,
    Pending,
    Armed,
    Applied,
    Reverting,
    Done,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Journal {
    pub schema: u32,
    pub entries: Vec<Entry>,
}

pub trait Backend {
    fn read(&mut self, setting: Setting) -> Result<Option<Value>, String>;
    fn write(&mut self, setting: Setting, value: &Value) -> Result<(), String>;
    fn delete(&mut self, setting: Setting) -> Result<(), String>;
}

pub trait Store {
    fn load(&mut self) -> Result<Option<Journal>, String>;
    fn save(&mut self, journal: &Journal) -> Result<(), String>;
    fn update(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear(&mut self) -> Result<(), String>;
}

#[derive(Debug, Eq, PartialEq)]
pub struct RestoreReport {
    pub restored: Vec<Setting>,
    pub already_original: Vec<Setting>,
    pub conflicts: Vec<Setting>,
    pub errors: Vec<(Setting, String)>,
}

pub fn prepare<B: Backend>(
    backend: &mut B,
    requested: &[(Setting, Value)],
) -> Result<Journal, String> {
    let mut seen = HashSet::new();
    let mut entries = Vec::new();
    for (setting, applied) in requested {
        if !seen.insert(*setting) {
            return Err("Configuração duplicada no plano.".into());
        }
        let original = backend.read(*setting)?;
        if original.as_ref() != Some(applied) {
            entries.push(Entry {
                setting: *setting,
                original,
                applied: applied.clone(),
                phase: Phase::Pending,
            });
        }
    }
    Ok(Journal { schema: 1, entries })
}

/// Refuses to overwrite an existing journal, including one left by a crash.
pub fn apply<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    journal: &Journal,
) -> Result<(), String> {
    validate(journal)?;
    if journal
        .entries
        .iter()
        .any(|entry| entry.phase != Phase::Pending)
    {
        return Err("O plano de alterações é inválido ou já foi usado.".into());
    }
    if store.load()?.is_some() {
        return Err("Existe uma operação anterior para revisar ou restaurar.".into());
    }
    if journal.entries.is_empty() {
        return Ok(());
    }
    // Detect a change made between preview and confirmation.
    for entry in &journal.entries {
        if backend.read(entry.setting)? != entry.original {
            return Err(format!(
                "A configuração {:?} mudou desde a análise.",
                entry.setting
            ));
        }
    }
    store.save(journal)?;
    let mut current_journal = journal.clone();
    for index in 0..current_journal.entries.len() {
        let entry = current_journal.entries[index].clone();
        // Another program can change a setting after the initial preflight.
        // Recheck as close to the write as possible and preserve conflicts.
        match backend.read(entry.setting) {
            Ok(current) if current == entry.original => {}
            result => {
                let rollback = restore(backend, store, &current_journal);
                return Err(format!(
                    "A configuração {:?} mudou ou não pôde ser lida antes da gravação: {result:?}. Restauração: {rollback:?}",
                    entry.setting
                ));
            }
        }
        let mut armed = current_journal.clone();
        armed.entries[index].phase = Phase::Armed;
        store.update(&current_journal, &armed)?;
        current_journal = armed;
        if let Err(err) = backend.write(entry.setting, &entry.applied) {
            // Keep the journal even if rollback fails or is interrupted.
            let rollback = restore(backend, store, &current_journal);
            return Err(format!(
                "Falha ao aplicar {:?}: {err}. Restauração: {rollback:?}",
                entry.setting
            ));
        }
        if !matches!(backend.read(entry.setting), Ok(Some(value)) if value == entry.applied) {
            let rollback = restore(backend, store, &current_journal);
            return Err(format!(
                "Não foi possível confirmar {:?}. Restauração: {rollback:?}",
                entry.setting
            ));
        }
        let mut applied = current_journal.clone();
        applied.entries[index].phase = Phase::Applied;
        store.update(&current_journal, &applied)?;
        current_journal = applied;
    }
    Ok(())
}

pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    journal: &Journal,
) -> Result<RestoreReport, String> {
    validate(journal)?;
    if store.load()?.as_ref() != Some(journal) {
        return Err("O backup mudou desde a leitura. Atualize e tente novamente.".into());
    }
    let mut report = RestoreReport {
        restored: vec![],
        already_original: vec![],
        conflicts: vec![],
        errors: vec![],
    };
    let mut current_journal = journal.clone();
    for index in (0..current_journal.entries.len()).rev() {
        let entry = current_journal.entries[index].clone();
        if entry.phase == Phase::Done {
            continue;
        }
        let current = match backend.read(entry.setting) {
            Ok(value) => value,
            Err(err) => {
                report.errors.push((entry.setting, err));
                continue;
            }
        };
        if current == entry.original {
            let mut done = current_journal.clone();
            done.entries[index].phase = Phase::Done;
            store.update(&current_journal, &done)?;
            current_journal = done;
            report.already_original.push(entry.setting);
        } else if entry.phase != Phase::Applied || current != Some(entry.applied.clone()) {
            report.conflicts.push(entry.setting);
        } else {
            let mut reverting = current_journal.clone();
            reverting.entries[index].phase = Phase::Reverting;
            store.update(&current_journal, &reverting)?;
            current_journal = reverting;
            let result = match &entry.original {
                Some(value) => backend.write(entry.setting, value),
                None => backend.delete(entry.setting),
            };
            match result.and_then(|_| backend.read(entry.setting)) {
                Ok(value) if value == entry.original => {
                    let mut done = current_journal.clone();
                    done.entries[index].phase = Phase::Done;
                    store.update(&current_journal, &done)?;
                    current_journal = done;
                    report.restored.push(entry.setting);
                }
                Ok(_) => report
                    .errors
                    .push((entry.setting, "Verificação da restauração falhou.".into())),
                Err(err) => report.errors.push((entry.setting, err)),
            }
        }
    }
    if report.conflicts.is_empty() && report.errors.is_empty() {
        store.clear()?;
    }
    Ok(report)
}

pub(crate) fn validate(journal: &Journal) -> Result<(), String> {
    if journal.schema != 1 || journal.entries.len() > 12 {
        return Err("Backup incompatível ou inválido.".into());
    }
    let mut seen = HashSet::new();
    for entry in &journal.entries {
        if !seen.insert(entry.setting)
            || entry.applied
                != Value::dword(match entry.setting {
                    Setting::GameMode => 1,
                    _ => 0,
                })
            || (entry.setting.is_system_parameter()
                && !matches!(entry.original.as_ref(), Some(value) if value == &Value::dword(0) || value == &Value::dword(1)))
            || entry
                .original
                .as_ref()
                .is_some_and(|v| v.bytes.len() > 1024 * 1024)
        {
            return Err("Backup incompatível ou inválido.".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Fake {
        values: HashMap<Setting, Value>,
        fail_on: Option<Setting>,
    }
    impl Backend for Fake {
        fn read(&mut self, s: Setting) -> Result<Option<Value>, String> {
            Ok(self.values.get(&s).cloned())
        }
        fn write(&mut self, s: Setting, v: &Value) -> Result<(), String> {
            if self.fail_on == Some(s) {
                self.fail_on = None;
                return Err("injected failure".into());
            }
            self.values.insert(s, v.clone());
            Ok(())
        }
        fn delete(&mut self, s: Setting) -> Result<(), String> {
            self.values.remove(&s);
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save(&mut self, j: &Journal) -> Result<(), String> {
            self.0 = Some(j.clone());
            Ok(())
        }
        fn update(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("journal changed".into());
            }
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    #[test]
    fn preserves_original_type_and_deletes_new_values() {
        let mut backend = Fake::default();
        let unusual = Value {
            kind: 1,
            bytes: vec![65, 0, 0, 0],
        };
        backend.values.insert(Setting::GameMode, unusual.clone());
        let plan = prepare(
            &mut backend,
            &[
                (Setting::GameMode, Value::dword(1)),
                (Setting::Transparency, Value::dword(0)),
            ],
        )
        .unwrap();
        let mut store = Memory::default();
        apply(&mut backend, &mut store, &plan).unwrap();
        let saved = store.load().unwrap().unwrap();
        let report = restore(&mut backend, &mut store, &saved).unwrap();
        assert_eq!(report.restored.len(), 2);
        assert_eq!(backend.values.get(&Setting::GameMode), Some(&unusual));
        assert!(!backend.values.contains_key(&Setting::Transparency));
        assert!(store.0.is_none());
    }
    #[test]
    fn refuses_to_overwrite_later_changes_and_keeps_journal() {
        let mut backend = Fake::default();
        let plan = prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap();
        let mut store = Memory::default();
        apply(&mut backend, &mut store, &plan).unwrap();
        backend.values.insert(Setting::GameMode, Value::dword(2));
        let saved = store.load().unwrap().unwrap();
        let result = restore(&mut backend, &mut store, &saved).unwrap();
        assert_eq!(result.conflicts, vec![Setting::GameMode]);
        assert_eq!(backend.values[&Setting::GameMode], Value::dword(2));
        assert!(store.0.is_some());
    }
    #[test]
    fn retry_does_not_undo_changes_after_partial_restoration() {
        let mut backend = Fake::default();
        let plan = prepare(
            &mut backend,
            &[
                (Setting::GameMode, Value::dword(1)),
                (Setting::Transparency, Value::dword(0)),
            ],
        )
        .unwrap();
        let mut store = Memory::default();
        apply(&mut backend, &mut store, &plan).unwrap();
        backend
            .values
            .insert(Setting::Transparency, Value::dword(7));
        let saved = store.load().unwrap().unwrap();
        let report = restore(&mut backend, &mut store, &saved).unwrap();
        assert_eq!(report.restored, vec![Setting::GameMode]);
        assert_eq!(report.conflicts, vec![Setting::Transparency]);
        backend.values.insert(Setting::GameMode, Value::dword(1));
        let saved = store.load().unwrap().unwrap();
        restore(&mut backend, &mut store, &saved).unwrap();
        assert_eq!(
            backend.values.get(&Setting::GameMode),
            Some(&Value::dword(1))
        );
    }
    #[test]
    fn interrupted_restoration_preserves_an_ambiguous_value() {
        let mut backend = Fake::default();
        let mut plan = prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap();
        plan.entries[0].phase = Phase::Reverting;
        backend.values.insert(Setting::GameMode, Value::dword(1));
        let mut store = Memory(Some(plan.clone()));
        assert_eq!(
            restore(&mut backend, &mut store, &plan).unwrap().conflicts,
            vec![Setting::GameMode]
        );
    }
    #[test]
    fn detects_stale_preview_before_any_write() {
        let mut backend = Fake::default();
        let plan = prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap();
        backend.values.insert(Setting::GameMode, Value::dword(0));
        let mut store = Memory::default();
        assert!(apply(&mut backend, &mut store, &plan).is_err());
        assert!(store.0.is_none());
        assert_eq!(backend.values[&Setting::GameMode], Value::dword(0));
    }
    #[test]
    fn preserves_an_external_change_between_preflight_and_write() {
        struct Racing {
            inner: Fake,
            reads: usize,
        }
        impl Backend for Racing {
            fn read(&mut self, setting: Setting) -> Result<Option<Value>, String> {
                if setting == Setting::Transparency {
                    self.reads += 1;
                    // prepare, preflight, then immediately before the second write
                    if self.reads == 3 {
                        self.inner.values.insert(setting, Value::dword(0));
                    }
                }
                self.inner.read(setting)
            }
            fn write(&mut self, setting: Setting, value: &Value) -> Result<(), String> {
                self.inner.write(setting, value)
            }
            fn delete(&mut self, setting: Setting) -> Result<(), String> {
                self.inner.delete(setting)
            }
        }
        let mut backend = Racing {
            inner: Fake::default(),
            reads: 0,
        };
        let plan = prepare(
            &mut backend,
            &[
                (Setting::GameMode, Value::dword(1)),
                (Setting::Transparency, Value::dword(0)),
            ],
        )
        .unwrap();
        let mut store = Memory::default();
        assert!(apply(&mut backend, &mut store, &plan).is_err());
        assert_eq!(
            backend.inner.values.get(&Setting::Transparency),
            Some(&Value::dword(0))
        );
        assert!(!backend.inner.values.contains_key(&Setting::GameMode));
        assert!(store.0.is_some());
    }
    #[test]
    fn failed_write_rolls_back_earlier_entries() {
        let mut backend = Fake::default();
        let plan = prepare(
            &mut backend,
            &[
                (Setting::GameMode, Value::dword(1)),
                (Setting::Transparency, Value::dword(0)),
            ],
        )
        .unwrap();
        backend.fail_on = Some(Setting::Transparency);
        let mut store = Memory::default();
        assert!(apply(&mut backend, &mut store, &plan).is_err());
        assert!(backend.values.is_empty());
        assert!(store.0.is_none());
    }
    #[test]
    fn restoration_rejects_a_journal_that_is_not_current() {
        let mut backend = Fake::default();
        let plan = prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap();
        let mut store = Memory(None);
        backend.values.insert(Setting::GameMode, Value::dword(1));
        assert!(restore(&mut backend, &mut store, &plan).is_err());
        assert_eq!(backend.values[&Setting::GameMode], Value::dword(1));
    }
    #[test]
    fn uncertain_crash_preserves_a_value_that_may_be_external() {
        let mut backend = Fake::default();
        let plan = prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap();
        let mut uncertain = plan.clone();
        uncertain.entries[0].phase = Phase::Armed;
        let mut store = Memory(Some(uncertain.clone()));
        backend.write(Setting::GameMode, &Value::dword(1)).unwrap();
        assert_eq!(
            restore(&mut backend, &mut store, &uncertain)
                .unwrap()
                .conflicts,
            vec![Setting::GameMode]
        );
        assert!(store.0.is_some());
        assert_eq!(
            backend.values.get(&Setting::GameMode),
            Some(&Value::dword(1))
        );
    }
    #[test]
    fn older_journal_without_phase_is_treated_as_uncertain() {
        let raw = r#"{"schema":1,"entries":[{"setting":"GameMode","original":null,"applied":{"kind":4,"bytes":[1,0,0,0]}}]}"#;
        let journal: Journal = serde_json::from_str(raw).unwrap();
        assert_eq!(journal.entries[0].phase, Phase::Uncertain);
        let mut backend = Fake::default();
        backend.values.insert(Setting::GameMode, Value::dword(1));
        let mut store = Memory(Some(journal.clone()));
        assert_eq!(
            restore(&mut backend, &mut store, &journal)
                .unwrap()
                .conflicts,
            vec![Setting::GameMode]
        );
    }
    #[test]
    fn rejects_tampered_target_values() {
        let mut backend = Fake::default();
        let mut store = Memory::default();
        let tampered = Journal {
            schema: 1,
            entries: vec![Entry {
                setting: Setting::GameMode,
                original: None,
                applied: Value::dword(0),
                phase: Phase::Pending,
            }],
        };
        assert!(apply(&mut backend, &mut store, &tampered).is_err());
        assert!(backend.values.is_empty());
    }
}
