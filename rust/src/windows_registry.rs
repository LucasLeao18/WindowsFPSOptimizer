//! Windows registry adapter. Registry paths are hard-coded, never loaded from a backup.
use crate::transaction::{Backend, Setting, Value};
use std::{io, ptr};
use windows_sys::Win32::{
    Foundation::{ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA, ERROR_SUCCESS},
    System::Registry::*,
};

#[derive(Default)]
pub struct WindowsRegistry {
    #[cfg(test)]
    test_root: Option<String>,
}

struct Key(HKEY);
impl Drop for Key {
    fn drop(&mut self) {
        unsafe {
            RegCloseKey(self.0);
        }
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn info(setting: Setting) -> Result<(&'static str, &'static str), String> {
    match setting {
        Setting::GameMode => Ok((r"Software\Microsoft\GameBar", "AutoGameModeEnabled")),
        Setting::Transparency => Ok((
            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "EnableTransparency",
        )),
        // A machine policy must not be changed until edition and management state
        // can be verified and the journal is protected across elevation.
        Setting::GameCapturePolicy => Err(
            "A política de captura exige verificação de compatibilidade e administração.".into(),
        ),
        _ => Err("Esta opção não é um valor do registro suportado.".into()),
    }
}
fn error(operation: &str, code: u32) -> String {
    format!(
        "{operation}: {} (código {code}).",
        io::Error::from_raw_os_error(code as i32)
    )
}
fn open(
    adapter: &WindowsRegistry,
    setting: Setting,
    access: u32,
    create: bool,
) -> Result<Option<(Key, Vec<u16>)>, String> {
    let (path, name) = info(setting)?;
    #[cfg(test)]
    let path = adapter.test_root.as_deref().unwrap_or(path);
    #[cfg(not(test))]
    let _ = adapter;
    let path = wide(path);
    let mut raw: HKEY = ptr::null_mut();
    let status = unsafe {
        if create {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                path.as_ptr(),
                0,
                ptr::null(),
                REG_OPTION_NON_VOLATILE,
                access,
                ptr::null(),
                &mut raw,
                ptr::null_mut(),
            )
        } else {
            RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, access, &mut raw)
        }
    };
    if status == ERROR_FILE_NOT_FOUND && !create {
        return Ok(None);
    }
    if status != ERROR_SUCCESS {
        return Err(error("Não foi possível abrir a configuração", status));
    }
    Ok(Some((Key(raw), wide(name))))
}

