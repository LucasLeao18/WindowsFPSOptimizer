//! Temporary visual changes for a game session, kept in a separate journal.
use crate::transaction::{self, Backend, Journal, RestoreReport, Setting, Store, Value};

const SETTINGS: &[Setting] = &[
    Setting::Transparency,
    Setting::WindowAnimations,
    Setting::ClientAreaAnimations,
    Setting::MenuAnimations,
    Setting::MenuFade,
    Setting::SelectionFade,
    Setting::TooltipAnimations,
    Setting::TooltipFade,
    Setting::ComboBoxAnimations,
    Setting::SmoothListScrolling,
    Setting::CursorShadow,
    Setting::DropShadows,
    // Restore the master switch first, before restoring individual effects.
    Setting::UiEffects,
];

fn validate(journal: &Journal) -> Result<(), String> {
    transaction::validate(journal)?;
    if journal
        .entries
        .iter()
        .any(|entry| !SETTINGS.contains(&entry.setting) || entry.applied != Value::dword(0))
    {
        return Err("Registro visual da sessão inválido.".into());
    }
    Ok(())
}

pub fn begin<B: Backend, S: Store>(backend: &mut B, store: &mut S) -> Result<Vec<String>, String> {
    if store.load()?.is_some() {
        return Err("Há um registro visual anterior para restaurar.".into());
    }
    let mut notes = Vec::new();
    let mut journal = Journal {
        schema: 1,
        entries: Vec::new(),
    };
    for setting in SETTINGS {
        match transaction::prepare(backend, &[(*setting, Value::dword(0))]).and_then(|candidate| {
            validate(&candidate)?;
            Ok(candidate)
        }) {
            Ok(mut candidate) => journal.entries.append(&mut candidate.entries),
            Err(error) => notes.push(format!("{}: {error}", setting.description())),
        }
    }
    validate(&journal)?;
    transaction::apply(backend, store, &journal)?;
    Ok(notes)
}

pub fn end<B: Backend, S: Store>(backend: &mut B, store: &mut S) -> Result<RestoreReport, String> {
    let journal = store.load()?.ok_or("Não há registro visual da sessão.")?;
    validate(&journal)?;
    transaction::restore(backend, store, &journal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    #[derive(Default)]
    struct Fake(HashMap<Setting, Value>);
    impl Backend for Fake {
        fn read(&mut self, setting: Setting) -> Result<Option<Value>, String> {
            Ok(self.0.get(&setting).cloned())
        }
        fn write(&mut self, setting: Setting, value: &Value) -> Result<(), String> {
            self.0.insert(setting, value.clone());
            Ok(())
        }
        fn delete(&mut self, setting: Setting) -> Result<(), String> {
            self.0.remove(&setting);
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save(&mut self, value: &Journal) -> Result<(), String> {
            if self.0.is_some() {
                return Err("exists".into());
            }
            self.0 = Some(value.clone());
            Ok(())
        }
        fn update(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("changed".into());
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
    fn restores_visual_changes_and_preserves_external_conflicts() {
        let mut backend = Fake::default();
        for setting in SETTINGS {
            backend.0.insert(*setting, Value::dword(1));
        }
        let mut store = Memory::default();
        begin(&mut backend, &mut store).unwrap();
        backend.0.insert(Setting::MenuFade, Value::dword(2));
        let report = end(&mut backend, &mut store).unwrap();
        assert_eq!(report.conflicts, vec![Setting::MenuFade]);
        assert_eq!(backend.0[&Setting::MenuFade], Value::dword(2));
        assert_eq!(backend.0[&Setting::DropShadows], Value::dword(1));
        assert!(store.0.is_some());
    }
    #[test]
    fn rejects_nonvisual_settings_in_a_session_journal() {
        let mut backend = Fake::default();
        let mut store = Memory(Some(
            transaction::prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap(),
        ));
        assert!(end(&mut backend, &mut store).is_err());
        assert!(store.0.is_some());
    }
    #[test]
    fn separate_session_journal_recovers_after_reopening() {
        use crate::storage::FileStore;
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("visual-journal-{unique}"));
        let mut backend = Fake::default();
        for setting in SETTINGS {
            backend.0.insert(*setting, Value::dword(1));
        }
        let original = backend.0.clone();
        let other =
            transaction::prepare(&mut backend, &[(Setting::GameMode, Value::dword(1))]).unwrap();
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            store.save(&other).unwrap();
            begin(&mut backend, &mut store.visual_session()).unwrap();
            assert_eq!(store.load().unwrap(), Some(other.clone()));
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            let report = end(&mut backend, &mut store.visual_session()).unwrap();
            assert!(report.conflicts.is_empty() && report.errors.is_empty());
            assert_eq!(store.load().unwrap(), Some(other));
            assert!(store.visual_session().load().unwrap().is_none());
        }
        assert_eq!(backend.0, original);
        let target = std::fs::canonicalize(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target"),
        )
        .unwrap();
        let resolved = std::fs::canonicalize(directory).unwrap();
        assert_eq!(resolved.parent(), Some(target.as_path()));
        std::fs::remove_dir_all(resolved).unwrap();
    }
    #[cfg(windows)]
    #[test]
    #[ignore = "Changes visual settings; run only on a disposable Windows runner"]
    fn disposable_session_visual_round_trip() {
        use crate::{storage::FileStore, windows_registry::WindowsRegistry};
        let mut backend = WindowsRegistry::default();
        let originals: Vec<_> = SETTINGS
            .iter()
            .filter_map(|setting| backend.read(*setting).ok().map(|value| (*setting, value)))
            .collect();
        struct Restore(Vec<(Setting, Option<Value>)>);
        impl Drop for Restore {
            fn drop(&mut self) {
                let mut backend = WindowsRegistry::default();
                for (setting, value) in &self.0 {
                    match value {
                        Some(value) => {
                            let _ = backend.write(*setting, value);
                        }
                        None => {
                            let _ = backend.delete(*setting);
                        }
                    }
                }
            }
        }
        let _restore = Restore(originals.clone());
        let forced = originals
            .iter()
            .find_map(|(setting, original)| {
                if setting.is_system_parameter()
                    && original.is_some()
                    && backend.write(*setting, &Value::dword(1)).is_ok()
                {
                    Some(*setting)
                } else {
                    None
                }
            })
            .expect("No writable visual effect is available on this runner");
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("visual-session-{unique}"));
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            begin(&mut backend, &mut store.visual_session()).unwrap();
            assert!(store.visual_session().load().unwrap().is_some());
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            let report = end(&mut backend, &mut store.visual_session()).unwrap();
            assert!(
                report.conflicts.is_empty() && report.errors.is_empty(),
                "{report:?}"
            );
        }
        assert_eq!(backend.read(forced).unwrap(), Some(Value::dword(1)));
        let target = std::fs::canonicalize(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target"),
        )
        .unwrap();
        let resolved = std::fs::canonicalize(directory).unwrap();
        assert_eq!(resolved.parent(), Some(target.as_path()));
        std::fs::remove_dir_all(resolved).unwrap();
    }
}
