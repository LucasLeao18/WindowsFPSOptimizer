//! Compatibility-aware orchestration. No Windows changes happen in preview.
use crate::{
    Preset,
    compatibility::{Capabilities, WindowsVersion, classify, conservative_changes},
    pagefile::Management,
    power_profile::{self, Kind},
    power_settings, service_config,
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
    /// Maximum only: power-saving overrides on the plan active after `power`.
    pub power_settings: Vec<power_settings::Setting>,
    /// Maximum only: services whose start type becomes Disabled.
    pub services: Vec<service_config::Service>,
    /// Maximum only: background helpers to close (not restorable).
    pub close_apps: Vec<&'static str>,
    /// Balanced and Maximum: trim working sets once (not restorable).
    pub trim_memory: bool,
    /// The facts the plan was built from, used to validate it again on apply.
    pub facts: Facts,
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
        !self.journal.entries.is_empty()
            || self.pagefile_to_automatic
            || self.power.is_some()
            || !self.power_settings.is_empty()
            || !self.services.is_empty()
            || !self.close_apps.is_empty()
            || self.trim_memory
    }
}

/// System facts gathered by the caller (read-only queries that may be slow).
#[derive(Debug, Clone, Default)]
pub struct Facts {
    pub pagefile: Option<Management>,
    pub power: Option<power_profile::Plan>,
    pub memory_integrity: Option<bool>,
    /// The application runs as administrator.
    pub elevated: bool,
    /// Physical Ethernet adapters and whether each exposes Energy-Efficient Ethernet.
    pub adapters: Vec<(u16, bool)>,
    /// AMD X3D processors rely on core parking to pick the V-Cache CCD.
    pub x3d: bool,
    /// Power-saving overrides still pending on the plan that will be active.
    pub power_settings: Vec<power_settings::Setting>,
    /// Profile services installed and not yet disabled.
    pub services: Vec<service_config::Service>,
    /// Closable background helpers currently running.
    pub background: Vec<&'static str>,
}

/// At most this many Ethernet adapters are adjusted.
const MAX_ADAPTERS: usize = 8;

fn profile_changes(
    capabilities: &Capabilities,
    preset: Preset,
    facts: &Facts,
) -> Vec<(Setting, Value)> {
    let mut changes = conservative_changes(capabilities);
    if !capabilities.supported || preset == Preset::Safe {
        return changes;
    }
    let mut settings = vec![
        Setting::CursorShadow,
        Setting::DropShadows,
        Setting::BackgroundRecording,
    ];
    if facts.elevated {
        settings.push(Setting::NtfsLastAccess);
    }
    if preset == Preset::MaximumFps {
        settings.extend([Setting::GameDvr, Setting::AppCapture]);
        if facts.elevated {
            settings.push(Setting::PerformanceCounters);
            for (index, has_eee) in facts.adapters.iter().take(MAX_ADAPTERS) {
                if *has_eee {
                    settings.push(Setting::AdapterEnergyEfficient(*index));
                }
                settings.push(Setting::AdapterPowerManagement(*index));
            }
        }
    }
    changes.extend(settings.into_iter().map(|s| (s, s.target())));
    changes
}

