//! Durable journal with a process-wide lock and exclusive creation.
use crate::{
    power_session::{Journal as PowerJournal, Store as PowerStore},
    session::{SessionJournal, SessionStore},
    startup::{Journal as StartupJournal, Store as StartupStore},
    transaction::{Journal, Store},
};
use fs2::FileExt;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::PathBuf,
};
const MAX_JOURNAL_BYTES: usize = 4 * 1024 * 1024;
const MAX_STARTUP_BYTES: usize = 9 * 1024 * 1024;

pub struct FileStore {
    file: PathBuf,
    session_file: PathBuf,
    power_file: PathBuf,
    startup_file: PathBuf,
    visual_session_file: PathBuf,
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
            power_file: directory.join("power-session.json"),
            startup_file: directory.join("startup.json"),
            visual_session_file: directory.join("visual-session.json"),
            _lock: lock,
        })
    }

    /// Preserve the original record before removing it from the active slot.
    /// This never changes a process or a Windows setting.
    pub fn archive_session(&mut self) -> Result<PathBuf, String> {
        archive_record(&self.session_file, "session", 65_536)
    }
    pub fn archive_power(&mut self) -> Result<PathBuf, String> {
        archive_record(&self.power_file, "power-session", 65_536)
    }
    pub fn visual_session(&mut self) -> VisualSessionStore<'_> {
        VisualSessionStore { owner: self }
    }
    pub fn activate_visual_session(&mut self, selected: &std::path::Path) -> Result<(), String> {
        if self.visual_session().load()?.is_some() {
            return Err("Já existe um backup visual de sessão ativo.".into());
        }
        let history = self
            .visual_session_file
            .parent()
            .ok_or("Pasta de backup inválida.")?
            .join("History");
        let history =
            fs::canonicalize(history).map_err(|e| format!("Histórico indisponível: {e}"))?;
        let selected =
            fs::canonicalize(selected).map_err(|e| format!("Backup indisponível: {e}"))?;
        if selected.parent() != Some(history.as_path()) {
            return Err("Selecione um arquivo diretamente do histórico deste aplicativo.".into());
        }
        let file =
            File::open(selected).map_err(|e| format!("Não foi possível abrir o backup: {e}"))?;
        let mut bytes = Vec::new();
        file.take(MAX_JOURNAL_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("O backup visual da sessão é grande demais.".into());
        }
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|e| format!("Backup visual inválido: {e}"))?;
        crate::visual_session::validate(&journal)?;
        self.visual_session().save(&journal)
    }
    pub fn archive_startup(&mut self) -> Result<PathBuf, String> {
        archive_record(&self.startup_file, "startup", MAX_STARTUP_BYTES)
    }
    /// Reopen a validated archived startup journal without changing Windows.
    pub fn activate_startup(&mut self, selected: &std::path::Path) -> Result<(), String> {
        if self.load_startup()?.is_some() {
            return Err("Já existe um backup de inicialização ativo.".into());
        }
        let history = self
            .startup_file
            .parent()
            .ok_or("Pasta de backup inválida.")?
            .join("History");
        let history =
            fs::canonicalize(history).map_err(|e| format!("Histórico indisponível: {e}"))?;
        let selected =
            fs::canonicalize(selected).map_err(|e| format!("Backup indisponível: {e}"))?;
        if selected.parent() != Some(history.as_path()) {
            return Err("Selecione um arquivo diretamente do histórico deste aplicativo.".into());
        }
        let file =
            File::open(selected).map_err(|e| format!("Não foi possível abrir o backup: {e}"))?;
        let mut bytes = Vec::new();
        file.take(MAX_STARTUP_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_STARTUP_BYTES {
            return Err("O backup de inicialização é grande demais.".into());
        }
        let journal: StartupJournal = serde_json::from_slice(&bytes)
            .map_err(|e| format!("Backup de inicialização inválido: {e}"))?;
        crate::startup::validate(&journal)?;
        self.save_startup(&journal)
    }
    /// Archive raw records even if damaged, so recovery is not blocked by parsing.
    pub fn archive_session_records(&mut self) -> Result<Vec<PathBuf>, String> {
        let mut paths = Vec::new();
        if self
            .visual_session_file
            .try_exists()
            .map_err(|e| e.to_string())?
        {
            paths.push(archive_record(
                &self.visual_session_file,
                "visual-session",
                MAX_JOURNAL_BYTES,
            )?);
        }
        if self.power_file.try_exists().map_err(|e| e.to_string())? {
            paths.push(self.archive_power()?);
        }
        if self.session_file.try_exists().map_err(|e| e.to_string())? {
            paths.push(self.archive_session()?);
        }
        if paths.is_empty() {
            return Err("Não há registros de sessão para arquivar.".into());
        }
        Ok(paths)
    }
    pub fn archive_backup(&mut self) -> Result<PathBuf, String> {
        archive_record(&self.file, "backup", MAX_JOURNAL_BYTES)
    }
    /// Reactivate only a validated backup from this installation's history.
    /// This copies the journal; it does not change Windows settings.
    pub fn activate_backup(&mut self, selected: &std::path::Path) -> Result<(), String> {
        if Store::load(self)?.is_some() {
            return Err(
                "Já existe um backup ativo. Restaure ou arquive-o antes de reativar outro.".into(),
            );
        }
        let history = self
            .file
            .parent()
            .ok_or("Pasta de backup inválida.")?
            .join("History");
        let history =
            fs::canonicalize(history).map_err(|e| format!("Histórico indisponível: {e}"))?;
        let selected =
            fs::canonicalize(selected).map_err(|e| format!("Backup indisponível: {e}"))?;
        if selected.parent() != Some(history.as_path()) {
            return Err(
                "Selecione um arquivo diretamente da pasta de histórico deste aplicativo.".into(),
            );
        }
        let file =
            File::open(selected).map_err(|e| format!("Não foi possível abrir o backup: {e}"))?;
        let mut bytes = Vec::new();
        file.take(MAX_JOURNAL_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("Backup excede o tamanho permitido.".into());
        }
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|e| format!("Backup inválido: {e}"))?;
        crate::transaction::validate(&journal)?;
        Store::save(self, &journal)
    }
}

