//! Compatibility-aware orchestration. No Windows changes happen in preview.
use crate::{
    Preset,
    compatibility::{WindowsVersion, classify, conservative_changes},
    pagefile::Management,
    transaction::{self, Backend, Journal, RestoreReport, Store},
};

#[derive(Debug, Clone)]
pub struct Preview {
    pub preset: Preset,
    pub platform: WindowsVersion,
    pub journal: Journal,
    pub notes: Vec<String>,
}

pub fn preview<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    version: WindowsVersion,
    preset: Preset,
    pagefile: Option<Management>,
) -> Result<Preview, String> {
    if store.load()?.is_some() {
        return Err(
            "Existe um backup anterior. Revise ou restaure antes de aplicar outro perfil.".into(),
        );
    }
    let capabilities = classify(Some(version));
    if !capabilities.supported {
        return Err(capabilities.reason.into());
    }
    match preset {
        Preset::Safe => {}
        Preset::Balanced => {}
        Preset::MaximumFps => {
            return Err(
                "A sessão de jogo ainda não está disponível na versão Rust em desenvolvimento."
                    .into(),
            );
        }
    }
    let mut notes = vec![capabilities.reason.to_string()];
    let mut journal = Journal {
        schema: 1,
        entries: Vec::new(),
    };
    for (setting, value) in conservative_changes(&capabilities) {
        match transaction::prepare(backend, &[(setting, value)]).and_then(|candidate| {
            transaction::validate(&candidate)?;
            Ok(candidate)
        }) {
            Ok(mut candidate) => journal.entries.append(&mut candidate.entries),
            Err(error) => notes.push(format!(
                "{} não será alterada: {error}",
                setting.description()
            )),
        }
    }
    if preset == Preset::Balanced {
        notes.push(match pagefile {
            Some(Management::Automatic) => "Memória virtual: gerenciada pelo Windows; nenhuma alteração de paginação será feita.",
            Some(Management::Manual) => "Memória virtual: configuração manual detectada. Ela não será alterada; revise-a nas opções avançadas do Windows se desejar.",
            None => "Memória virtual: não foi possível consultar a configuração. Ela não será alterada; os demais ajustes disponíveis podem ser aplicados.",
        }.into());
    }
    if !capabilities.game_mode_automatic {
        notes.push("Modo de Jogo: configure manualmente no Windows.".into());
    } else {
        notes.push("O Windows pode aplicar políticas próprias ou exigir nova sessão para refletir uma alteração.".into());
    }
    notes.push("Capturas: revise nas Configurações do Windows; o aplicativo não muda políticas sem verificar edição e gerenciamento.".into());
    notes.push("O efeito dos ajustes sobre FPS varia por computador e jogo.".into());
    Ok(Preview {
        preset,
        platform: version,
        journal,
        notes,
    })
}

pub fn apply<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    current: WindowsVersion,
    preview: &Preview,
    _pagefile: Option<Management>,
) -> Result<(), String> {
    if preview.platform != current {
        return Err("A versão do Windows mudou desde a análise. Faça uma nova análise.".into());
    }
    let capabilities = classify(Some(current));
    if !capabilities.supported || preview.preset == Preset::MaximumFps {
        return Err("Este perfil não é compatível.".into());
    }
    let allowed = conservative_changes(&capabilities);
    for entry in &preview.journal.entries {
        if !allowed.contains(&(entry.setting, entry.applied.clone())) {
            return Err("O plano contém uma alteração incompatível.".into());
        }
    }
    transaction::apply(backend, store, &preview.journal)
}

pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
) -> Result<RestoreReport, String> {
    let journal = store.load()?.ok_or("Não existe backup para restaurar.")?;
    transaction::restore(backend, store, &journal)
}

