#[derive(Clone, Debug)]
pub struct Plan {
    pub bytes: u64,
    pub skipped: u64,
    pub truncated: bool,
}
impl Plan {
    pub fn files(&self) -> usize {
        0
    }
    pub fn folder(&self) -> &std::path::Path {
        std::path::Path::new("")
    }
}
#[derive(Debug)]
pub struct Report {
    pub marked: u64,
    pub bytes: u64,
    pub skipped: u64,
}
pub fn plan_user_temp() -> Result<Plan, String> {
    Err("Esta opção requer Windows.".into())
}
pub fn apply(_: &Plan) -> Result<Report, String> {
    Err("Esta opção requer Windows.".into())
}
