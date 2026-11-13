//! Reversible, individually selected startup entries. The adapter fixes the
//! registry location; neither a preview nor a journal can supply a path.
use crate::transaction::Value;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const MAX_ITEMS: usize = 128;
const MAX_VALUE: usize = 16_384;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub name: String,
    pub value: Value,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    Pending,
    Armed,
    Applied,
    Reverting,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub item: Item,
    pub phase: Phase,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Journal {
    pub schema: u32,
    pub entries: Vec<Entry>,
}

pub trait Backend {
    fn read(&mut self, name: &str) -> Result<Option<Value>, String>;
    fn delete_expected(&mut self, item: &Item) -> Result<(), String>;
    fn restore_if_absent(&mut self, item: &Item) -> Result<(), String>;
}
pub trait Store {
    fn load_startup(&mut self) -> Result<Option<Journal>, String>;
    fn save_startup(&mut self, journal: &Journal) -> Result<(), String>;
    fn update_startup(&mut self, old: &Journal, new: &Journal) -> Result<(), String>;
    fn clear_startup(&mut self) -> Result<(), String>;
}
#[derive(Debug, Eq, PartialEq)]
pub enum RestoreResult {
    Restored,
    AlreadyOriginal,
    Conflict,
}

/// Only ordinary string commands are eligible; malformed or protected entries
/// stay untouched. This does not execute, expand, or resolve the command.
pub fn validate_item(item: &Item) -> Result<(), String> {
    if item.name.is_empty()
        || item.name.encode_utf16().count() > 16_383
        || item.name.contains('\0')
        || !matches!(item.value.kind, 1 | 2)
        || item.value.bytes.is_empty()
        || item.value.bytes.len() > MAX_VALUE
        || !item.value.bytes.len().is_multiple_of(2)
    {
        return Err("Item de inicialização inválido ou não suportado.".into());
    }
    let words: Vec<u16> = item
        .value
        .bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|part| u16::from_le_bytes([part[0], part[1]]))
        .collect();
    if words.last() != Some(&0) || words[..words.len() - 1].contains(&0) {
        return Err("Comando de inicialização inválido.".into());
    }
    let command = String::from_utf16(&words[..words.len() - 1])
        .map_err(|_| "Comando de inicialização inválido.")?;
    if command.trim().is_empty() {
        return Err("Comando de inicialização vazio.".into());
    }
    let text = format!("{} {}", item.name, command).to_lowercase();
    if [
        "securityhealth",
        "windows defender",
        "windowsdefender",
        "msascuil",
        "msmpeng",
        "antimalware",
        "crowdstrike",
        "sentinelone",
        "sophos",
        "kaspersky",
        "bitdefender",
        "malwarebytes",
        "easyanticheat",
        "battleye",
        "vgtray",
    ]
    .iter()
    .any(|pattern| text.contains(pattern))
    {
        return Err("Este item de segurança ou proteção é preservado pelo aplicativo.".into());
    }
    Ok(())
}
pub fn validate(journal: &Journal) -> Result<(), String> {
    if journal.schema != 1 || journal.entries.len() > MAX_ITEMS {
        return Err("Registro de inicialização inválido.".into());
    }
    let mut names = HashSet::new();
    for entry in &journal.entries {
        validate_item(&entry.item)?;
        if !names.insert(entry.item.name.to_lowercase()) {
            return Err("Itens de inicialização duplicados.".into());
        }
    }
    Ok(())
}

pub fn command_text(value: &Value) -> String {
    if !matches!(value.kind, 1 | 2)
        || value.bytes.len() > MAX_VALUE
        || !value.bytes.len().is_multiple_of(2)
    {
        return "(formato não suportado)".into();
    }
    let words: Vec<u16> = value
        .bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|part| u16::from_le_bytes(*part))
        .collect();
    match String::from_utf16(&words) {
        Ok(command) => command.trim_end_matches('\0').replace('\0', "�"),
        Err(_) => "(comando inválido)".into(),
    }
}
fn persist<S: Store>(store: &mut S, old: &Option<Journal>, new: &Journal) -> Result<(), String> {
    if let Some(old) = old {
        store.update_startup(old, new)
    } else {
        store.save_startup(new)
    }
}