#[cfg(windows)]
pub fn state_directory() -> Result<std::path::PathBuf, String> {
    let root = std::env::var_os("LOCALAPPDATA")
        .filter(|v| !v.is_empty())
        .ok_or("A pasta local do usuário está indisponível.")?;
    let path = std::path::PathBuf::from(root);
    if !path.is_absolute() || path.to_string_lossy().starts_with(r"\\") {
        return Err("A pasta de backup precisa estar em uma unidade local.".into());
    }
    Ok(path.join("WindowsFPSOptimizerRust").join("State"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transaction::{Setting, Value};
    use std::collections::HashMap;
    #[derive(Default)]
    struct Fake(HashMap<Setting, Value>);
    impl Backend for Fake {
        fn read(&mut self, key: Setting) -> Result<Option<Value>, String> {
            Ok(self.0.get(&key).cloned())
        }
        fn write(&mut self, key: Setting, value: &Value) -> Result<(), String> {
            self.0.insert(key, value.clone());
            Ok(())
        }
        fn delete(&mut self, key: Setting) -> Result<(), String> {
            self.0.remove(&key);
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
            self.0 = Some(value.clone());
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
    fn preview_does_not_write_and_unknown_os_is_rejected() {
        let mut backend = Fake::default();
        let mut store = Memory::default();
        let server = WindowsVersion {
            major: 10,
            build: 20348,
            workstation: false,
        };
        assert!(preview(&mut backend, &mut store, server, Preset::Safe, None).is_err());
        let client = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let view = preview(&mut backend, &mut store, client, Preset::Safe, None).unwrap();
        assert_eq!(view.journal.entries.len(), 2);
        assert!(backend.0.is_empty() && store.0.is_none());
    }
    #[test]
    fn apply_then_restore_preserves_absent_values() {
        let mut backend = Fake::default();
        let mut store = Memory::default();
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let view = preview(&mut backend, &mut store, version, Preset::Safe, None).unwrap();
        apply(&mut backend, &mut store, version, &view, None).unwrap();
        assert_eq!(backend.0.len(), 2);
        assert_eq!(restore(&mut backend, &mut store).unwrap().restored.len(), 2);
        assert!(backend.0.is_empty());
    }
    #[test]
    fn balanced_remains_available_without_changing_pagefile() {
        let mut backend = Fake::default();
        let mut store = Memory::default();
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let view = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Balanced,
            Some(Management::Manual),
        )
        .unwrap();
        assert!(
            view.notes
                .iter()
                .any(|note| note.contains("manual") && note.contains("não será alterada"))
        );
        assert!(backend.0.is_empty() && store.0.is_none());
        apply(&mut backend, &mut store, version, &view, None).unwrap();
        restore(&mut backend, &mut store).unwrap();
        let unknown = preview(&mut backend, &mut store, version, Preset::Balanced, None).unwrap();
        assert!(
            unknown
                .notes
                .iter()
                .any(|note| note.contains("não foi possível consultar"))
        );
    }
    #[test]
    fn visual_settings_are_backed_up_and_restored() {
        let mut backend = Fake::default();
        for setting in [
            Setting::WindowAnimations,
            Setting::ClientAreaAnimations,
            Setting::MenuAnimations,
            Setting::MenuFade,
            Setting::SelectionFade,
            Setting::TooltipAnimations,
            Setting::TooltipFade,
            Setting::ComboBoxAnimations,
            Setting::SmoothListScrolling,
        ] {
            backend.0.insert(setting, Value::dword(1));
        }
        let before = backend.0.clone();
        let mut store = Memory::default();
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let view = preview(&mut backend, &mut store, version, Preset::Safe, None).unwrap();
        assert_eq!(view.journal.entries.len(), 11);
        apply(&mut backend, &mut store, version, &view, None).unwrap();
        restore(&mut backend, &mut store).unwrap();
        assert_eq!(backend.0, before);
    }
    #[test]
    fn unavailable_visual_parameter_is_reported_and_other_changes_remain_available() {
        struct Limited(Fake);
        impl Backend for Limited {
            fn read(&mut self, setting: Setting) -> Result<Option<Value>, String> {
                if setting == Setting::MenuFade {
                    return Err("não suportado".into());
                }
                self.0.read(setting)
            }
            fn write(&mut self, setting: Setting, value: &Value) -> Result<(), String> {
                self.0.write(setting, value)
            }
            fn delete(&mut self, setting: Setting) -> Result<(), String> {
                self.0.delete(setting)
            }
        }
        let mut backend = Limited(Fake::default());
        let mut store = Memory::default();
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let view = preview(&mut backend, &mut store, version, Preset::Safe, None).unwrap();
        assert!(
            view.journal
                .entries
                .iter()
                .any(|entry| entry.setting == Setting::GameMode)
        );
        assert!(
            !view
                .journal
                .entries
                .iter()
                .any(|entry| entry.setting == Setting::MenuFade)
        );
        assert!(
            view.notes
                .iter()
                .any(|note| note.contains("Transição de menus") && note.contains("não suportado"))
        );
    }
}
