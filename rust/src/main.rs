#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]
mod app;
use eframe::egui;
fn main() {
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    let fallback = std::env::args_os().any(|arg| arg == "--renderer-fallback");
    let smoke = std::env::args_os().any(|arg| arg == "--smoke-test");
    let initialized = Arc::new(AtomicBool::new(false));
    let creator_initialized = initialized.clone();
    let options = eframe::NativeOptions {
        renderer: if fallback {
            eframe::Renderer::Wgpu
        } else {
            eframe::Renderer::Glow
        },
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1060.0, 720.0])
            .with_min_inner_size([760.0, 520.0]),
        ..Default::default()
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        eframe::run_native(
            "Windows FPS Optimizer",
            options,
            Box::new(move |cc| {
                let app = app::App::new(cc);
                creator_initialized.store(true, Ordering::Release);
                Ok(Box::new(app))
            }),
        )
    }));
    if !matches!(result, Ok(Ok(()))) {
        if smoke && let Some(path) = std::env::var_os("WFO_SMOKE_LOG") {
            let detail = match &result {
                Ok(Err(error)) => format!(
                    "renderer={}; initialized={}; error={error:?}\n",
                    if fallback { "wgpu" } else { "glow" },
                    initialized.load(Ordering::Acquire)
                ),
                Err(payload) => format!(
                    "renderer={}; initialized={}; panic={}\n",
                    if fallback { "wgpu" } else { "glow" },
                    initialized.load(Ordering::Acquire),
                    payload
                        .downcast_ref::<String>()
                        .map(String::as_str)
                        .or_else(|| payload.downcast_ref::<&str>().copied())
                        .unwrap_or("unknown")
                ),
                Ok(Ok(())) => String::new(),
            };
            use std::io::Write;
            if let Ok(mut file) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let _ = file.write_all(detail.as_bytes());
            }
        }
        // Winit cannot recreate an event loop in one process. Retry once in a
        // fresh process, and only before the application itself was created.
        if !fallback
            && !initialized.load(Ordering::Acquire)
            && let Ok(exe) = std::env::current_exe()
        {
            let mut command = std::process::Command::new(exe);
            command.arg("--renderer-fallback");
            if smoke {
                command.arg("--smoke-test");
            }
            if let Ok(mut child) = command.spawn() {
                if smoke {
                    std::process::exit(child.wait().ok().and_then(|s| s.code()).unwrap_or(1));
                }
                return;
            }
        }
        if !smoke {
            show_startup_error();
        }
        std::process::exit(1);
    }
}

#[cfg(windows)]
fn show_startup_error() {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};
    let title: Vec<u16> = "Windows FPS Optimizer"
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let message: Vec<u16> = "A interface gráfica não pôde ser iniciada ou foi interrompida. Confira o driver de vídeo e tente novamente em uma sessão local. Se uma operação foi interrompida, reabra o aplicativo para verificar os backups."
        .encode_utf16().chain(Some(0)).collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            message.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(not(windows))]
fn show_startup_error() {
    eprintln!("Não foi possível abrir a interface gráfica.");
}