pub struct VisualSessionStore<'a> {
    owner: &'a mut FileStore,
}
impl Store for VisualSessionStore<'_> {
    fn load(&mut self) -> Result<Option<Journal>, String> {
        let file = match File::open(&self.owner.visual_session_file) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "Não foi possível abrir o backup visual da sessão: {error}"
                ));
            }
        };
        let mut bytes = Vec::new();
        file.take(MAX_JOURNAL_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("O backup visual da sessão é grande demais.".into());
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("Backup visual da sessão inválido: {e}"))
    }
    fn save(&mut self, journal: &Journal) -> Result<(), String> {
        let bytes = serde_json::to_vec(journal).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("O backup visual da sessão é grande demais.".into());
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.owner.visual_session_file)
            .map_err(|e| format!("Não foi possível criar o backup visual da sessão: {e}"))?;
        if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
            drop(file);
            let _ = fs::remove_file(&self.owner.visual_session_file);
            return Err(format!(
                "Não foi possível salvar o backup visual da sessão: {error}"
            ));
        }
        Ok(())
    }
    fn update(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
        if self.load()?.as_ref() != Some(old) {
            return Err("O backup visual da sessão mudou durante a operação.".into());
        }
        let bytes = serde_json::to_vec(new).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("O backup visual da sessão é grande demais.".into());
        }
        replace_record(&self.owner.visual_session_file, &bytes)
    }
    fn clear(&mut self) -> Result<(), String> {
        match fs::remove_file(&self.owner.visual_session_file) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "Não foi possível finalizar o backup visual da sessão: {error}"
            )),
        }
    }
}

impl StartupStore for FileStore {
    fn load_startup(&mut self) -> Result<Option<StartupJournal>, String> {
        let file = match File::open(&self.startup_file) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "Não foi possível abrir o backup de inicialização: {error}"
                ));
            }
        };
        let mut bytes = Vec::new();
        file.take(MAX_STARTUP_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_STARTUP_BYTES {
            return Err("O backup de inicialização é grande demais.".into());
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("Backup de inicialização inválido: {e}"))
    }
    fn save_startup(&mut self, journal: &StartupJournal) -> Result<(), String> {
        let bytes = serde_json::to_vec(journal).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_STARTUP_BYTES {
            return Err("O backup de inicialização é grande demais.".into());
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.startup_file)
            .map_err(|e| format!("Não foi possível criar o backup de inicialização: {e}"))?;
        if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
            drop(file);
            let _ = fs::remove_file(&self.startup_file);
            return Err(format!(
                "Não foi possível salvar o backup de inicialização: {error}"
            ));
        }
        Ok(())
    }
    fn update_startup(&mut self, old: &StartupJournal, new: &StartupJournal) -> Result<(), String> {
        if self.load_startup()?.as_ref() != Some(old) {
            return Err("O backup de inicialização mudou durante a operação.".into());
        }
        let bytes = serde_json::to_vec(new).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_STARTUP_BYTES {
            return Err("O backup de inicialização é grande demais.".into());
        }
        replace_record(&self.startup_file, &bytes)
    }
    fn clear_startup(&mut self) -> Result<(), String> {
        match fs::remove_file(&self.startup_file) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "Não foi possível finalizar o backup de inicialização: {error}"
            )),
        }
    }
}

