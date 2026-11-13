//! Recoverable, process-scoped priority session. Platform adapters must identify
//! a process by both PID and creation time, since Windows can reuse PIDs.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub created: u64,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
pub enum Priority {
    Idle,
    BelowNormal,
    Normal,
    AboveNormal,
    High,
    Realtime,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct SessionJournal {
    pub schema: u32,
    pub process: ProcessIdentity,
    pub original: Priority,
    pub applied: Priority,
    #[serde(default)]
    pub phase: Phase,
}

#[derive(Debug, Clone, Copy, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    #[default]
    Uncertain,
    Pending,
    Armed,
    Applied,
    Reverting,
}

/// `None` means that exact process has exited or its PID was reused.
pub trait ProcessBackend {
    fn priority(&mut self, process: ProcessIdentity) -> Result<Option<Priority>, String>;
    fn set_priority(
        &mut self,
        process: ProcessIdentity,
        expected: Priority,
        priority: Priority,
    ) -> Result<(), String>;
}

pub trait SessionStore {
    fn load_session(&mut self) -> Result<Option<SessionJournal>, String>;
    fn save_session(&mut self, journal: &SessionJournal) -> Result<(), String>;
    fn update_session(&mut self, old: &SessionJournal, new: &SessionJournal) -> Result<(), String>;
    fn clear_session(&mut self) -> Result<(), String>;
}

#[derive(Debug, Eq, PartialEq)]
pub enum EndResult {
    Restored,
    AlreadyOriginal,
    ProcessExited,
    Conflict,
}

/// Store the previous value durably before changing the game process.
pub fn begin<B: ProcessBackend, S: SessionStore>(
    backend: &mut B,
    store: &mut S,
    process: ProcessIdentity,
) -> Result<SessionJournal, String> {
    if process.pid == 0 || process.created == 0 {
        return Err("Identidade do processo inválida.".into());
    }
    if store.load_session()?.is_some() {
        return Err("Existe uma sessão anterior para restaurar.".into());
    }
    let original = backend
        .priority(process)?
        .ok_or("O jogo já foi encerrado.")?;
    // Never lower a priority chosen by the game or another program.
    if matches!(
        original,
        Priority::AboveNormal | Priority::High | Priority::Realtime
    ) {
        return Err("O jogo já usa prioridade igual ou maior. Nenhuma alteração foi feita.".into());
    }
    let mut journal = SessionJournal {
        schema: 1,
        process,
        original,
        applied: Priority::AboveNormal,
        phase: Phase::Pending,
    };
    store.save_session(&journal)?;
    if backend.priority(process)? != Some(original) {
        return Err(
            "A prioridade mudou durante a análise; o registro de recuperação foi mantido.".into(),
        );
    }
    let mut armed = journal.clone();
    armed.phase = Phase::Armed;
    store.update_session(&journal, &armed)?;
    journal = armed;
    if let Err(error) = backend.set_priority(process, original, journal.applied) {
        let recovery = end(backend, store);
        return Err(format!(
            "Não foi possível ajustar a prioridade: {error}. Recuperação: {recovery:?}"
        ));
    }
    if backend.priority(process)? != Some(journal.applied) {
        let recovery = end(backend, store);
        return Err(format!(
            "Não foi possível confirmar a prioridade. Recuperação: {recovery:?}"
        ));
    }
    let mut applied = journal.clone();
    applied.phase = Phase::Applied;
    store.update_session(&journal, &applied)?;
    journal = applied;
    Ok(journal)
}

