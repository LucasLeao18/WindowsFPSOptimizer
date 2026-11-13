//! HKCU Run entries only. No executable is launched or interpreted.
use crate::{
    startup::{Backend, Item},
    transaction::Value,
};
use std::{io, ptr};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA, ERROR_NO_MORE_ITEMS, ERROR_SUCCESS,
        HANDLE, INVALID_HANDLE_VALUE,
    },
    Storage::FileSystem::{CommitTransaction, CreateTransaction, RollbackTransaction},
    System::Registry::*,
};

const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
#[derive(Default)]
pub struct WindowsStartup {
    #[cfg(test)]
    test_root: Option<String>,
}
#[derive(Debug)]
pub struct Inventory {
    pub items: Vec<Item>,
    pub skipped: usize,
    pub truncated: bool,
}
struct Key(HKEY);
struct Transaction {
    handle: HANDLE,
    committed: bool,
}
impl Drop for Transaction {
    fn drop(&mut self) {
        unsafe {
            if !self.committed {
                RollbackTransaction(self.handle);
            }
            CloseHandle(self.handle);
        }
    }
}
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
    format!(
        "{operation}: {} (código {code}).",
        io::Error::from_raw_os_error(code as i32)
    )
}
impl WindowsStartup {
    fn path(&self) -> &str {
        #[cfg(test)]
        {
            self.test_root.as_deref().unwrap_or(RUN)
        }
        #[cfg(not(test))]
        {
            RUN
        }
    }
    fn open(&self, access: u32, create: bool) -> Result<Option<Key>, String> {
        let path = self.path();
        let mut raw = ptr::null_mut();
        let result = unsafe {
            if create {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
                    wide(path).as_ptr(),
                    0,
                    ptr::null(),
                    REG_OPTION_NON_VOLATILE,
                    access,
                    ptr::null(),
                    &mut raw,
                    ptr::null_mut(),
                )
            } else {
                RegOpenKeyExW(HKEY_CURRENT_USER, wide(path).as_ptr(), 0, access, &mut raw)
            }
        };
        if result == ERROR_FILE_NOT_FOUND && !create {
            return Ok(None);
        }
        if result != ERROR_SUCCESS {
            return Err(error("Não foi possível abrir a inicialização", result));
        }
        Ok(Some(Key(raw)))
    }
    fn change_transactionally(&self, item: &Item, deleting: bool) -> Result<(), String> {
        crate::startup::validate_item(item)?;
        let handle =
            unsafe { CreateTransaction(ptr::null_mut(), ptr::null_mut(), 0, 0, 0, 0, ptr::null()) };
        if handle == INVALID_HANDLE_VALUE || handle.is_null() {
            return Err(format!(
                "O Windows não disponibilizou transações de registro: {}",
                io::Error::last_os_error()
            ));
        }
        let mut transaction = Transaction {
            handle,
            committed: false,
        };
        let mut raw = ptr::null_mut();
        let path = wide(self.path());
        let status = unsafe {
            if deleting {
                RegOpenKeyTransactedW(
                    HKEY_CURRENT_USER,
                    path.as_ptr(),
                    0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE,
                    &mut raw,
                    handle,
                    ptr::null(),
                )
            } else {
                RegCreateKeyTransactedW(
                    HKEY_CURRENT_USER,
                    path.as_ptr(),
                    0,
                    ptr::null(),
                    REG_OPTION_NON_VOLATILE,
                    KEY_QUERY_VALUE | KEY_SET_VALUE,
                    ptr::null(),
                    &mut raw,
                    ptr::null_mut(),
                    handle,
                    ptr::null(),
                )
            }
        };
        if status != ERROR_SUCCESS {
            return Err(error(
                "Não foi possível abrir a transação de inicialização",
                status,
            ));
        }
        let key = Key(raw);
        let current = read_key(&key, &item.name)?;
        if deleting && current != Some(item.value.clone()) {
            return Err("O item mudou antes da desativação.".into());
        }
        if !deleting && current.is_some() {
            return Err("Outro programa recriou o item; ele foi preservado.".into());
        }
        let status = unsafe {
            if deleting {
                RegDeleteValueW(key.0, wide(&item.name).as_ptr())
            } else {
                RegSetValueExW(
                    key.0,
                    wide(&item.name).as_ptr(),
                    0,
                    item.value.kind,
                    item.value.bytes.as_ptr(),
                    item.value.bytes.len() as u32,
                )
            }
        };
        if status != ERROR_SUCCESS {
            return Err(error(
                "Não foi possível alterar o item de inicialização",
                status,
            ));
        }
        drop(key);
        if unsafe { CommitTransaction(handle) } == 0 {
            return Err(format!(
                "A transação foi recusada ou entrou em conflito: {}",
                io::Error::last_os_error()
            ));
        }
        transaction.committed = true;
        Ok(())
    }
    pub fn list(&mut self) -> Result<Inventory, String> {
        let Some(key) = self.open(KEY_QUERY_VALUE, false)? else {
            return Ok(Inventory {
                items: Vec::new(),
                skipped: 0,
                truncated: false,
            });
        };
        let mut inventory = Inventory {
            items: Vec::new(),
            skipped: 0,
            truncated: false,
        };
        let mut total_bytes = 0usize;
        for index in 0..10_000u32 {
            let mut name = vec![0u16; 16_384];
            let mut size = name.len() as u32;
            let status = unsafe {
                RegEnumValueW(
                    key.0,
                    index,
                    name.as_mut_ptr(),
                    &mut size,
                    ptr::null(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            };
            if status == ERROR_NO_MORE_ITEMS {
                return Ok(inventory);
            }
            if status != ERROR_SUCCESS || size as usize >= name.len() {
                return Err(error("Não foi possível listar a inicialização", status));
            }
            let Ok(name) = String::from_utf16(&name[..size as usize]) else {
                inventory.skipped += 1;
                continue;
            };
            if name.is_empty() {
                inventory.skipped += 1;
                continue;
            }
            if let Ok(Some(value)) = self.read(&name) {
                total_bytes = total_bytes
                    .saturating_add(name.len())
                    .saturating_add(value.bytes.len());
                if total_bytes > 8 * 1024 * 1024 {
                    inventory.truncated = true;
                    return Ok(inventory);
                }
                inventory.items.push(Item { name, value });
            } else {
                inventory.skipped += 1;
            }
        }
        inventory.truncated = true;
        Ok(inventory)
    }
}
fn read_key(key: &Key, name: &str) -> Result<Option<Value>, String> {
    if name.is_empty() || name.contains('\0') || name.encode_utf16().count() > 16_383 {
        return Err("Nome de inicialização inválido.".into());
    }
    for _ in 0..3 {
        let mut kind = 0;
        let mut size = 0;
        let mut status = unsafe {
            RegQueryValueExW(
                key.0,
                wide(name).as_ptr(),
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
            return Err(error("Não foi possível ler o item", status));
        }
        if size > 16_384 {
            return Err("O comando de inicialização é grande demais.".into());
        }
        let mut bytes = vec![0u8; size as usize];
        status = unsafe {
            RegQueryValueExW(
                key.0,
                wide(name).as_ptr(),
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
            return Err(error("Não foi possível ler o item", status));
        }
        bytes.truncate(size as usize);
        return Ok(Some(Value { kind, bytes }));
    }
    Err("O item mudou durante a leitura; atualize a lista.".into())
}
impl Backend for WindowsStartup {
    fn read(&mut self, name: &str) -> Result<Option<Value>, String> {
        let Some(key) = self.open(KEY_QUERY_VALUE, false)? else {
            return Ok(None);
        };
        read_key(&key, name)
    }
    fn delete_expected(&mut self, item: &Item) -> Result<(), String> {
        self.change_transactionally(item, true)
    }
    fn restore_if_absent(&mut self, item: &Item) -> Result<(), String> {
        self.change_transactionally(item, false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        startup::{self, RestoreResult},
        storage::FileStore,
    };
    #[test]
    fn isolated_registry_entry_round_trip_with_reopened_backup() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = format!(
            r"Software\WindowsFPSOptimizerRustTests\startup-{}-{unique}",
            std::process::id()
        );
        struct KeyCleanup(String);
        impl Drop for KeyCleanup {
            fn drop(&mut self) {
                unsafe {
                    RegDeleteTreeW(HKEY_CURRENT_USER, wide(&self.0).as_ptr());
                }
            }
        }
        let _cleanup = KeyCleanup(path.clone());
        let mut backend = WindowsStartup {
            test_root: Some(path),
        };
        let item = Item {
            name: "Fixture".into(),
            value: Value {
                kind: REG_SZ,
                bytes: r"C:\Fixture\game.exe"
                    .encode_utf16()
                    .chain(Some(0))
                    .flat_map(u16::to_le_bytes)
                    .collect(),
            },
        };
        backend.restore_if_absent(&item).unwrap();
        let inventory = backend.list().unwrap();
        assert_eq!(inventory.items, vec![item.clone()]);
        assert_eq!(inventory.skipped, 0);
        assert!(!inventory.truncated);
        let directory = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("startup-store-{unique}"));
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            startup::disable(&mut backend, &mut store, &item).unwrap();
            assert_eq!(backend.read(&item.name).unwrap(), None);
            let archive = store.archive_startup().unwrap();
            let outside = directory.join("outside.json");
            std::fs::copy(&archive, &outside).unwrap();
            assert!(store.activate_startup(&outside).is_err());
            store.activate_startup(&archive).unwrap();
            assert!(store.activate_startup(&archive).is_err());
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(
                startup::restore(&mut backend, &mut store, &item.name).unwrap(),
                RestoreResult::Restored
            );
            assert_eq!(backend.read(&item.name).unwrap(), Some(item.value));
        }
        let target = std::fs::canonicalize(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target"),
        )
        .unwrap();
        let resolved = std::fs::canonicalize(directory).unwrap();
        assert_eq!(resolved.parent(), Some(target.as_path()));
        std::fs::remove_dir_all(resolved).unwrap();
    }
}
