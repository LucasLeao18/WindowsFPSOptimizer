//! Compatibility UI using ordinary Win32 controls and no GPU renderer.
//! It exposes the same core engines and asks before every operation.
use crate::app;
use std::{
    path::PathBuf,
    ptr,
    sync::{OnceLock, mpsc},
    thread,
};
use windows_fps_optimizer::{Preset, engine::Preview};
use windows_sys::Win32::{
    Foundation::{HWND, LPARAM, LRESULT, WPARAM},
    Graphics::Gdi::{COLOR_WINDOW, DEFAULT_GUI_FONT, GetStockObject, UpdateWindow},
    System::LibraryLoader::GetModuleHandleW,
    UI::WindowsAndMessaging::*,
};

const COMBO: usize = 100;
const ANALYZE: usize = 101;
const APPLY: usize = 102;
const RESTORE: usize = 103;
const SELECT_GAME: usize = 104;
const END_SESSION: usize = 105;
const ARCHIVE_BACKUP: usize = 106;
const ACTIVATE_BACKUP: usize = 107;
const ARCHIVE_SESSION: usize = 108;
static EVENTS: OnceLock<mpsc::Sender<(u16, u16)>> = OnceLock::new();

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_COMMAND => {
            if let Some(events) = EVENTS.get() {
                let _ = events.send(((wparam & 0xffff) as u16, ((wparam >> 16) & 0xffff) as u16));
            }
            0
        }
        WM_DESTROY => {
            unsafe {
                PostQuitMessage(0);
            }
            0
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn child(
    parent: HWND,
    class: &str,
    text: &str,
    style: u32,
    rect: [i32; 4],
    id: usize,
) -> Result<HWND, String> {
    let hwnd = unsafe {
        CreateWindowExW(
            0,
            wide(class).as_ptr(),
            wide(text).as_ptr(),
            WS_CHILD | WS_VISIBLE | style,
            rect[0],
            rect[1],
            rect[2],
            rect[3],
            parent,
            id as _,
            GetModuleHandleW(ptr::null()),
            ptr::null(),
        )
    };
    if hwnd.is_null() {
        return Err(format!(
            "Não foi possível criar o controle: {}",
            std::io::Error::last_os_error()
        ));
    }
    let font = unsafe { GetStockObject(DEFAULT_GUI_FONT) };
    unsafe {
        SendMessageW(hwnd, WM_SETFONT, font as usize, 1);
    }
    Ok(hwnd)
}

fn selected(combo: HWND) -> Option<Preset> {
    match unsafe { SendMessageW(combo, CB_GETCURSEL, 0, 0) } {
        0 => Some(Preset::Safe),
        1 => Some(Preset::Balanced),
        2 => Some(Preset::MaximumFps),
        _ => None,
    }
}

fn set_text(control: HWND, text: &str) {
    unsafe {
        SetWindowTextW(control, wide(text).as_ptr());
    }
}
fn confirm(owner: HWND, question: &str) -> bool {
    unsafe {
        MessageBoxW(
            owner,
            wide(question).as_ptr(),
            wide("Confirmar").as_ptr(),
            MB_YESNO | MB_ICONQUESTION,
        ) == IDYES
    }
}

enum Finished {
    Preview(Result<Preview, String>),
    Applied(Result<(), String>),
    Message(Result<String, String>),
}
fn start(work: impl FnOnce() -> Finished + Send + 'static) -> mpsc::Receiver<Finished> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(work());
    });
    rx
}

