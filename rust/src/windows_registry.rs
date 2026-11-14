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
const NETWORK_CLASS: &str =
    r"SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}";

struct Location {
    root: HKEY,
    path: String,
    name: &'static str,
}

fn user(path: &str, name: &'static str) -> Result<Location, String> {
    Ok(Location {
        root: HKEY_CURRENT_USER,
        path: path.into(),
        name,
    })
}
fn machine(path: String, name: &'static str) -> Result<Location, String> {
    Ok(Location {
        root: HKEY_LOCAL_MACHINE,
        path,
        name,
    })
}
fn adapter_path(index: u16) -> Result<String, String> {
    if index > 9999 {
        return Err("Adaptador de rede inválido.".into());
    }
    Ok(format!(r"{NETWORK_CLASS}\{index:04}"))
}
fn info(setting: Setting) -> Result<Location, String> {
    match setting {
        Setting::GameMode => user(r"Software\Microsoft\GameBar", "AutoGameModeEnabled"),
        Setting::Transparency => user(
            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "EnableTransparency",
        ),
        // Per-user "record what happened" setting; the policy is never touched.
        Setting::BackgroundRecording => user(
            r"Software\Microsoft\Windows\CurrentVersion\GameDVR",
            "HistoricalCaptureEnabled",
        ),
        Setting::AppCapture => user(
            r"Software\Microsoft\Windows\CurrentVersion\GameDVR",
            "AppCaptureEnabled",
        ),
        Setting::GameDvr => user(r"System\GameConfigStore", "GameDVR_Enabled"),
        Setting::NtfsLastAccess => machine(
            r"SYSTEM\CurrentControlSet\Control\FileSystem".into(),
            "NtfsDisableLastAccessUpdate",
        ),
        Setting::PerformanceCounters => machine(
            r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib".into(),
            "Disable Performance Counters",
        ),
        Setting::AdapterEnergyEfficient(index) => machine(adapter_path(index)?, "*EEE"),
        Setting::AdapterPowerManagement(index) => machine(adapter_path(index)?, "PnPCapabilities"),
        // A machine policy must not be changed until edition and management state
        // can be verified and the journal is protected across elevation.
        Setting::GameCapturePolicy => Err(
            "A política de captura exige verificação de compatibilidade e administração.".into(),
        ),
        _ => Err("Esta opção não é um valor do registro suportado.".into()),
    }
}
fn error(operation: &str, code: u32) -> String {
    if code == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
        return format!("{operation}: é necessário executar o aplicativo como administrador.");
    }
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
    #[allow(unused_mut)]
    let mut location = info(setting)?;
    #[cfg(test)]
    if let Some(root) = &adapter.test_root {
        location.root = HKEY_CURRENT_USER;
        location.path = root.clone();
    }
    #[cfg(not(test))]
    let _ = adapter;
    // Machine keys belong to Windows and drivers: they are opened, never created.
    let create = create && location.root == HKEY_CURRENT_USER;
    let access = access | KEY_WOW64_64KEY;
    let path = wide(&location.path);
    let mut raw: HKEY = ptr::null_mut();
    let status = unsafe {
        if create {
            RegCreateKeyExW(
                location.root,
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
            RegOpenKeyExW(location.root, path.as_ptr(), 0, access, &mut raw)
        }
    };
    if status == ERROR_FILE_NOT_FOUND {
        return Ok(None);
    }
    if status != ERROR_SUCCESS {
        return Err(error("Não foi possível abrir a configuração", status));
    }
    Ok(Some((Key(raw), wide(location.name))))
}

fn query_dword_or_string(key: HKEY, name: &str) -> Option<String> {
    let name = wide(name);
    let mut kind = 0u32;
    let mut buffer = [0u16; 64];
    let mut size = (buffer.len() * 2) as u32;
    let status = unsafe {
        RegQueryValueExW(
            key,
            name.as_ptr(),
            ptr::null(),
            &mut kind,
            buffer.as_mut_ptr().cast(),
            &mut size,
        )
    };
    if status != ERROR_SUCCESS {
        return None;
    }
    match kind {
        REG_DWORD if size == 4 => Some((buffer[0] as u32 | ((buffer[1] as u32) << 16)).to_string()),
        REG_SZ => {
            let units = &buffer[..(size as usize / 2).min(buffer.len())];
            Some(
                String::from_utf16_lossy(units)
                    .trim_end_matches('\0')
                    .to_string(),
            )
        }
        _ => None,
    }
}