pub fn disable<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    selected: &Item,
) -> Result<(), String> {
    validate_item(selected)?;
    let old = store.load_startup()?;
    let mut journal = old.clone().unwrap_or(Journal {
        schema: 1,
        entries: Vec::new(),
    });
    validate(&journal)?;
    if journal.entries.len() >= MAX_ITEMS
        || journal
            .entries
            .iter()
            .any(|entry| entry.item.name.to_lowercase() == selected.name.to_lowercase())
    {
        return Err("Este item já possui backup ou o limite de itens foi atingido.".into());
    }
    if backend.read(&selected.name)? != Some(selected.value.clone()) {
        return Err("O item mudou desde a análise; atualize a lista.".into());
    }
    journal.entries.push(Entry {
        item: selected.clone(),
        phase: Phase::Pending,
    });
    persist(store, &old, &journal)?;
    if backend.read(&selected.name)? != Some(selected.value.clone()) {
        return Err("O item mudou; o backup foi preservado.".into());
    }
    let mut armed = journal.clone();
    armed.entries.last_mut().unwrap().phase = Phase::Armed;
    store.update_startup(&journal, &armed)?;
    backend.delete_expected(selected)?;
    if backend.read(&selected.name)?.is_some() {
        return Err("Não foi possível confirmar a desativação; o backup foi preservado.".into());
    }
    let mut applied = armed.clone();
    applied.entries.last_mut().unwrap().phase = Phase::Applied;
    store.update_startup(&armed, &applied)
}