/// Changes the profile would make that need administrator rights.
fn administrator_items(preset: Preset, facts: &Facts) -> Vec<&'static str> {
    let mut items = Vec::new();
    if preset == Preset::Safe {
        return items;
    }
    items.push("último acesso do NTFS");
    if preset == Preset::MaximumFps {
        items.push("contadores de desempenho");
        if !facts.adapters.is_empty() {
            items.push("economia de energia do Ethernet");
        }
        if !facts.services.is_empty() {
            items.push("SysMain e Windows Search");
        }
    }
    items
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
    for (setting, value) in profile_changes(&capabilities, preset, &facts) {
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
    if preset != Preset::Safe {
        if facts.elevated {
            notes.push("Último acesso do NTFS desligado após reiniciar: backups e o Sensor de Armazenamento deixam de saber quando um arquivo foi aberto.".into());
        } else {
            notes.push(format!(
                "Exigem administrador e ficam de fora agora: {}. Use Reabrir como administrador para incluí-los.",
                administrator_items(preset, &facts).join(", ")
            ));
        }
        notes.push("A memória dos programas abertos será liberada uma vez; o Windows recarrega o que for usado.".into());
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
        if !facts.power_settings.is_empty() {
            notes.push(format!(
                "Economia de energia desligada no plano ativo (na tomada): {}. Aumenta consumo e temperatura.",
                facts
                    .power_settings
                    .iter()
                    .map(|setting| setting.description())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        if facts.x3d {
            notes.push("Estacionamento de núcleos mantido: processadores Ryzen X3D dependem dele para usar o cache 3D nos jogos.".into());
        }
        if facts.elevated {
            for service in &facts.services {
                notes.push(format!(
                    "{} será desativado: {}.",
                    service.title(),
                    service.impact()
                ));
            }
            if !facts.adapters.is_empty() {
                notes.push("Ethernet: economia de energia desligada no adaptador; vale depois de reiniciar o adaptador ou o computador.".into());
            }
            notes.push("Contadores de desempenho desligados após reiniciar: o Monitor de Desempenho, gráficos do Gerenciador de Tarefas e sobreposições como o MSI Afterburner podem ficar sem dados.".into());
        }
        if !facts.background.is_empty() {
            notes.push(format!(
                "Serão fechados: {}. Isso não é desfeito pela restauração; eles voltam ao abrir ou no próximo login.",
                facts.background.join(", ")
            ));
        }
        notes.push("Game Bar desligado: Win+G e as gravações do Game Bar deixam de funcionar até restaurar.".into());
        notes.push("O desligamento do Windows Defender, oferecido por alguns otimizadores, não é feito: ele deixaria o computador sem proteção.".into());
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
        power_settings: if preset == Preset::MaximumFps {
            facts.power_settings.clone()
        } else {
            Vec::new()
        },
        services: if preset == Preset::MaximumFps && facts.elevated {
            facts.services.clone()
        } else {
            Vec::new()
        },
        close_apps: if preset == Preset::MaximumFps {
            facts.background.clone()
        } else {
            Vec::new()
        },
        trim_memory: preset != Preset::Safe,
        facts,
        notes,
    })
}

pub fn apply<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    current: WindowsVersion,
    preview: &Preview,
    elevated_now: bool,
) -> Result<(), String> {
    if preview.platform != current {
        return Err("A versão do Windows mudou desde a análise. Faça uma nova análise.".into());
    }
    let capabilities = classify(Some(current));
    if !capabilities.supported {
        return Err("Este perfil não é compatível.".into());
    }
    let maximum_only = preview.power.is_some()
        || !preview.power_settings.is_empty()
        || !preview.services.is_empty()
        || !preview.close_apps.is_empty();
    if (preview.pagefile_to_automatic && preview.preset == Preset::Safe)
        || (preview.trim_memory && preview.preset == Preset::Safe)
        || (maximum_only && preview.preset != Preset::MaximumFps)
        || (!preview.services.is_empty() && !elevated_now)
    {
        return Err("O plano contém uma alteração incompatível.".into());
    }
    if preview.facts.elevated && !elevated_now {
        return Err("O aplicativo não está mais como administrador. Faça uma nova análise.".into());
    }
    let allowed = profile_changes(&capabilities, preview.preset, &preview.facts);
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
        apply(&mut backend, &mut store, version, &view, false).unwrap();
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
        apply(&mut backend, &mut store, version, &view, false).unwrap();
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
        assert!(apply(&mut backend, &mut store, version, &tampered, false).is_err());
        apply(&mut backend, &mut store, version, &balanced, false).unwrap();
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
        apply(&mut backend, &mut store, version, &view, false).unwrap();
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
            ..Facts::default()
        };
        let maximum = preview(
            &mut backend,
            &mut store,
            version,
            Preset::MaximumFps,
            facts.clone(),
        )
        .unwrap();
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
        let balanced = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Balanced,
            facts.clone(),
        )
        .unwrap();
        assert!(balanced.power.is_none());
        let mut tampered = balanced.clone();
        tampered.power = maximum.power;
        assert!(apply(&mut backend, &mut store, version, &tampered, false).is_err());
        apply(&mut backend, &mut store, version, &maximum, false).unwrap();
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
        use crate::{storage::FileStore, windows_registry::WindowsRegistry};
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("real-preview-{unique}"));
        let version = crate::compatibility::detect().unwrap();
        // Direct pagefile query: the guarded variant refuses concurrent callers.
        let facts = crate::system_facts::gather_using(Preset::MaximumFps, crate::pagefile::detect);
        println!("{version:?} {facts:?}");
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            for preset in [Preset::Safe, Preset::Balanced, Preset::MaximumFps] {
                let view = preview(
                    &mut WindowsRegistry::default(),
                    &mut store,
                    version,
                    preset,
                    facts.clone(),
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
    #[test]
    fn maximum_includes_booster_features_only_with_administrator() {
        let version = WindowsVersion {
            major: 10,
            build: 22621,
            workstation: true,
        };
        let elevated = Facts {
            elevated: true,
            adapters: vec![(7, true), (9, false)],
            services: vec![service_config::Service::SysMain],
            background: vec!["OneDrive"],
            power_settings: vec![power_settings::Setting::PcieLinkPower],
            ..Facts::default()
        };
        let mut backend = Fake::default();
        let mut store = Memory::default();
        let view = preview(
            &mut backend,
            &mut store,
            version,
            Preset::MaximumFps,
            elevated.clone(),
        )
        .unwrap();
        let has = |setting| view.journal.entries.iter().any(|e| e.setting == setting);
        for setting in [
            Setting::NtfsLastAccess,
            Setting::PerformanceCounters,
            Setting::GameDvr,
            Setting::AppCapture,
            Setting::AdapterEnergyEfficient(7),
            Setting::AdapterPowerManagement(7),
            Setting::AdapterPowerManagement(9),
        ] {
            assert!(has(setting), "{setting:?}");
        }
        assert!(!has(Setting::AdapterEnergyEfficient(9)));
        assert_eq!(view.services, vec![service_config::Service::SysMain]);
        assert_eq!(view.close_apps, vec!["OneDrive"]);
        assert!(view.trim_memory && !view.power_settings.is_empty());
        assert!(view.notes.iter().any(|n| n.contains("Windows Defender")));
        // Losing administrator rights invalidates the plan.
        assert!(apply(&mut backend, &mut store, version, &view, false).is_err());
        apply(&mut backend, &mut store, version, &view, true).unwrap();
        assert_eq!(
            backend.0[&Setting::AdapterEnergyEfficient(7)],
            Value::string("0")
        );
        restore(&mut backend, &mut store).unwrap();
        assert!(!backend.0.contains_key(&Setting::AdapterPowerManagement(9)));
        // Without administrator rights the machine-wide items are left out.
        let user = Facts {
            elevated: false,
            ..elevated.clone()
        };
        let view = preview(&mut backend, &mut store, version, Preset::MaximumFps, user).unwrap();
        assert!(
            view.journal
                .entries
                .iter()
                .all(|e| !e.setting.requires_administrator())
        );
        assert!(view.services.is_empty());
        assert!(
            view.notes
                .iter()
                .any(|n| n.contains("Exigem administrador"))
        );
        // Balanced never closes programs nor changes services or adapters.
        let balanced = preview(
            &mut backend,
            &mut store,
            version,
            Preset::Balanced,
            elevated,
        )
        .unwrap();
        assert!(balanced.close_apps.is_empty() && balanced.services.is_empty());
        assert!(
            balanced
                .journal
                .entries
                .iter()
                .any(|e| e.setting == Setting::NtfsLastAccess)
        );
        assert!(
            !balanced
                .journal
                .entries
                .iter()
                .any(|e| e.setting == Setting::PerformanceCounters)
        );
        assert!(balanced.power_settings.is_empty());
    }
}