impl Backend for WindowsRegistry {
    fn read(&mut self, setting: Setting) -> Result<Option<Value>, String> {
        if setting.is_system_parameter() {
            return crate::windows_visual::read(setting).map(Some);
        }
        let Some((key, name)) = open(self, setting, KEY_QUERY_VALUE, false)? else {
            return Ok(None);
        };
        for _ in 0..3 {
            let mut kind = 0;
            let mut size = 0;
            let status = unsafe {
                RegQueryValueExW(
                    key.0,
                    name.as_ptr(),
                    ptr::null(),
                    &mut kind,
                    ptr::null_mut(),
                    &mut size,
                )
            };
            if status == ERROR_FILE_NOT_FOUND {
                return Ok(None);
            }
            if status != ERROR_SUCCESS {
                return Err(error("Não foi possível ler a configuração", status));
            }
            if size > 1024 * 1024 {
                return Err("Valor do registro excede o limite de backup.".into());
            }
            let mut bytes = vec![0; size as usize];
            let status = unsafe {
                RegQueryValueExW(
                    key.0,
                    name.as_ptr(),
                    ptr::null(),
                    &mut kind,
                    bytes.as_mut_ptr(),
                    &mut size,
                )
            };
            if status == ERROR_MORE_DATA {
                continue;
            }
            if status == ERROR_FILE_NOT_FOUND {
                return Ok(None);
            }
            if status != ERROR_SUCCESS {
                return Err(error("Não foi possível ler a configuração", status));
            }
            bytes.truncate(size as usize);
            return Ok(Some(Value { kind, bytes }));
        }
        Err("A configuração mudou durante a leitura; tente novamente.".into())
    }
    fn write(&mut self, setting: Setting, value: &Value) -> Result<(), String> {
        if setting.is_system_parameter() {
            return crate::windows_visual::write(setting, value);
        }
        let (key, name) =
            open(self, setting, KEY_SET_VALUE, true)?.ok_or("Chave de registro indisponível")?;
        let status = unsafe {
            RegSetValueExW(
                key.0,
                name.as_ptr(),
                0,
                value.kind,
                value.bytes.as_ptr(),
                value.bytes.len() as u32,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(error("Não foi possível salvar a configuração", status));
        }
        Ok(())
    }
    fn delete(&mut self, setting: Setting) -> Result<(), String> {
        if setting.is_system_parameter() {
            return Err("A configuração visual não pode ser removida.".into());
        }
        let Some((key, name)) = open(self, setting, KEY_SET_VALUE, false)? else {
            return Ok(());
        };
        let status = unsafe { RegDeleteValueW(key.0, name.as_ptr()) };
        if status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND {
            return Err(error("Não foi possível restaurar a configuração", status));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_writes_and_deletes_only_isolated_test_values() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = format!(
            r"Software\WindowsFPSOptimizerRustTests\test-{}-{unique}",
            std::process::id()
        );
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                unsafe {
                    RegDeleteTreeW(HKEY_CURRENT_USER, wide(&self.0).as_ptr());
                }
            }
        }
        let _cleanup = Cleanup(path.clone());
        let mut adapter = WindowsRegistry {
            test_root: Some(path),
        };
        assert_eq!(adapter.read(Setting::GameMode).unwrap(), None);
        let raw = Value {
            kind: REG_BINARY,
            bytes: vec![0, 255, 42],
        };
        adapter.write(Setting::GameMode, &raw).unwrap();
        assert_eq!(adapter.read(Setting::GameMode).unwrap(), Some(raw));
        adapter
            .write(Setting::Transparency, &Value::dword(0))
            .unwrap();
        assert_eq!(
            adapter.read(Setting::Transparency).unwrap(),
            Some(Value::dword(0))
        );
        adapter.delete(Setting::GameMode).unwrap();
        assert_eq!(adapter.read(Setting::GameMode).unwrap(), None);
        assert_eq!(
            adapter.read(Setting::Transparency).unwrap(),
            Some(Value::dword(0))
        );
        assert!(
            adapter
                .write(Setting::GameCapturePolicy, &Value::dword(0))
                .is_err()
        );
    }
    #[test]
    fn isolated_registry_transaction_recovers_after_reopening_backup() {
        use crate::{
            storage::FileStore,
            transaction::{self, Store},
        };
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let key = format!(
            r"Software\WindowsFPSOptimizerRustTests\transaction-{}-{unique}",
            std::process::id()
        );
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                unsafe {
                    RegDeleteTreeW(HKEY_CURRENT_USER, wide(&self.0).as_ptr());
                }
            }
        }
        let _cleanup = Cleanup(key.clone());
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("registry-transaction-{unique}"));
        let mut backend = WindowsRegistry {
            test_root: Some(key),
        };
        let initial = Value {
            kind: REG_BINARY,
            bytes: vec![1, 2, 3],
        };
        backend.write(Setting::GameMode, &initial).unwrap();
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            let plan = transaction::prepare(
                &mut backend,
                &[
                    (Setting::GameMode, Value::dword(1)),
                    (Setting::Transparency, Value::dword(0)),
                ],
            )
            .unwrap();
            transaction::apply(&mut backend, &mut store, &plan).unwrap();
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            let saved = store.load().unwrap().unwrap();
            assert_eq!(
                transaction::restore(&mut backend, &mut store, &saved)
                    .unwrap()
                    .restored
                    .len(),
                2
            );
            assert_eq!(backend.read(Setting::GameMode).unwrap(), Some(initial));
            assert_eq!(backend.read(Setting::Transparency).unwrap(), None);
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
