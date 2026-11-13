//! Compatibility-aware orchestration. No Windows changes happen in preview.
use crate::{
    Preset,
    compatibility::{Capabilities, WindowsVersion, classify, conservative_changes},
    pagefile::Management,
    power_profile::{self, Kind},
    transaction::{self, Backend, Journal, RestoreReport, Setting, Store, Value},
};

#[derive(Debug, Clone)]
pub struct Preview {
    pub preset: Preset,
    pub platform: WindowsVersion,
    pub journal: Journal,
    /// Balanced and Maximum: return a manual pagefile layout to Windows management.
    pub pagefile_to_automatic: bool,
    /// Maximum only: the power plan or power mode to switch.
    pub power: Option<PowerChange>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PowerChange {
    pub kind: Kind,
    pub from: crate::power_session::Scheme,
    pub to: crate::power_session::Scheme,
}

impl Preview {
    pub fn has_changes(&self) -> bool {
        !self.journal.entries.is_empty() || self.pagefile_to_automatic || self.power.is_some()
    }
}

/// System facts gathered by the caller (read-only queries that may be slow).
#[derive(Debug, Clone, Copy, Default)]
pub struct Facts {
    pub pagefile: Option<Management>,
    pub power: Option<power_profile::Plan>,
    pub memory_integrity: Option<bool>,
}

fn profile_changes(capabilities: &Capabilities, preset: Preset) -> Vec<(Setting, Value)> {
    let mut changes = conservative_changes(capabilities);
    if capabilities.supported && preset != Preset::Safe {
        changes.extend([
            (Setting::CursorShadow, Value::dword(0)),
            (Setting::DropShadows, Value::dword(0)),
            (Setting::BackgroundRecording, Value::dword(0)),
        ]);
    }
    changes
}

pub fn preview<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    version: WindowsVersion,
    preset: Preset,
    facts: Facts,
) -> Result<Preview, String> {
    let pagefile = facts.pagefile;
    if store.load()?.is_some() {
        return Err(
            "Existe um backup anterior. Revise ou restaure antes de aplicar outro perfil.".into(),
        );
    }
    let capabilities = classify(Some(version));
    if !capabilities.supported {
        return Err(capabilities.reason.into());
    }
    let mut notes = vec![capabilities.reason.to_string()];
    let mut journal = Journal {
        schema: 1,
        entries: Vec::new(),
    };
    for (setting, value) in profile_changes(&capabilities, preset) {
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
    if preset != Preset::Safe {
        notes.push(match pagefile {
            Some(Management::Automatic) => "Memória virtual: gerenciada pelo Windows; nenhuma alteração de paginação será feita.",
            Some(Management::Manual) => "Memória virtual: configuração manual detectada. Ela será devolvida ao gerenciamento automático do Windows; a configuração atual é salva para restauração. Requer executar como administrador e vale após reiniciar.",
            None => "Memória virtual: não foi possível consultar a configuração. Ela não será alterada; os demais ajustes disponíveis podem ser aplicados.",
        }.into());
    }
    let mut power = None;
    if preset == Preset::MaximumFps {
        notes.push(match facts.power {
            Some(power_profile::Plan::Change { kind, from, to }) => {
                power = Some(PowerChange { kind, from, to });
                match kind {
                    Kind::Plan => "Energia: o plano Alto Desempenho será ativado. Ele aumenta consumo e temperatura; em notebooks, prefira usar na tomada.",
                    Kind::Mode => "Energia: o modo de energia do Windows passará para Melhor desempenho. Ele aumenta consumo e temperatura; em notebooks, prefira usar na tomada.",
                }
            }
            Some(power_profile::Plan::AlreadyMaximum) => "Energia: já está na configuração de maior desempenho disponível.",
            Some(power_profile::Plan::Unavailable) => "Energia: um plano personalizado ou do fabricante está ativo, ou o Windows não oferece o modo de energia. Ele não será substituído.",
            None => "Energia: não foi possível consultar o plano; ele não será alterado.",
        }.into());
        if facts.memory_integrity == Some(true) {
            notes.push("Integridade de memória está ativada. Testes publicados mostram perdas de cerca de 3% a 8% em alguns jogos, mas ela protege contra drivers maliciosos. O aplicativo não a desativa; a decisão fica em Segurança do Windows > Segurança do dispositivo > Isolamento de núcleo.".into());
        }
    }
    if !capabilities.game_mode_automatic {
        notes.push("Modo de Jogo: configure manualmente no Windows.".into());
    } else {
        notes.push("O Windows pode aplicar políticas próprias ou exigir nova sessão para refletir uma alteração.".into());
    }
    notes.push(if preset == Preset::Safe {
        "Capturas: revise nas Configurações do Windows; o aplicativo não muda políticas sem verificar edição e gerenciamento."
    } else {
        "Capturas: a gravação em segundo plano do Game Bar será desligada; a gravação manual (Win+Alt+R) continua disponível."
    }.into());
    notes.push("O efeito dos ajustes sobre FPS varia por computador e jogo.".into());
    Ok(Preview {
        preset,
        platform: version,
        journal,
        pagefile_to_automatic: preset != Preset::Safe && pagefile == Some(Management::Manual),
        power,
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
    if !capabilities.supported {
        return Err("Este perfil não é compatível.".into());
    }
    if (preview.pagefile_to_automatic && preview.preset == Preset::Safe)
        || (preview.power.is_some() && preview.preset != Preset::MaximumFps)
    {
        return Err("O plano contém uma alteração incompatível.".into());
    }
    let allowed = profile_changes(&capabilities, preview.preset);
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
        assert!(
            preview(
                &mut backend,
                &mut store,
                server,
                Preset::Safe,
                Facts::default()
            )
            .is_err()
        );
        let client = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let view = preview(
            &mut backend,
            &mut store,
            client,
            Preset::Safe,
            Facts::default(),
        )
        .unwrap();
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
        let view = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Safe,
            Facts::default(),
        )
        .unwrap();
        apply(&mut backend, &mut store, version, &view, None).unwrap();
        assert_eq!(backend.0.len(), 2);
        assert_eq!(restore(&mut backend, &mut store).unwrap().restored.len(), 2);
        assert!(backend.0.is_empty());
    }
    #[test]
    fn balanced_plans_automatic_pagefile_only_when_manual() {
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
            Facts {
                pagefile: Some(Management::Manual),
                ..Facts::default()
            },
        )
        .unwrap();
        assert!(view.pagefile_to_automatic && view.has_changes());
        assert!(
            view.notes
                .iter()
                .any(|note| note.contains("manual") && note.contains("gerenciamento automático"))
        );
        assert!(backend.0.is_empty() && store.0.is_none());
        apply(&mut backend, &mut store, version, &view, None).unwrap();
        restore(&mut backend, &mut store).unwrap();
        let automatic = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Balanced,
            Facts {
                pagefile: Some(Management::Automatic),
                ..Facts::default()
            },
        )
        .unwrap();
        assert!(!automatic.pagefile_to_automatic);
        let safe = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Safe,
            Facts {
                pagefile: Some(Management::Manual),
                ..Facts::default()
            },
        )
        .unwrap();
        assert!(!safe.pagefile_to_automatic);
        let unknown = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Balanced,
            Facts::default(),
        )
        .unwrap();
        assert!(!unknown.pagefile_to_automatic);
        assert!(
            unknown
                .notes
                .iter()
                .any(|note| note.contains("não foi possível consultar"))
        );
    }
    #[test]
    fn balanced_adds_reversible_shadows_and_safe_rejects_them() {
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let mut backend = Fake::default();
        for setting in [Setting::CursorShadow, Setting::DropShadows] {
            backend.0.insert(setting, Value::dword(1));
        }
        let mut store = Memory::default();
        let safe = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Safe,
            Facts::default(),
        )
        .unwrap();
        assert!(
            !safe
                .journal
                .entries
                .iter()
                .any(|entry| entry.setting == Setting::CursorShadow
                    || entry.setting == Setting::DropShadows)
        );
        let balanced = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Balanced,
            Facts::default(),
        )
        .unwrap();
        for setting in [Setting::CursorShadow, Setting::DropShadows] {
            assert!(
                balanced
                    .journal
                    .entries
                    .iter()
                    .any(|entry| entry.setting == setting)
            );
        }
        let mut tampered = safe;
        tampered.journal.entries.push(
            balanced
                .journal
                .entries
                .iter()
                .find(|entry| entry.setting == Setting::CursorShadow)
                .unwrap()
                .clone(),
        );
        assert!(apply(&mut backend, &mut store, version, &tampered, None).is_err());
        apply(&mut backend, &mut store, version, &balanced, None).unwrap();
        assert_eq!(backend.0[&Setting::DropShadows], Value::dword(0));
        restore(&mut backend, &mut store).unwrap();
        assert_eq!(backend.0[&Setting::DropShadows], Value::dword(1));
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
        let view = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Safe,
            Facts::default(),
        )
        .unwrap();
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
        let view = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Safe,
            Facts::default(),
        )
        .unwrap();
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
    #[test]
    fn maximum_is_a_windows_profile_with_power_and_recording() {
        use crate::power_session::HIGH_PERFORMANCE;
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let mut backend = Fake::default();
        let mut store = Memory::default();
        let change = power_profile::Plan::Change {
            kind: Kind::Plan,
            from: power_profile::BALANCED,
            to: HIGH_PERFORMANCE,
        };
        let facts = Facts {
            pagefile: Some(Management::Manual),
            power: Some(change),
            memory_integrity: Some(true),
        };
        let maximum =
            preview(&mut backend, &mut store, version, Preset::MaximumFps, facts).unwrap();
        assert!(maximum.pagefile_to_automatic);
        assert_eq!(maximum.power.unwrap().to, HIGH_PERFORMANCE);
        assert!(
            maximum
                .journal
                .entries
                .iter()
                .any(|e| e.setting == Setting::BackgroundRecording)
        );
        assert!(
            maximum
                .notes
                .iter()
                .any(|n| n.contains("Integridade de memória"))
        );
        // Balanced never carries a power change, even with the same facts.
        let balanced = preview(&mut backend, &mut store, version, Preset::Balanced, facts).unwrap();
        assert!(balanced.power.is_none());
        let mut tampered = balanced.clone();
        tampered.power = maximum.power;
        assert!(apply(&mut backend, &mut store, version, &tampered, None).is_err());
        apply(&mut backend, &mut store, version, &maximum, None).unwrap();
        assert_eq!(backend.0[&Setting::BackgroundRecording], Value::dword(0));
        restore(&mut backend, &mut store).unwrap();
        assert!(!backend.0.contains_key(&Setting::BackgroundRecording));
        // A custom plan is reported and left alone.
        let custom = Facts {
            power: Some(power_profile::Plan::Unavailable),
            ..Facts::default()
        };
        let view = preview(
            &mut backend,
            &mut store,
            version,
            Preset::MaximumFps,
            custom,
        )
        .unwrap();
        assert!(view.power.is_none());
        assert!(
            view.notes
                .iter()
                .any(|n| n.contains("não será substituído"))
        );
    }
    /// Prints the plan of every profile for this machine without writing.
    #[cfg(windows)]
    #[test]
    #[ignore = "Reads the local Windows configuration"]
    fn real_machine_preview_is_read_only() {
        use crate::{
            storage::FileStore, windows_power::WindowsPowerProfile,
            windows_registry::WindowsRegistry,
        };
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("real-preview-{unique}"));
        let version = crate::compatibility::detect().unwrap();
        let facts = Facts {
            pagefile: // Direct query: the guarded variant refuses concurrent callers.
            crate::pagefile::detect().ok(),
            power: power_profile::plan(&mut WindowsPowerProfile).ok(),
            memory_integrity: crate::windows_registry::memory_integrity_enabled(),
        };
        println!("{version:?} {facts:?}");
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            for preset in [Preset::Safe, Preset::Balanced, Preset::MaximumFps] {
                let view = preview(
                    &mut WindowsRegistry::default(),
                    &mut store,
                    version,
                    preset,
                    facts,
                )
                .unwrap();
                println!(
                    "== {} ({} alteração(ões), memória virtual: {}, energia: {:?})",
                    preset.name(),
                    view.journal.entries.len(),
                    view.pagefile_to_automatic,
                    view.power
                );
                for entry in &view.journal.entries {
                    println!(
                        "   {} -> {:?}",
                        entry.setting.description(),
                        entry.applied.bytes
                    );
                }
                for note in &view.notes {
                    println!("   * {note}");
                }
            }
            assert!(Store::load(&mut store).unwrap().is_none());
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
