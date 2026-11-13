//! Conservative capability checks: unknown platforms never opt in to writes.
use crate::transaction::{Setting, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowsVersion {
    pub major: u32,
    pub build: u32,
    pub workstation: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Capabilities {
    pub supported: bool,
    pub game_mode_automatic: bool,
    pub transparency_automatic: bool,
    pub reason: &'static str,
}

pub fn classify(version: Option<WindowsVersion>) -> Capabilities {
    match version {
        Some(WindowsVersion {
            major: 10,
            build,
            workstation: true,
        }) if build >= 22000 => Capabilities {
            supported: true,
            game_mode_automatic: true,
            transparency_automatic: true,
            reason: "Windows 11 detectado.",
        },
        Some(WindowsVersion {
            major: 10,
            build,
            workstation: true,
        }) if build >= 10240 => Capabilities {
            supported: true,
            game_mode_automatic: false,
            transparency_automatic: true,
            reason: "Windows 10 detectado; o Modo de Jogo deve ser revisado nas Configurações.",
        },
        Some(WindowsVersion {
            workstation: false, ..
        }) => Capabilities {
            supported: false,
            game_mode_automatic: false,
            transparency_automatic: false,
            reason: "Esta versão de servidor não está entre as plataformas testadas.",
        },
        _ => Capabilities {
            supported: false,
            game_mode_automatic: false,
            transparency_automatic: false,
            reason: "Não foi possível confirmar uma versão compatível do Windows.",
        },
    }
}

pub fn conservative_changes(capabilities: &Capabilities) -> Vec<(Setting, Value)> {
    let mut changes = Vec::new();
    if capabilities.game_mode_automatic {
        changes.push((Setting::GameMode, Value::dword(1)));
    }
    if capabilities.transparency_automatic {
        changes.push((Setting::Transparency, Value::dword(0)));
    }
    if capabilities.supported {
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
            changes.push((setting, Value::dword(0)));
        }
    }
    changes
}

#[cfg(windows)]
pub fn detect() -> Result<WindowsVersion, String> {
    // RtlGetVersion accepts the extended structure when its size is set.
    #[repr(C)]
    struct OsVersion {
        size: u32,
        major: u32,
        minor: u32,
        build: u32,
        platform: u32,
        csd: [u16; 128],
        service_major: u16,
        service_minor: u16,
        suite: u16,
        product_type: u8,
        reserved: u8,
    }
    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn RtlGetVersion(info: *mut OsVersion) -> i32;
    }
    let mut info: OsVersion = unsafe { std::mem::zeroed() };
    info.size = std::mem::size_of::<OsVersion>() as u32;
    let status = unsafe { RtlGetVersion(&mut info) };
    if status < 0 {
        return Err(format!(
            "Não foi possível detectar o Windows (0x{:08x}).",
            status as u32
        ));
    }
    Ok(WindowsVersion {
        major: info.major,
        build: info.build,
        workstation: info.product_type == 1,
    })
}

#[cfg(not(windows))]
pub fn detect() -> Result<WindowsVersion, String> {
    Err("Este aplicativo requer Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gates_by_build_and_client_type() {
        let win10 = classify(Some(WindowsVersion {
            major: 10,
            build: 19045,
            workstation: true,
        }));
        assert!(win10.supported && !win10.game_mode_automatic && win10.transparency_automatic);
        let win11 = classify(Some(WindowsVersion {
            major: 10,
            build: 22000,
            workstation: true,
        }));
        assert!(win11.supported && win11.game_mode_automatic);
        assert!(
            !classify(Some(WindowsVersion {
                major: 10,
                build: 20348,
                workstation: false
            }))
            .supported
        );
        assert!(
            !classify(Some(WindowsVersion {
                major: 10,
                build: 10239,
                workstation: true
            }))
            .supported
        );
        assert!(!classify(None).supported);
    }
    #[test]
    fn unsupported_platforms_never_get_automatic_changes() {
        assert!(conservative_changes(&classify(None)).is_empty());
        let changes = conservative_changes(&classify(Some(WindowsVersion {
            major: 10,
            build: 19045,
            workstation: true,
        })));
        assert!(changes.contains(&(Setting::Transparency, Value::dword(0))));
        assert!(
            !changes
                .iter()
                .any(|(setting, _)| *setting == Setting::GameMode)
        );
    }
    #[cfg(windows)]
    #[test]
    fn native_detection_returns_a_real_version() {
        let current = detect().unwrap();
        assert!(current.major >= 6);
        assert!(current.build > 0);
    }
}