pub fn run(smoke: bool) -> Result<(), String> {
    let (events, event_rx) = mpsc::channel();
    EVENTS
        .set(events)
        .map_err(|_| "A interface nativa já foi inicializada.")?;
    let instance = unsafe { GetModuleHandleW(ptr::null()) };
    if instance.is_null() {
        return Err("Não foi possível iniciar a interface nativa.".into());
    }
    let class_name = wide("WindowsFPSOptimizerNativeFallback");
    let class = WNDCLASSW {
        lpfnWndProc: Some(window_proc),
        hInstance: instance,
        hCursor: unsafe { LoadCursorW(ptr::null_mut(), IDC_ARROW) },
        hbrBackground: (COLOR_WINDOW as usize + 1) as _,
        lpszClassName: class_name.as_ptr(),
        ..Default::default()
    };
    if unsafe { RegisterClassW(&class) } == 0 {
        return Err(format!(
            "Não foi possível registrar a janela: {}",
            std::io::Error::last_os_error()
        ));
    }
    let window = unsafe {
        CreateWindowExW(
            0,
            class_name.as_ptr(),
            wide("Windows FPS Optimizer — modo de compatibilidade").as_ptr(),
            WS_OVERLAPPEDWINDOW & !WS_MAXIMIZEBOX & !WS_THICKFRAME,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            900,
            680,
            ptr::null_mut(),
            ptr::null_mut(),
            instance,
            ptr::null(),
        )
    };
    if window.is_null() {
        return Err(format!(
            "Não foi possível criar a janela: {}",
            std::io::Error::last_os_error()
        ));
    }
    let setup = (|| -> Result<(HWND, HWND), String> {
        child(
            window,
            "STATIC",
            "Modo de compatibilidade: escolha um perfil, analise e confirme antes de aplicar.",
            0,
            [20, 18, 840, 24],
            0,
        )?;
        let combo = child(
            window,
            "COMBOBOX",
            "",
            CBS_DROPDOWNLIST as u32 | WS_VSCROLL | WS_TABSTOP,
            [20, 52, 230, 200],
            COMBO,
        )?;
        for label in ["Seguro", "Equilibrado", "Máximo FPS"] {
            unsafe {
                SendMessageW(combo, CB_ADDSTRING, 0, wide(label).as_ptr() as isize);
            }
        }
        unsafe {
            SendMessageW(combo, CB_SETCURSEL, 0, 0);
        }
        child(
            window,
            "BUTTON",
            "Analisar",
            WS_TABSTOP,
            [265, 50, 130, 30],
            ANALYZE,
        )?;
        child(
            window,
            "BUTTON",
            "Aplicar / iniciar",
            WS_TABSTOP,
            [405, 50, 145, 30],
            APPLY,
        )?;
        child(
            window,
            "BUTTON",
            "Restaurar backup",
            WS_TABSTOP,
            [560, 50, 150, 30],
            RESTORE,
        )?;
        child(
            window,
            "BUTTON",
            "Selecionar jogo (.exe)",
            WS_TABSTOP,
            [20, 92, 190, 30],
            SELECT_GAME,
        )?;
        child(
            window,
            "BUTTON",
            "Restaurar prioridade do jogo",
            WS_TABSTOP,
            [220, 92, 230, 30],
            END_SESSION,
        )?;
        child(
            window,
            "BUTTON",
            "Arquivar backup",
            WS_TABSTOP,
            [20, 132, 170, 30],
            ARCHIVE_BACKUP,
        )?;
        child(
            window,
            "BUTTON",
            "Reativar backup arquivado",
            WS_TABSTOP,
            [200, 132, 210, 30],
            ACTIVATE_BACKUP,
        )?;
        child(
            window,
            "BUTTON",
            "Arquivar sessão",
            WS_TABSTOP,
            [420, 132, 160, 30],
            ARCHIVE_SESSION,
        )?;
        let output = child(
            window,
            "EDIT",
            "Este modo não depende de OpenGL ou DirectX.\r\n\r\nSeguro e Equilibrado: escolha o perfil e clique em Analisar.\r\nMáximo FPS: selecione o jogo e clique em Aplicar / iniciar.\r\nAs ferramentas avançadas exigem a interface gráfica completa.",
            WS_BORDER
                | WS_VSCROLL
                | ES_MULTILINE as u32
                | ES_READONLY as u32
                | ES_AUTOVSCROLL as u32,
            [20, 180, 840, 410],
            0,
        )?;
        Ok((combo, output))
    })();
    let (combo, output) = match setup {
        Ok(value) => value,
        Err(error) => {
            unsafe {
                DestroyWindow(window);
            }
            return Err(error);
        }
    };
    if unsafe { SetTimer(window, 1, 200, None) } == 0 {
        unsafe {
            DestroyWindow(window);
        }
        return Err("Não foi possível iniciar o monitor da interface.".into());
    }
    if !smoke {
        unsafe {
            ShowWindow(window, SW_SHOWNORMAL);
            UpdateWindow(window);
        }
    }
    let mut game: Option<PathBuf> = None;
    let mut preview: Option<Preview> = None;
    let mut pending: Option<mpsc::Receiver<Finished>> = None;
    let mut ticks = 0u8;
    let mut msg = MSG::default();
    loop {
        let received = unsafe { GetMessageW(&mut msg, ptr::null_mut(), 0, 0) };
        if received == -1 {
            return Err(format!(
                "A interface foi interrompida: {}",
                std::io::Error::last_os_error()
            ));
        }
        if received == 0 {
            break;
        }
        unsafe {
            if IsDialogMessageW(window, &msg) == 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        if smoke && msg.message == WM_TIMER {
            ticks = ticks.saturating_add(1);
            if ticks >= 3 {
                unsafe {
                    PostMessageW(window, WM_CLOSE, 0, 0);
                }
            }
        }
        while let Ok((id, notification)) = event_rx.try_recv() {
            if id as usize == COMBO && notification as u32 == CBN_SELCHANGE {
                preview = None;
                set_text(
                    output,
                    "Perfil alterado. Analise novamente antes de aplicar.",
                );
                continue;
            }
            if pending.is_some() {
                continue;
            }
            match id as usize {
                SELECT_GAME => {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("Executável", &["exe"])
                        .pick_file()
                    {
                        set_text(
                            output,
                            &format!(
                                "Jogo selecionado: {}\r\nEscolha Máximo FPS e clique em Aplicar / iniciar.",
                                path.display()
                            ),
                        );
                        game = Some(path);
                    }
                }
                ANALYZE => match selected(combo) {
                    Some(Preset::MaximumFps) => set_text(
                        output,
                        "Máximo FPS inicia o jogo selecionado e tenta ajustar somente a prioridade desse processo. Selecione o executável e confirme em Aplicar / iniciar.",
                    ),
                    Some(preset) => {
                        preview = None;
                        set_text(output, "Analisando compatibilidade...");
                        pending = Some(start(move || {
                            Finished::Preview(app::preview_system(preset))
                        }));
                    }
                    None => set_text(output, "Selecione um perfil."),
                },
                APPLY => match selected(combo) {
                    Some(Preset::MaximumFps) => {
                        if let Some(path) = game.clone() {
                            if confirm(
                                window,
                                "Iniciar o jogo selecionado e tentar ajustar sua prioridade? O valor anterior será salvo.",
                            ) {
                                set_text(output, "Iniciando o jogo...");
                                pending = Some(start(move || {
                                    Finished::Message(app::start_session(path))
                                }));
                            }
                        } else {
                            set_text(output, "Selecione primeiro o executável do jogo.");
                        }
                    }
                    Some(preset) => {
                        if let Some(plan) = preview
                            .clone()
                            .filter(|p| p.preset == preset && !p.journal.entries.is_empty())
                        {
                            if confirm(
                                window,
                                "Aplicar as alterações listadas e salvar os valores anteriores?",
                            ) {
                                set_text(output, "Salvando backup e aplicando...");
                                pending =
                                    Some(start(move || Finished::Applied(app::apply_system(plan))));
                            }
                        } else {
                            set_text(output, "Analise o perfil selecionado antes de aplicar.");
                        }
                    }
                    None => set_text(output, "Selecione um perfil."),
                },
                RESTORE => {
                    set_text(output, "Restaurando backup...");
                    pending = Some(start(|| Finished::Message(app::restore_system())));
                }
                END_SESSION => {
                    set_text(output, "Restaurando prioridade...");
                    pending = Some(start(|| Finished::Message(app::stop_session())));
                }
                ARCHIVE_BACKUP => {
                    if confirm(
                        window,
                        "Manter as configurações atuais e arquivar o backup? Para restaurar depois, reative o arquivo arquivado.",
                    ) {
                        set_text(output, "Arquivando backup...");
                        pending = Some(start(|| Finished::Message(app::archive_backup())));
                    }
                }
                ACTIVATE_BACKUP => {
                    let mut dialog = rfd::FileDialog::new().add_filter("Backup JSON", &["json"]);
                    if let Some(path) = app::history_path() {
                        dialog = dialog.set_directory(path);
                    }
                    if let Some(path) = dialog.pick_file() {
                        set_text(output, "Reativando backup...");
                        pending =
                            Some(start(move || Finished::Message(app::activate_backup(path))));
                    }
                }
                ARCHIVE_SESSION
                    if confirm(
                        window,
                        "Manter a prioridade atual e arquivar o registro da sessão? Ela não será restaurada automaticamente.",
                    ) =>
                {
                    set_text(output, "Arquivando sessão...");
                    pending = Some(start(|| Finished::Message(app::archive_session())));
                }
                _ => {}
            }
        }
        if let Some(receiver) = &pending {
            match receiver.try_recv() {
                Ok(result) => {
                    pending = None;
                    match result {
                        Finished::Preview(Ok(plan)) if selected(combo) == Some(plan.preset) => {
                            let mut lines = vec![format!(
                                "Análise: {} alteração(ões).",
                                plan.journal.entries.len()
                            )];
                            for entry in &plan.journal.entries {
                                lines.push(format!(
                                    "• {}: {} para {}",
                                    app::setting_name(entry.setting),
                                    app::display_value(entry.original.as_ref()),
                                    app::display_value(Some(&entry.applied))
                                ));
                            }
                            lines.extend(plan.notes.iter().cloned());
                            if plan.journal.entries.is_empty() {
                                lines.push("Não há alterações automáticas disponíveis.".into());
                            }
                            set_text(output, &lines.join("\r\n"));
                            preview = Some(plan);
                        }
                        Finished::Preview(Ok(_)) => set_text(
                            output,
                            "O perfil mudou durante a análise. Analise novamente.",
                        ),
                        Finished::Applied(Ok(())) => {
                            preview = None;
                            set_text(
                                output,
                                "Operação concluída. O backup está disponível para restauração.",
                            );
                        }
                        Finished::Message(Ok(message)) => {
                            preview = None;
                            set_text(output, &message);
                        }
                        Finished::Preview(Err(error))
                        | Finished::Applied(Err(error))
                        | Finished::Message(Err(error)) => set_text(output, &error),
                    }
                }
                Err(mpsc::TryRecvError::Empty) => {}
                Err(mpsc::TryRecvError::Disconnected) => {
                    pending = None;
                    set_text(
                        output,
                        "A operação foi interrompida. Verifique o backup antes de tentar novamente.",
                    );
                }
            }
        }
    }
    Ok(())
}
