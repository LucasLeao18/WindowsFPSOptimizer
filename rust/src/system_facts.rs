//! Read-only gathering of everything a profile plan depends on.
use crate::{
    Preset, background_apps,
    engine::Facts,
    power_profile::{self, Kind, Plan},
    power_settings, service_config,
    windows_power::{WindowsPower, WindowsPowerProfile, WindowsPowerSettings},
    windows_registry,
};

/// May take a few seconds (WMI and service queries). Call from a worker thread.
pub fn gather(preset: Preset) -> Facts {
    gather_using(preset, || {
        crate::pagefile::detect_with_timeout(std::time::Duration::from_secs(8))
    })
}

pub fn gather_using(
    preset: Preset,
    pagefile: impl FnOnce() -> Result<crate::pagefile::Management, String>,
) -> Facts {
    let mut facts = Facts {
        elevated: crate::process_control::current_process_elevated(),
        ..Facts::default()
    };
    if preset == Preset::Safe {
        return facts;
    }
    facts.pagefile = pagefile().ok();
    if preset != Preset::MaximumFps {
        return facts;
    }
    facts.power = power_profile::plan(&mut WindowsPowerProfile).ok();
    facts.memory_integrity = windows_registry::memory_integrity_enabled();
    facts.adapters = windows_registry::ethernet_adapters();
    facts.x3d = windows_registry::processor_name()
        .is_some_and(|name| name.to_ascii_uppercase().contains("X3D"));
    // Overrides go to the plan that will be active after the power change.
    let plan = match facts.power {
        Some(Plan::Change {
            kind: Kind::Plan,
            to,
            ..
        }) => Some(to),
        _ => {
            use crate::power_session::Backend;
            WindowsPower.active().ok()
        }
    };
    let allowed: Vec<_> = power_settings::Setting::ALL
        .into_iter()
        .filter(|s| !(facts.x3d && *s == power_settings::Setting::CoreParkingMinimum))
        .collect();
    if let Some(plan) = plan {
        facts.power_settings =
            power_settings::pending(&mut WindowsPowerSettings, plan, &allowed).unwrap_or_default();
    }
    facts.services = service_config::pending(
        &mut crate::windows_services::WindowsServiceConfig,
        &service_config::Service::ALL,
    )
    .unwrap_or_default();
    let mut titles: Vec<&'static str> = background_apps::running()
        .into_iter()
        .map(|f| f.title)
        .collect();
    titles.dedup();
    titles.sort_unstable();
    titles.dedup();
    facts.background = titles;
    facts
}