impl PowerStore for FileStore {
    fn load_power(&mut self) -> Result<Option<PowerJournal>, String> {
        let file = match File::open(&self.power_file) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(format!(
                    "Não foi possível abrir o registro de energia: {error}"
                ));
            }
        };
        let mut bytes = Vec::new();
        file.take(65_537)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 65_536 {
            return Err("Registro de energia excede o tamanho permitido.".into());
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("Registro de energia inválido: {e}"))
    }
    fn save_power(&mut self, journal: &PowerJournal) -> Result<(), String> {
        let bytes = serde_json::to_vec(journal).map_err(|e| e.to_string())?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.power_file)
            .map_err(|e| format!("Não foi possível criar o registro de energia: {e}"))?;
        if let Err(error) = file.write_all(&bytes).and_then(|_| file.sync_all()) {
            drop(file);
            let _ = fs::remove_file(&self.power_file);
            return Err(format!(
                "Não foi possível salvar o registro de energia: {error}"
            ));
        }
        Ok(())
    }
    fn update_power(&mut self, old: &PowerJournal, new: &PowerJournal) -> Result<(), String> {
        if self.load_power()?.as_ref() != Some(old) {
            return Err("O registro de energia mudou durante a operação.".into());
        }
        let bytes = serde_json::to_vec(new).map_err(|e| e.to_string())?;
        if bytes.len() > 65_536 {
            return Err("Registro de energia excede o tamanho permitido.".into());
        }
        replace_record(&self.power_file, &bytes)
    }
    fn clear_power(&mut self) -> Result<(), String> {
        match fs::remove_file(&self.power_file) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "Não foi possível finalizar o registro de energia: {error}"
            )),
        }
    }
}

fn archive_record(source: &std::path::Path, prefix: &str, limit: usize) -> Result<PathBuf, String> {
    let file = File::open(source).map_err(|e| format!("Não foi possível abrir o registro: {e}"))?;
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return Err("O registro é grande demais para arquivar automaticamente.".into());
    }
    let parent = source.parent().ok_or("Pasta de backup inválida.")?;
    let history = parent.join("History");
    fs::create_dir_all(&history).map_err(|e| e.to_string())?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let destination = history.join(format!("{prefix}-{timestamp}-{}.json", std::process::id()));
    let mut archive = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&destination)
        .map_err(|e| format!("Não foi possível arquivar o registro: {e}"))?;
    if let Err(error) = archive.write_all(&bytes).and_then(|_| archive.sync_all()) {
        drop(archive);
        let _ = fs::remove_file(&destination);
        return Err(format!("Não foi possível arquivar o registro: {error}"));
    }
    drop(archive);
    fs::remove_file(source).map_err(|e| {
        format!("O arquivo foi preservado, mas o registro ativo não pôde ser liberado: {e}")
    })?;
    Ok(destination)
}

