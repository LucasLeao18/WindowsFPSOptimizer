#![windows_subsystem = "windows"]
// Short-lived isolated process used only by the opt-in integration test.
fn main() {
    std::thread::sleep(std::time::Duration::from_secs(4));
}
