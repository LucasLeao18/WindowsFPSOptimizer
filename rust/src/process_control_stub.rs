use crate::session::ProcessIdentity;
use std::path::PathBuf;
#[derive(Debug, Clone)]
pub struct Candidate {
    pub identity: ProcessIdentity,
    pub path: PathBuf,
}
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum Termination {
    Exited,
    Requested,
}
pub fn inspect(_: ProcessIdentity) -> Result<Candidate, String> {
    Err("Esta opção requer Windows.".into())
}
pub fn terminate(_: &Candidate) -> Result<Termination, String> {
    Err("Esta opção requer Windows.".into())
}
pub fn current_process_elevated() -> bool {
    false
}