/// Physical Ethernet adapters (IfType 6, 802.3 media) and whether each one
/// exposes the standardized Energy-Efficient Ethernet keyword. Read-only.
pub fn ethernet_adapters() -> Vec<(u16, bool)> {
    let mut found = Vec::new();
    let path = wide(NETWORK_CLASS);
    let mut class: HKEY = ptr::null_mut();
    if unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            path.as_ptr(),
            0,
            KEY_READ | KEY_WOW64_64KEY,
            &mut class,
        )
    } != ERROR_SUCCESS
    {
        return found;
    }
    let class = Key(class);
    for index in 0..512u32 {
        let mut name = [0u16; 32];
        let mut length = name.len() as u32;
        let status = unsafe {
            RegEnumKeyExW(
                class.0,
                index,
                name.as_mut_ptr(),
                &mut length,
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
            )
        };
        if status != ERROR_SUCCESS {
            break;
        }
        let name = String::from_utf16_lossy(&name[..length as usize]);
        let Ok(number) = name.parse::<u16>() else {
            continue;
        };
        if name.len() != 4 {
            continue;
        }
        let sub = wide(&name);
        let mut key: HKEY = ptr::null_mut();
        if unsafe { RegOpenKeyExW(class.0, sub.as_ptr(), 0, KEY_QUERY_VALUE, &mut key) }
            != ERROR_SUCCESS
        {
            continue;
        }
        let key = Key(key);
        let ethernet = query_dword_or_string(key.0, "*IfType").as_deref() == Some("6")
            && query_dword_or_string(key.0, "*PhysicalMediaType").as_deref() == Some("14");
        if ethernet {
            found.push((number, query_dword_or_string(key.0, "*EEE").is_some()));
        }
    }
    found
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

/// Read-only: the marketing name of the first processor, if available.
pub fn processor_name() -> Option<String> {
    let path = wide(r"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
    let mut key: HKEY = ptr::null_mut();
    if unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            path.as_ptr(),
            0,
            KEY_QUERY_VALUE,
            &mut key,
        )
    } != ERROR_SUCCESS
    {
        return None;
    }
    let key = Key(key);
    query_dword_or_string(key.0, "ProcessorNameString").map(|name| name.trim().to_string())
}

/// Read-only: whether Memory Integrity (HVCI) is enabled. `None` if unknown.
pub fn memory_integrity_enabled() -> Option<bool> {
    let path = wide(
        r"SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity",
    );
    let name = wide("Enabled");
    let mut key: HKEY = ptr::null_mut();
    if unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            path.as_ptr(),
            0,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY,
            &mut key,
        )
    } != ERROR_SUCCESS
    {
        return Some(false);
    }
    let key = Key(key);
    let (mut kind, mut value, mut size) = (0u32, 0u32, 4u32);
    let status = unsafe {
        RegQueryValueExW(
            key.0,
            name.as_ptr(),
            ptr::null(),
            &mut kind,
            (&mut value as *mut u32).cast(),
            &mut size,
        )
    };
    match status {
        ERROR_FILE_NOT_FOUND => Some(false),
        ERROR_SUCCESS if kind == REG_DWORD => Some(value != 0),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn machine_settings_round_trip_in_an_isolated_user_key() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = format!(
            r"Software\WindowsFPSOptimizerRustTests\machine-{}-{unique}",
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
        for setting in [
            Setting::NtfsLastAccess,
            Setting::AdapterEnergyEfficient(7),
            Setting::GameDvr,
        ] {
            assert_eq!(adapter.read(setting).unwrap(), None);
            adapter.write(setting, &setting.target()).unwrap();
            assert_eq!(adapter.read(setting).unwrap(), Some(setting.target()));
            adapter.delete(setting).unwrap();
            assert_eq!(adapter.read(setting).unwrap(), None);
        }
    }
    #[test]
    fn lists_ethernet_adapters_and_processor_without_changes() {
        assert_eq!(ethernet_adapters(), ethernet_adapters());
        assert!(processor_name().is_some_and(|name| !name.is_empty()));
    }
    #[test]
    fn reads_memory_integrity_state_without_changes() {
        assert_eq!(memory_integrity_enabled(), memory_integrity_enabled());
    }
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
