//! Windows power-scheme adapter. Enumerates existing schemes only.
use crate::power_session::{Backend, Scheme};
use std::ptr;
use windows_sys::{
    Win32::{
        Foundation::{ERROR_NO_MORE_ITEMS, ERROR_SUCCESS, LocalFree},
        System::Power::{
            ACCESS_SCHEME, PowerEnumerate, PowerGetActiveScheme, PowerSetActiveScheme,
        },
    },
    core::GUID,
};

fn from_guid(guid: GUID) -> Scheme {
    Scheme {
        data1: guid.data1,
        data2: guid.data2,
        data3: guid.data3,
        data4: guid.data4,
    }
}
fn to_guid(scheme: Scheme) -> GUID {
    GUID {
        data1: scheme.data1,
        data2: scheme.data2,
        data3: scheme.data3,
        data4: scheme.data4,
    }
}
pub struct WindowsPower;
impl Backend for WindowsPower {
    fn active(&mut self) -> Result<Scheme, String> {
        let mut pointer: *mut GUID = ptr::null_mut();
        let status = unsafe { PowerGetActiveScheme(ptr::null_mut(), &mut pointer) };
        if status != ERROR_SUCCESS || pointer.is_null() {
            if !pointer.is_null() {
                unsafe {
                    LocalFree(pointer.cast());
                }
            }
            return Err(format!(
                "Não foi possível consultar o plano de energia (erro {status})."
            ));
        }
        let result = from_guid(unsafe { *pointer });
        unsafe {
            LocalFree(pointer.cast());
        }
        Ok(result)
    }
    fn available(&mut self, scheme: Scheme) -> Result<bool, String> {
        for index in 0..4096 {
            let mut guid = GUID::from_u128(0);
            let mut size = std::mem::size_of::<GUID>() as u32;
            let status = unsafe {
                PowerEnumerate(
                    ptr::null_mut(),
                    ptr::null(),
                    ptr::null(),
                    ACCESS_SCHEME,
                    index,
                    (&mut guid as *mut GUID).cast(),
                    &mut size,
                )
            };
            if status == ERROR_NO_MORE_ITEMS {
                return Ok(false);
            }
            if status != ERROR_SUCCESS || size != std::mem::size_of::<GUID>() as u32 {
                return Err(format!(
                    "Não foi possível listar os planos de energia (erro {status})."
                ));
            }
            if from_guid(guid) == scheme {
                return Ok(true);
            }
        }
        Err("A lista de planos de energia é grande demais.".into())
    }
    fn set_active(&mut self, expected: Scheme, target: Scheme) -> Result<(), String> {
        if self.active()? != expected {
            return Err("O plano de energia mudou antes da gravação.".into());
        }
        if !self.available(target)? {
            return Err("O plano de energia não está disponível neste computador.".into());
        }
        let status = unsafe { PowerSetActiveScheme(ptr::null_mut(), &to_guid(target)) };
        if status != ERROR_SUCCESS {
            return Err(format!(
                "O Windows não permitiu mudar o plano de energia (erro {status})."
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_active_power_plan_and_enumerates_it() {
        let mut power = WindowsPower;
        if let Ok(active) = power.active() {
            assert!(power.available(active).unwrap());
        }
    }
    #[test]
    #[ignore = "Temporarily changes power plan; run only on a disposable Windows runner"]
    fn disposable_power_session_round_trip() {
        use crate::{
            power_session::{self, BeginResult, EndResult, HIGH_PERFORMANCE},
            storage::FileStore,
            windows_process,
        };
        use windows_sys::Win32::System::Power::{PowerDeleteScheme, PowerDuplicateScheme};
        let mut power = WindowsPower;
        let initial = power.active().unwrap();
        struct Restore {
            initial: Scheme,
            created: Vec<Scheme>,
        }
        impl Drop for Restore {
            fn drop(&mut self) {
                let mut power = WindowsPower;
                if let Ok(current) = power.active()
                    && current != self.initial
                {
                    let _ = power.set_active(current, self.initial);
                }
                if power.active().ok() == Some(self.initial) {
                    for scheme in &self.created {
                        unsafe {
                            PowerDeleteScheme(ptr::null_mut(), &to_guid(*scheme));
                        }
                    }
                }
            }
        }
        let mut restore = Restore {
            initial,
            created: Vec::new(),
        };
        let mut original = initial;
        if original == HIGH_PERFORMANCE {
            let mut allocated = ptr::null_mut();
            let status = unsafe {
                PowerDuplicateScheme(ptr::null_mut(), &to_guid(original), &mut allocated)
            };
            assert_eq!(
                status, ERROR_SUCCESS,
                "Could not create isolated original scheme: {status}"
            );
            assert!(!allocated.is_null());
            original = from_guid(unsafe { *allocated });
            unsafe {
                LocalFree(allocated.cast());
            }
            restore.created.push(original);
            power.set_active(initial, original).unwrap();
        }
        if !power.available(HIGH_PERFORMANCE).unwrap() {
            let mut desired = to_guid(HIGH_PERFORMANCE);
            let mut destination = &mut desired as *mut GUID;
            let status = unsafe {
                PowerDuplicateScheme(ptr::null_mut(), &to_guid(original), &mut destination)
            };
            assert_eq!(
                status, ERROR_SUCCESS,
                "Could not create isolated target scheme: {status}"
            );
            restore.created.push(HIGH_PERFORMANCE);
        }
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("power-test-{unique}"));
        let process = windows_process::identity(std::process::id()).unwrap();
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                power_session::begin(&mut power, &mut store, process).unwrap(),
                BeginResult::Applied
            );
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                power_session::end(&mut power, &mut store).unwrap(),
                EndResult::Restored
            );
        }
        assert_eq!(power.active().unwrap(), original);
        let root = std::fs::canonicalize(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target"),
        )
        .unwrap();
        let resolved = std::fs::canonicalize(directory).unwrap();
        assert_eq!(resolved.parent(), Some(root.as_path()));
        std::fs::remove_dir_all(resolved).unwrap();
    }
}
