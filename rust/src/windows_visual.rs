//! Documented Windows visual parameters, never arbitrary action codes.
use crate::transaction::{Setting, Value};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

fn actions(setting: Setting) -> Option<(u32, u32)> {
    match setting {
        Setting::WindowAnimations => Some((SPI_GETANIMATION, SPI_SETANIMATION)),
        Setting::ClientAreaAnimations => {
            Some((SPI_GETCLIENTAREAANIMATION, SPI_SETCLIENTAREAANIMATION))
        }
        Setting::MenuAnimations => Some((SPI_GETMENUANIMATION, SPI_SETMENUANIMATION)),
        Setting::MenuFade => Some((SPI_GETMENUFADE, SPI_SETMENUFADE)),
        Setting::SelectionFade => Some((SPI_GETSELECTIONFADE, SPI_SETSELECTIONFADE)),
        Setting::TooltipAnimations => Some((SPI_GETTOOLTIPANIMATION, SPI_SETTOOLTIPANIMATION)),
        Setting::TooltipFade => Some((SPI_GETTOOLTIPFADE, SPI_SETTOOLTIPFADE)),
        Setting::ComboBoxAnimations => Some((SPI_GETCOMBOBOXANIMATION, SPI_SETCOMBOBOXANIMATION)),
        Setting::SmoothListScrolling => {
            Some((SPI_GETLISTBOXSMOOTHSCROLLING, SPI_SETLISTBOXSMOOTHSCROLLING))
        }
        _ => None,
    }
}

pub fn read(setting: Setting) -> Result<Value, String> {
    let (get, _) = actions(setting).ok_or("Configuração visual desconhecida.")?;
    let value = if setting == Setting::WindowAnimations {
        let mut info = ANIMATIONINFO {
            cbSize: std::mem::size_of::<ANIMATIONINFO>() as u32,
            iMinAnimate: 0,
        };
        if unsafe {
            SystemParametersInfoW(
                get,
                info.cbSize,
                (&mut info as *mut ANIMATIONINFO).cast(),
                0,
            )
        } == 0
        {
            return Err(format!(
                "Não foi possível consultar o efeito visual: {}",
                std::io::Error::last_os_error()
            ));
        }
        info.iMinAnimate
    } else {
        let mut value = 0i32;
        if unsafe { SystemParametersInfoW(get, 0, (&mut value as *mut i32).cast(), 0) } == 0 {
            return Err(format!(
                "Não foi possível consultar o efeito visual: {}",
                std::io::Error::last_os_error()
            ));
        }
        value
    };
    Ok(Value::dword(u32::from(value != 0)))
}

pub fn write(setting: Setting, value: &Value) -> Result<(), String> {
    let (_, set) = actions(setting).ok_or("Configuração visual desconhecida.")?;
    let enabled = if *value == Value::dword(0) {
        false
    } else if *value == Value::dword(1) {
        true
    } else {
        return Err("Valor visual inválido.".into());
    };
    let flags = SPIF_UPDATEINIFILE | SPIF_SENDCHANGE;
    let result = if setting == Setting::WindowAnimations {
        let mut info = ANIMATIONINFO {
            cbSize: std::mem::size_of::<ANIMATIONINFO>() as u32,
            iMinAnimate: i32::from(enabled),
        };
        unsafe {
            SystemParametersInfoW(
                set,
                info.cbSize,
                (&mut info as *mut ANIMATIONINFO).cast(),
                flags,
            )
        }
    } else {
        unsafe {
            SystemParametersInfoW(set, 0, usize::from(enabled) as *mut std::ffi::c_void, flags)
        }
    };
    if result == 0 {
        Err(format!(
            "Não foi possível salvar o efeito visual: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unsupported_actions_and_non_boolean_values() {
        assert!(read(Setting::GameMode).is_err());
        assert!(write(Setting::ClientAreaAnimations, &Value::dword(2)).is_err());
    }
    #[test]
    fn reads_the_local_animation_setting_without_changes() {
        if let Ok(value) = read(Setting::ClientAreaAnimations) {
            assert!(value == Value::dword(0) || value == Value::dword(1));
        }
    }
    #[test]
    #[ignore = "Changes visual settings; run only on a disposable Windows runner"]
    fn disposable_visual_profile_round_trip() {
        use crate::{
            storage::FileStore,
            transaction::{self, Backend, Store},
        };
        let options = [
            Setting::WindowAnimations,
            Setting::ClientAreaAnimations,
            Setting::MenuAnimations,
            Setting::MenuFade,
            Setting::SelectionFade,
            Setting::TooltipAnimations,
            Setting::TooltipFade,
            Setting::ComboBoxAnimations,
            Setting::SmoothListScrolling,
        ];
        let originals: Vec<_> = options
            .into_iter()
            .filter_map(|setting| read(setting).ok().map(|value| (setting, value)))
            .collect();
        assert!(
            !originals.is_empty(),
            "No supported visual settings were available"
        );
        struct Guard(Vec<(Setting, Value)>);
        impl Drop for Guard {
            fn drop(&mut self) {
                for (setting, value) in &self.0 {
                    let _ = write(*setting, value);
                }
            }
        }
        let _guard = Guard(originals.clone());
        // Make one setting differ from the profile so the test exercises a real write.
        write(originals[0].0, &Value::dword(1)).unwrap();
        struct Visual;
        impl Backend for Visual {
            fn read(&mut self, setting: Setting) -> Result<Option<Value>, String> {
                super::read(setting).map(Some)
            }
            fn write(&mut self, setting: Setting, value: &Value) -> Result<(), String> {
                super::write(setting, value)
            }
            fn delete(&mut self, _: Setting) -> Result<(), String> {
                Err("unsupported".into())
            }
        }
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("visual-test-{unique}"));
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            let requested: Vec<_> = originals
                .iter()
                .map(|(setting, _)| (*setting, Value::dword(0)))
                .collect();
            let plan = transaction::prepare(&mut Visual, &requested).unwrap();
            assert!(!plan.entries.is_empty());
            transaction::apply(&mut Visual, &mut store, &plan).unwrap();
            let journal = store.load().unwrap().unwrap();
            let report = transaction::restore(&mut Visual, &mut store, &journal).unwrap();
            assert!(report.conflicts.is_empty() && report.errors.is_empty());
            assert_eq!(read(originals[0].0).unwrap(), Value::dword(1));
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
