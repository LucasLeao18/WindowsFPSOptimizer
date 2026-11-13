//! Pagefile adapter backed by the `PagingFiles` registry value, which is the
//! source Windows and WMI use for `Win32_PageFileSetting`. Writing it requires
//! administrator rights and takes effect after a restart.
use crate::pagefile_transaction::{self, Backend, Setting, State};
use std::{io, ptr};
use windows_sys::Win32::{
    Foundation::{ERROR_ACCESS_DENIED, ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA, ERROR_SUCCESS},
    System::Registry::*,
};

const KEY: &str = r"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management";
const VALUE: &str = "PagingFiles";
const AUTOMATIC: &str = r"?:\pagefile.sys";

pub struct WindowsPagefile {
    root: HKEY,
    path: String,
}

impl Default for WindowsPagefile {
    fn default() -> Self {
        Self {
            root: HKEY_LOCAL_MACHINE,
            path: KEY.into(),
        }
    }
}

/// Parses the lines of `PagingFiles`. Only the layouts that can be restored
/// exactly are accepted: the automatic marker alone, or `X:\pagefile.sys`
/// followed by an initial and a maximum size in MB.
pub fn parse(lines: &[String]) -> Result<State, String> {
    let lines: Vec<&str> = lines
        .iter()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty())
        .collect();
    if lines.iter().any(|line| line.starts_with("?:")) {
        let [only] = lines.as_slice() else {
            return Err("Configuração de memória virtual ambígua; nada será alterado.".into());
        };
        let mut parts = only.split_whitespace();
        if !parts
            .next()
            .is_some_and(|name| name.eq_ignore_ascii_case(AUTOMATIC))
        {
            return Err("Configuração automática de memória virtual não reconhecida.".into());
        }
        return Ok(State {
            automatic: true,
            settings: Vec::new(),
        });
    }
    let settings = lines
        .iter()
        .map(|line| {
            let parts: Vec<&str> = line.split_whitespace().collect();
            let [name, initial, maximum] = parts.as_slice() else {
                return Err(
                    "Formato de memória virtual não suportado; nenhuma alteração será feita."
                        .to_string(),
                );
            };
            let size = |value: &str| {
                value
                    .parse::<u32>()
                    .map_err(|_| "Tamanho de memória virtual inválido.".to_string())
            };
            Ok(Setting {
                name: (*name).to_string(),
                initial_mb: size(initial)?,
                maximum_mb: size(maximum)?,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    pagefile_transaction::normalize(State {
        automatic: false,
        settings,
    })
}

pub fn format(state: &State) -> Vec<String> {
    if state.automatic {
        return vec![AUTOMATIC.into()];
    }
    state
        .settings
        .iter()
        .map(|s| format!("{} {} {}", s.name, s.initial_mb, s.maximum_mb))
        .collect()
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

fn error(operation: &str, code: u32) -> String {
    if code == ERROR_ACCESS_DENIED {
        return format!("{operation}: é necessário executar o aplicativo como administrador.");
    }
    format!(
        "{operation}: {} (código {code}).",
        io::Error::from_raw_os_error(code as i32)
    )
}

impl WindowsPagefile {
    fn open(&self, access: u32) -> Result<Key, String> {
        let path = wide(&self.path);
        let mut raw: HKEY = ptr::null_mut();
        let status = unsafe {
            RegOpenKeyExW(
                self.root,
                path.as_ptr(),
                0,
                access | KEY_WOW64_64KEY,
                &mut raw,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(error(
                "Não foi possível abrir a configuração de memória virtual",
                status,
            ));
        }
        Ok(Key(raw))
    }

    fn read_lines(&self) -> Result<Vec<String>, String> {
        let key = self.open(KEY_QUERY_VALUE)?;
        let name = wide(VALUE);
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
                return Ok(Vec::new());
            }
            if status != ERROR_SUCCESS {
                return Err(error("Não foi possível ler a memória virtual", status));
            }
            if kind != REG_MULTI_SZ || size > 64 * 1024 {
                return Err("Formato de memória virtual não suportado.".into());
            }
            let mut buffer = vec![0u16; (size as usize).div_ceil(2)];
            let status = unsafe {
                RegQueryValueExW(
                    key.0,
                    name.as_ptr(),
                    ptr::null(),
                    &mut kind,
                    buffer.as_mut_ptr().cast(),
                    &mut size,
                )
            };
            if status == ERROR_MORE_DATA {
                continue;
            }
            if status != ERROR_SUCCESS {
                return Err(error("Não foi possível ler a memória virtual", status));
            }
            buffer.truncate(size as usize / 2);
            return Ok(buffer
                .split(|unit| *unit == 0)
                .filter(|line| !line.is_empty())
                .map(String::from_utf16_lossy)
                .collect());
        }
        Err("A memória virtual mudou durante a leitura; tente novamente.".into())
    }

    fn write_state(&self, expected: &State, target: &State) -> Result<(), String> {
        if &self.snapshot_now()? != expected {
            return Err("A memória virtual mudou desde a análise; nada foi alterado.".into());
        }
        let mut data: Vec<u16> = Vec::new();
        for line in format(target) {
            data.extend(line.encode_utf16());
            data.push(0);
        }
        data.push(0);
        let key = self.open(KEY_SET_VALUE | KEY_QUERY_VALUE)?;
        let name = wide(VALUE);
        let status = unsafe {
            RegSetValueExW(
                key.0,
                name.as_ptr(),
                0,
                REG_MULTI_SZ,
                data.as_ptr().cast(),
                (data.len() * 2) as u32,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(error("Não foi possível alterar a memória virtual", status));
        }
        Ok(())
    }

    fn snapshot_now(&self) -> Result<State, String> {
        parse(&self.read_lines()?)
    }
}

impl Backend for WindowsPagefile {
    fn snapshot(&mut self) -> Result<State, String> {
        self.snapshot_now()
    }
    fn set_automatic(&mut self, expected: &State) -> Result<(), String> {
        self.write_state(
            expected,
            &State {
                automatic: true,
                settings: Vec::new(),
            },
        )
    }
    fn restore_exact(&mut self, expected: &State, original: &State) -> Result<(), String> {
        self.write_state(expected, original)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn lines(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }
    #[test]
    fn parses_and_formats_supported_layouts() {
        let automatic = parse(&lines(&[r"?:\pagefile.sys"])).unwrap();
        assert!(automatic.automatic && automatic.settings.is_empty());
        assert_eq!(format(&automatic), lines(&[r"?:\pagefile.sys"]));
        let manual = parse(&lines(&[
            r"d:\pagefile.sys 0 0",
            r"C:\pagefile.sys 4096 8192",
        ]))
        .unwrap();
        assert!(!manual.automatic);
        assert_eq!(
            format(&manual),
            lines(&[r"C:\PAGEFILE.SYS 4096 8192", r"D:\PAGEFILE.SYS 0 0"])
        );
        assert_eq!(parse(&format(&manual)).unwrap(), manual);
        let none = parse(&[]).unwrap();
        assert!(!none.automatic && none.settings.is_empty());
    }
    #[test]
    fn rejects_unrecoverable_layouts() {
        for invalid in [
            vec![r"?:\pagefile.sys", r"C:\pagefile.sys 0 0"],
            vec![r"C:\pagefile.sys"],
            vec![r"C:\pagefile.sys 1 x"],
            vec![r"C:\other\pagefile.sys 0 0"],
            vec![r"?:\swap.sys"],
        ] {
            assert!(parse(&lines(&invalid)).is_err(), "{invalid:?}");
        }
    }
    #[test]
    fn isolated_registry_round_trip_restores_manual_layout() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = format!(
            r"Software\WindowsFPSOptimizerRustTests\pagefile-{}-{unique}",
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
        let mut raw: HKEY = ptr::null_mut();
        assert_eq!(
            unsafe {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
                    wide(&path).as_ptr(),
                    0,
                    ptr::null(),
                    REG_OPTION_NON_VOLATILE,
                    KEY_ALL_ACCESS,
                    ptr::null(),
                    &mut raw,
                    ptr::null_mut(),
                )
            },
            ERROR_SUCCESS
        );
        drop(Key(raw));
        let mut backend = WindowsPagefile {
            root: HKEY_CURRENT_USER,
            path,
        };
        let empty = backend.snapshot().unwrap();
        let original = parse(&lines(&[r"C:\pagefile.sys 2048 4096"])).unwrap();
        backend.restore_exact(&empty, &original).unwrap();
        assert_eq!(backend.snapshot().unwrap(), original);
        let mut store = MemoryStore::default();
        assert_eq!(
            pagefile_transaction::begin(&mut backend, &mut store).unwrap(),
            pagefile_transaction::BeginResult::Applied
        );
        assert!(backend.snapshot().unwrap().automatic);
        assert_eq!(
            pagefile_transaction::restore(&mut backend, &mut store).unwrap(),
            pagefile_transaction::RestoreResult::Restored
        );
        assert_eq!(backend.snapshot().unwrap(), original);
        assert!(backend.set_automatic(&empty).is_err());
    }
    #[derive(Default)]
    struct MemoryStore(Option<pagefile_transaction::Journal>);
    impl pagefile_transaction::Store for MemoryStore {
        fn load_pagefile(&mut self) -> Result<Option<pagefile_transaction::Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_pagefile(&mut self, j: &pagefile_transaction::Journal) -> Result<(), String> {
            self.0 = Some(j.clone());
            Ok(())
        }
        fn update_pagefile(
            &mut self,
            _: &pagefile_transaction::Journal,
            j: &pagefile_transaction::Journal,
        ) -> Result<(), String> {
            self.0 = Some(j.clone());
            Ok(())
        }
        fn clear_pagefile(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    #[test]
    #[ignore = "Read-only query of the machine pagefile configuration"]
    fn reads_complete_pagefile_snapshot_without_changes() {
        let first = WindowsPagefile::default().snapshot().unwrap();
        assert!(first.settings.len() <= 26);
        assert_eq!(
            pagefile_transaction::normalize(first.clone()).unwrap(),
            first
        );
    }
}
