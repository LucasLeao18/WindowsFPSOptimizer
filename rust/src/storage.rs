//! Durable journal with a process-wide lock and exclusive creation.
use crate::{
    session::{SessionJournal, SessionStore},
    transaction::{Journal, Store},
};
use fs2::FileExt;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::PathBuf,
};
const MAX_JOURNAL_BYTES: usize = 4 * 1024 * 1024;

pub struct FileStore {
    file: PathBuf,
    session_file: PathBuf,
    _lock: File,
}

impl FileStore {
    pub fn acquire(directory: PathBuf) -> Result<Self, String> {
        fs::create_dir_all(&directory)
            .map_err(|e| format!("Não foi possível criar a pasta de backup: {e}"))?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("operation.lock"))
            .map_err(|e| e.to_string())?;
        lock.try_lock_exclusive()
            .map_err(|_| "Outra operação do otimizador está em andamento.".to_string())?;
        Ok(Self {
            file: directory.join("active.json"),
            session_file: directory.join("session.json"),
            _lock: lock,
        })
    }

    /// Preserve the original record before removing it from the active slot.
    /// This never changes a process or a Windows setting.
    pub fn archive_session(&mut self) -> Result<PathBuf, String> {
        let file = File::open(&self.session_file)
            .map_err(|e| format!("Não foi possível abrir o registro da sessão: {e}"))?;
        let mut bytes = Vec::new();
        file.take(65_537)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 65_536 {
            return Err(
                "O registro de sessão é grande demais para arquivar automaticamente.".into(),
            );
        }
        let parent = self
            .session_file
            .parent()
            .ok_or("Pasta de sessão inválida.")?;
        let history = parent.join("History");
        fs::create_dir_all(&history).map_err(|e| e.to_string())?;
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos();
        let destination = history.join(format!("session-{timestamp}-{}.json", std::process::id()));
        let mut archive = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
            .map_err(|e| format!("Não foi possível arquivar a sessão: {e}"))?;
        if let Err(error) = archive.write_all(&bytes).and_then(|_| archive.sync_all()) {
            drop(archive);
            let _ = fs::remove_file(&destination);
            return Err(format!("Não foi possível arquivar a sessão: {error}"));
        }
        drop(archive);
        fs::remove_file(&self.session_file).map_err(|e| {
            format!("O arquivo foi preservado, mas o registro ativo não pôde ser liberado: {e}")
        })?;
        Ok(destination)
    }
}

impl SessionStore for FileStore {
    fn load_session(&mut self) -> Result<Option<SessionJournal>, String> {
        let file = match File::open(&self.session_file) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("Não foi possível abrir a sessão: {e}")),
        };
        let mut bytes = Vec::new();
        file.take(65_537)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 65_536 {
            return Err("Registro de sessão excede o tamanho permitido.".into());
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("Registro de sessão inválido: {e}"))
    }
    fn save_session(&mut self, journal: &SessionJournal) -> Result<(), String> {
        let bytes = serde_json::to_vec(journal).map_err(|e| e.to_string())?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.session_file)
            .map_err(|e| format!("Não foi possível criar o registro da sessão: {e}"))?;
        if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
            drop(file);
            let _ = fs::remove_file(&self.session_file);
            return Err(format!(
                "Não foi possível salvar o registro da sessão: {error}"
            ));
        }
        Ok(())
    }
    fn clear_session(&mut self) -> Result<(), String> {
        match fs::remove_file(&self.session_file) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("Não foi possível finalizar a sessão: {e}")),
        }
    }
}

impl Store for FileStore {
    fn load(&mut self) -> Result<Option<Journal>, String> {
        let file = match File::open(&self.file) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("Não foi possível abrir o backup: {e}")),
        };
        if file.metadata().map_err(|e| e.to_string())?.len() > MAX_JOURNAL_BYTES as u64 {
            return Err("Arquivo de backup excede o tamanho permitido.".into());
        }
        let mut bytes = Vec::new();
        file.take(MAX_JOURNAL_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("Arquivo de backup excede o tamanho permitido.".into());
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("Backup inválido: {e}"))
    }
    fn save(&mut self, journal: &Journal) -> Result<(), String> {
        let bytes = serde_json::to_vec(journal).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err(
                "O backup excede o tamanho permitido; nenhuma configuração foi alterada.".into(),
            );
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.file)
            .map_err(|e| format!("Não foi possível criar o backup: {e}"))?;
        if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
            drop(file);
            // No system writes are allowed until save has returned successfully.
            let _ = fs::remove_file(&self.file);
            return Err(format!("Não foi possível salvar o backup: {error}"));
        }
        Ok(())
    }
    fn clear(&mut self) -> Result<(), String> {
        match fs::remove_file(&self.file) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("Não foi possível finalizar o backup: {e}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Priority, ProcessIdentity, SessionJournal, SessionStore};
    use crate::transaction::{Entry, Setting, Value};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn durable_journal_blocks_concurrent_writer_and_survives_restart() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("store-test-{unique}"));
        let journal = Journal {
            schema: 1,
            entries: vec![Entry {
                setting: Setting::GameMode,
                original: None,
                applied: Value::dword(1),
            }],
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert!(FileStore::acquire(directory.clone()).is_err());
            assert!(store.load().unwrap().is_none());
            store.save(&journal).unwrap();
            assert!(store.save(&journal).is_err());
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(store.load().unwrap(), Some(journal));
            store.clear().unwrap();
            assert!(store.load().unwrap().is_none());
        }
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn refuses_to_write_a_backup_it_could_not_read() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("store-large-{unique}"));
        let mut store = FileStore::acquire(directory.clone()).unwrap();
        let journal = Journal {
            schema: 1,
            entries: vec![Entry {
                setting: Setting::GameMode,
                original: Some(Value {
                    kind: 3,
                    bytes: vec![255; 1_100_000],
                }),
                applied: Value::dword(1),
            }],
        };
        assert!(store.save(&journal).is_err());
        assert!(store.load().unwrap().is_none());
        drop(store);
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn session_journal_survives_reopening() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("session-store-{unique}"));
        let value = SessionJournal {
            schema: 1,
            process: ProcessIdentity { pid: 1, created: 2 },
            original: Priority::Normal,
            applied: Priority::AboveNormal,
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            store.save_session(&value).unwrap();
            assert!(store.save_session(&value).is_err());
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(store.load_session().unwrap(), Some(value));
            store.clear_session().unwrap();
        }
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn archive_preserves_record_and_frees_active_slot() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("session-archive-{unique}"));
        let value = SessionJournal {
            schema: 1,
            process: ProcessIdentity { pid: 1, created: 2 },
            original: Priority::Normal,
            applied: Priority::AboveNormal,
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            store.save_session(&value).unwrap();
            let archived = store.archive_session().unwrap();
            let persisted: SessionJournal =
                serde_json::from_slice(&fs::read(archived).unwrap()).unwrap();
            assert_eq!(persisted, value);
            assert!(store.load_session().unwrap().is_none());
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
