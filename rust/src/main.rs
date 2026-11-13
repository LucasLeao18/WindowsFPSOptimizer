#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]
mod app;
use eframe::egui;
fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1060.0, 720.0])
            .with_min_inner_size([760.0, 520.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Windows FPS Optimizer",
        options,
        Box::new(|cc| Ok(Box::new(app::App::new(cc)))),
    )
}