fn replace_record(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let temp = path.with_file_name(format!("journal-{}-{stamp}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|e| format!("Não foi possível atualizar o registro: {e}"))?;
    if let Err(error) = file.write_all(bytes).and_then(|_| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(&temp);
        return Err(format!("Não foi possível atualizar o registro: {error}"));
    }
    drop(file);
    if let Err(error) = fs::rename(&temp, path) {
        let _ = fs::remove_file(&temp);
        return Err(format!(
            "Não foi possível concluir a atualização do registro: {error}"
        ));
    }
    Ok(())
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
    fn update_session(&mut self, old: &SessionJournal, new: &SessionJournal) -> Result<(), String> {
        if self.load_session()?.as_ref() != Some(old) {
            return Err("O registro da sessão mudou durante a operação.".into());
        }
        let bytes = serde_json::to_vec(new).map_err(|e| e.to_string())?;
        if bytes.len() > 65_536 {
            return Err("Registro da sessão excede o tamanho permitido.".into());
        }
        replace_record(&self.session_file, &bytes)
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
    fn update(&mut self, old: &Journal, new: &Journal) -> Result<(), String> {
        if self.load()?.as_ref() != Some(old) {
            return Err("O backup mudou durante a operação.".into());
        }
        let bytes = serde_json::to_vec(new).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_JOURNAL_BYTES {
            return Err("Backup excede o tamanho permitido.".into());
        }
        replace_record(&self.file, &bytes)
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
    use crate::session::{
        Phase as SessionPhase, Priority, ProcessIdentity, SessionJournal, SessionStore,
    };
    use crate::transaction::{Entry, Phase, Setting, Value};
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
                phase: Phase::Pending,
            }],
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert!(FileStore::acquire(directory.clone()).is_err());
            assert!(store.load().unwrap().is_none());
            store.save(&journal).unwrap();
            assert!(store.save(&journal).is_err());
            let mut armed = journal.clone();
            armed.entries[0].phase = Phase::Armed;
            store.update(&journal, &armed).unwrap();
            assert!(store.update(&journal, &armed).is_err());
            store.update(&armed, &journal).unwrap();
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
                phase: Phase::Pending,
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
            phase: SessionPhase::Pending,
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
    fn power_journal_survives_reopening_and_corruption_can_be_archived() {
        use crate::power_session::{
            HIGH_PERFORMANCE, Journal as PowerJournal, Phase as PowerPhase, Scheme,
        };
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("power-store-{unique}"));
        let mut record = PowerJournal {
            schema: 1,
            process: ProcessIdentity { pid: 1, created: 2 },
            original: Scheme {
                data1: 1,
                data2: 2,
                data3: 3,
                data4: [4; 8],
            },
            applied: HIGH_PERFORMANCE,
            phase: PowerPhase::Pending,
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            store.save_power(&record).unwrap();
            let mut armed = record.clone();
            armed.phase = PowerPhase::Armed;
            store.update_power(&record, &armed).unwrap();
            assert!(store.update_power(&record, &armed).is_err());
            record = armed;
        }
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert_eq!(store.load_power().unwrap(), Some(record));
            fs::write(directory.join("power-session.json"), b"broken").unwrap();
            assert!(store.load_power().is_err());
            let paths = store.archive_session_records().unwrap();
            assert_eq!(fs::read(&paths[0]).unwrap(), b"broken");
            assert!(store.load_power().unwrap().is_none());
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
            phase: SessionPhase::Pending,
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
    #[test]
    fn archive_backup_keeps_a_copy_and_frees_the_slot() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("backup-archive-{unique}"));
        let journal = Journal {
            schema: 1,
            entries: vec![Entry {
                setting: Setting::GameMode,
                original: None,
                applied: Value::dword(1),
                phase: Phase::Applied,
            }],
        };
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            store.save(&journal).unwrap();
            let path = store.archive_backup().unwrap();
            let saved: Journal = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
            assert_eq!(saved, journal);
            assert!(store.load().unwrap().is_none());
            store.activate_backup(&path).unwrap();
            assert_eq!(store.load().unwrap(), Some(journal));
            assert!(store.activate_backup(&path).is_err());
        }
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn activation_rejects_a_file_outside_history() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("backup-outside-{unique}"));
        fs::create_dir_all(directory.join("History")).unwrap();
        let outsider = directory.join("elsewhere.json");
        fs::write(&outsider, b"{}").unwrap();
        let tampered = directory.join("History").join("tampered.json");
        let journal = Journal {
            schema: 1,
            entries: vec![Entry {
                setting: Setting::GameMode,
                original: None,
                applied: Value::dword(0),
                phase: Phase::Applied,
            }],
        };
        fs::write(&tampered, serde_json::to_vec(&journal).unwrap()).unwrap();
        {
            let mut store = FileStore::acquire(directory.clone()).unwrap();
            assert!(store.activate_backup(&outsider).is_err());
            assert!(store.activate_backup(&tampered).is_err());
            assert!(store.load().unwrap().is_none());
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