pub fn restore<B: Backend, S: Store>(
    backend: &mut B,
    store: &mut S,
    name: &str,
) -> Result<RestoreResult, String> {
    let journal = store
        .load_startup()?
        .ok_or("Não há itens de inicialização para restaurar.")?;
    validate(&journal)?;
    let index = journal
        .entries
        .iter()
        .position(|entry| entry.item.name.to_lowercase() == name.to_lowercase())
        .ok_or("Item não encontrado no backup.")?;
    let entry = &journal.entries[index];
    let current = backend.read(&entry.item.name)?;
    let result = if current == Some(entry.item.value.clone()) {
        RestoreResult::AlreadyOriginal
    } else if current.is_some() || entry.phase != Phase::Applied {
        return Ok(RestoreResult::Conflict);
    } else {
        let mut reverting = journal.clone();
        reverting.entries[index].phase = Phase::Reverting;
        store.update_startup(&journal, &reverting)?;
        backend.restore_if_absent(&entry.item)?;
        if backend.read(&entry.item.name)? != Some(entry.item.value.clone()) {
            return Err(
                "Não foi possível confirmar a restauração; o backup foi preservado.".into(),
            );
        }
        let mut completed = reverting.clone();
        completed.entries.remove(index);
        if completed.entries.is_empty() {
            store.clear_startup()?;
        } else {
            store.update_startup(&reverting, &completed)?;
        }
        return Ok(RestoreResult::Restored);
    };
    let mut completed = journal.clone();
    completed.entries.remove(index);
    if completed.entries.is_empty() {
        store.clear_startup()?;
    } else {
        store.update_startup(&journal, &completed)?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    #[derive(Default)]
    struct Fake(HashMap<String, Value>);
    impl Backend for Fake {
        fn read(&mut self, name: &str) -> Result<Option<Value>, String> {
            Ok(self.0.get(&name.to_lowercase()).cloned())
        }
        fn delete_expected(&mut self, item: &Item) -> Result<(), String> {
            if self.read(&item.name)? != Some(item.value.clone()) {
                return Err("changed".into());
            }
            self.0.remove(&item.name.to_lowercase());
            Ok(())
        }
        fn restore_if_absent(&mut self, item: &Item) -> Result<(), String> {
            if self.read(&item.name)?.is_some() {
                return Err("changed".into());
            }
            self.0.insert(item.name.to_lowercase(), item.value.clone());
            Ok(())
        }
    }
    #[derive(Default)]
    struct Memory(Option<Journal>);
    impl Store for Memory {
        fn load_startup(&mut self) -> Result<Option<Journal>, String> {
            Ok(self.0.clone())
        }
        fn save_startup(&mut self, journal: &Journal) -> Result<(), String> {
            if self.0.is_some() {
                return Err("exists".into());
            }
            self.0 = Some(journal.clone());
            Ok(())
        }
        fn update_startup(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("changed".into());
            }
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_startup(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    fn item(name: &str, command: &str) -> Item {
        Item {
            name: name.into(),
            value: Value {
                kind: 1,
                bytes: command
                    .encode_utf16()
                    .chain(Some(0))
                    .flat_map(u16::to_le_bytes)
                    .collect(),
            },
        }
    }
    #[test]
    fn restores_multiple_selections_independently() {
        let first = item("GameTool", "C:\\Apps\\tool.exe");
        let second = item("Helper", "C:\\Apps\\helper.exe");
        let mut backend = Fake::default();
        backend
            .0
            .insert(first.name.to_lowercase(), first.value.clone());
        backend
            .0
            .insert(second.name.to_lowercase(), second.value.clone());
        let mut store = Memory::default();
        disable(&mut backend, &mut store, &first).unwrap();
        disable(&mut backend, &mut store, &second).unwrap();
        assert_eq!(
            restore(&mut backend, &mut store, "gametool").unwrap(),
            RestoreResult::Restored
        );
        assert_eq!(store.0.as_ref().unwrap().entries.len(), 1);
        assert_eq!(
            restore(&mut backend, &mut store, "Helper").unwrap(),
            RestoreResult::Restored
        );
        assert!(store.0.is_none());
        assert_eq!(backend.read(&first.name).unwrap(), Some(first.value));
    }
    #[test]
    fn does_not_overwrite_external_changes_or_ambiguous_deletion() {
        let selected = item("GameTool", "C:\\Apps\\tool.exe");
        let mut backend = Fake::default();
        backend
            .0
            .insert(selected.name.to_lowercase(), selected.value.clone());
        let mut store = Memory::default();
        disable(&mut backend, &mut store, &selected).unwrap();
        let replacement = item("GameTool", "C:\\Apps\\new.exe");
        backend
            .0
            .insert(selected.name.to_lowercase(), replacement.value.clone());
        assert_eq!(
            restore(&mut backend, &mut store, &selected.name).unwrap(),
            RestoreResult::Conflict
        );
        assert_eq!(
            backend.read(&selected.name).unwrap(),
            Some(replacement.value)
        );
        backend.0.clear();
        store.0.as_mut().unwrap().entries[0].phase = Phase::Armed;
        assert_eq!(
            restore(&mut backend, &mut store, &selected.name).unwrap(),
            RestoreResult::Conflict
        );
        assert!(backend.0.is_empty());
    }
    #[test]
    fn refuses_stale_malformed_and_protected_items() {
        let selected = item("GameTool", "C:\\Apps\\tool.exe");
        let mut backend = Fake::default();
        let mut store = Memory::default();
        assert!(disable(&mut backend, &mut store, &selected).is_err());
        assert!(store.0.is_none());
        assert!(validate_item(&item("Windows Security", "securityhealthsystray.exe")).is_err());
        let mut bad = selected;
        bad.value.bytes.pop();
        assert!(validate_item(&bad).is_err());
    }
    #[test]
    fn concurrent_change_during_delete_keeps_backup_and_external_value() {
        struct Racing {
            selected: Item,
            replacement: Value,
        }
        impl Backend for Racing {
            fn read(&mut self, _: &str) -> Result<Option<Value>, String> {
                Ok(Some(self.selected.value.clone()))
            }
            fn delete_expected(&mut self, _: &Item) -> Result<(), String> {
                self.selected.value = self.replacement.clone();
                Err("transaction conflict".into())
            }
            fn restore_if_absent(&mut self, _: &Item) -> Result<(), String> {
                panic!("must not restore over external value")
            }
        }
        let selected = item("GameTool", "C:\\Apps\\old.exe");
        let replacement = item("GameTool", "C:\\Apps\\new.exe").value;
        let mut backend = Racing {
            selected: selected.clone(),
            replacement: replacement.clone(),
        };
        let mut store = Memory::default();
        assert!(disable(&mut backend, &mut store, &selected).is_err());
        assert_eq!(store.0.as_ref().unwrap().entries[0].phase, Phase::Armed);
        assert_eq!(
            restore(&mut backend, &mut store, &selected.name).unwrap(),
            RestoreResult::Conflict
        );
        assert_eq!(backend.selected.value, replacement);
    }
}