pub fn end<B: ProcessBackend, S: SessionStore>(
    backend: &mut B,
    store: &mut S,
) -> Result<EndResult, String> {
    let journal = store
        .load_session()?
        .ok_or("Não há sessão para restaurar.")?;
    if journal.schema != 1
        || journal.process.pid == 0
        || journal.process.created == 0
        || journal.applied != Priority::AboveNormal
        || matches!(
            journal.original,
            Priority::AboveNormal | Priority::High | Priority::Realtime
        )
    {
        return Err("Registro de sessão inválido.".into());
    }
    let result = match backend.priority(journal.process)? {
        None => EndResult::ProcessExited,
        Some(value) if value == journal.original => EndResult::AlreadyOriginal,
        Some(value) if journal.phase != Phase::Applied || value != journal.applied => {
            return Ok(EndResult::Conflict);
        }
        Some(_) => {
            let mut reverting = journal.clone();
            reverting.phase = Phase::Reverting;
            store.update_session(&journal, &reverting)?;
            backend.set_priority(journal.process, journal.applied, journal.original)?;
            match backend.priority(journal.process)? {
                Some(value) if value == journal.original => EndResult::Restored,
                None => EndResult::ProcessExited,
                _ => return Err("Não foi possível verificar a restauração da prioridade.".into()),
            }
        }
    };
    store.clear_session()?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Memory(Option<SessionJournal>);
    impl SessionStore for Memory {
        fn load_session(&mut self) -> Result<Option<SessionJournal>, String> {
            Ok(self.0.clone())
        }
        fn save_session(&mut self, value: &SessionJournal) -> Result<(), String> {
            self.0 = Some(value.clone());
            Ok(())
        }
        fn update_session(
            &mut self,
            old: &SessionJournal,
            new: &SessionJournal,
        ) -> Result<(), String> {
            if self.0.as_ref() != Some(old) {
                return Err("session changed".into());
            }
            self.0 = Some(new.clone());
            Ok(())
        }
        fn clear_session(&mut self) -> Result<(), String> {
            self.0 = None;
            Ok(())
        }
    }
    struct Fake {
        process: ProcessIdentity,
        value: Option<Priority>,
    }
    impl ProcessBackend for Fake {
        fn priority(&mut self, process: ProcessIdentity) -> Result<Option<Priority>, String> {
            Ok(if process == self.process {
                self.value
            } else {
                None
            })
        }
        fn set_priority(
            &mut self,
            process: ProcessIdentity,
            expected: Priority,
            value: Priority,
        ) -> Result<(), String> {
            if process != self.process || self.value.is_none() {
                return Err("process exited".into());
            }
            if self.value != Some(expected) {
                return Err("priority changed".into());
            }
            self.value = Some(value);
            Ok(())
        }
    }
    fn fixture() -> (Fake, Memory) {
        (
            Fake {
                process: ProcessIdentity {
                    pid: 42,
                    created: 5,
                },
                value: Some(Priority::Normal),
            },
            Memory::default(),
        )
    }
    #[test]
    fn restores_original_without_terminating_game() {
        let (mut b, mut s) = fixture();
        let id = b.process;
        begin(&mut b, &mut s, id).unwrap();
        assert_eq!(b.value, Some(Priority::AboveNormal));
        assert_eq!(end(&mut b, &mut s).unwrap(), EndResult::Restored);
        assert_eq!(b.value, Some(Priority::Normal));
        assert!(s.0.is_none());
    }
    #[test]
    fn preserves_external_priority_changes() {
        let (mut b, mut s) = fixture();
        let id = b.process;
        begin(&mut b, &mut s, id).unwrap();
        b.value = Some(Priority::High);
        assert_eq!(end(&mut b, &mut s).unwrap(), EndResult::Conflict);
        assert_eq!(b.value, Some(Priority::High));
        assert!(s.0.is_some());
    }
    #[test]
    fn pending_session_never_undoes_a_matching_external_change() {
        let (mut backend, mut store) = fixture();
        let record = SessionJournal {
            schema: 1,
            process: backend.process,
            original: Priority::Normal,
            applied: Priority::AboveNormal,
            phase: Phase::Pending,
        };
        store.save_session(&record).unwrap();
        backend.value = Some(Priority::AboveNormal);
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Conflict);
        assert_eq!(backend.value, Some(Priority::AboveNormal));
        assert!(store.0.is_some());
    }
    #[test]
    fn interrupted_write_with_unknown_origin_is_preserved() {
        let (mut backend, mut store) = fixture();
        let record = SessionJournal {
            schema: 1,
            process: backend.process,
            original: Priority::Normal,
            applied: Priority::AboveNormal,
            phase: Phase::Armed,
        };
        store.save_session(&record).unwrap();
        backend.value = Some(Priority::AboveNormal);
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Conflict);
        assert_eq!(backend.value, Some(Priority::AboveNormal));
        assert!(store.0.is_some());
    }
    #[test]
    fn interrupted_restoration_does_not_claim_priority_again() {
        let (mut backend, mut store) = fixture();
        let record = SessionJournal {
            schema: 1,
            process: backend.process,
            original: Priority::Normal,
            applied: Priority::AboveNormal,
            phase: Phase::Reverting,
        };
        store.save_session(&record).unwrap();
        backend.value = Some(Priority::AboveNormal);
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Conflict);
        assert_eq!(backend.value, Some(Priority::AboveNormal));
    }
    #[test]
    fn legacy_session_without_phase_does_not_override_current_priority() {
        let raw = r#"{"schema":1,"process":{"pid":42,"created":5},"original":"Normal","applied":"AboveNormal"}"#;
        let record: SessionJournal = serde_json::from_str(raw).unwrap();
        assert_eq!(record.phase, Phase::Uncertain);
        let (mut backend, _) = fixture();
        backend.value = Some(Priority::AboveNormal);
        let mut store = Memory(Some(record));
        assert_eq!(end(&mut backend, &mut store).unwrap(), EndResult::Conflict);
        assert_eq!(backend.value, Some(Priority::AboveNormal));
    }
    #[test]
    fn reused_pid_is_never_modified() {
        let (mut b, mut s) = fixture();
        let id = b.process;
        begin(&mut b, &mut s, id).unwrap();
        b.process.created += 1;
        assert_eq!(end(&mut b, &mut s).unwrap(), EndResult::ProcessExited);
        assert_eq!(b.value, Some(Priority::AboveNormal));
        assert!(s.0.is_none());
    }
}
