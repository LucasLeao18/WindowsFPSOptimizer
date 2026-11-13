//! Compatibility UI using ordinary Win32 controls and no GPU renderer.
//! It exposes the same core engines and asks before every operation.
use crate::app;
use std::{
    path::PathBuf,
    ptr,
    sync::{OnceLock, mpsc},
    thread,
    time::{Duration, Instant},
};
use windows_fps_optimizer::{
    Preset,
    engine::Preview,
    temp_cleanup::{self, Plan as CleanupPlan, Report as CleanupReport},
};
use windows_sys::Win32::{
    Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM},
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
const ACTIVATE_VISUAL: usize = 109;
const ANALYZE_TEMP: usize = 110;
const CLEAN_TEMP: usize = 111;
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
    let style = style
        | if class == "BUTTON" {
            BS_MULTILINE as u32
        } else {
            0
        };
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
            MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2,
        ) == IDYES
    }
}

enum Finished {
    Preview(Result<Preview, String>),
    Applied(Result<(), String>),
    Message(Result<String, String>),
    SessionCheck(Result<app::SessionCheck, String>),
    CleanupPlan(Result<CleanupPlan, String>),
    CleanupDone(Result<CleanupReport, String>),
}
fn start(work: impl FnOnce() -> Finished + Send + 'static) -> mpsc::Receiver<Finished> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(work());
    });
    rx
}

struct Flow {
    width: i32,
    x: i32,
    y: i32,
}
impl Flow {
    fn new(width: i32) -> Self {
        Self {
            width: width.max(160),
            x: 12,
            y: 42,
        }
    }
    fn place(&mut self, wanted: i32) -> [i32; 4] {
        let max_width = if self.width < 480 {
            (self.width - 32) / 2
        } else {
            self.width - 24
        };
        let width = wanted.min(max_width).max(1);
        if self.x + width > self.width - 12 {
            self.x = 12;
            self.y += 38;
        }
        let result = [self.x, self.y, width, 30];
        self.x += width + 8;
        result
    }
    fn next_y(&self) -> i32 {
        self.y + 42
    }
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
    let mut work = RECT::default();
    if unsafe { SystemParametersInfoW(SPI_GETWORKAREA, 0, (&mut work as *mut RECT).cast(), 0) } == 0
        || work.right <= work.left
        || work.bottom <= work.top
    {
        work = RECT {
            left: 0,
            top: 0,
            right: 1024,
            bottom: 768,
        };
    }
    let width = (work.right - work.left - 16).clamp(320, 780);
    let height = (work.bottom - work.top - 16).clamp(320, 610);
    let x = work.left + ((work.right - work.left - width) / 2).max(0);
    let y = work.top + ((work.bottom - work.top - height) / 2).max(0);
    let window = unsafe {
        CreateWindowExW(
            0,
            class_name.as_ptr(),
            wide("Windows FPS Optimizer — modo de compatibilidade").as_ptr(),
            WS_OVERLAPPEDWINDOW & !WS_MAXIMIZEBOX & !WS_THICKFRAME,
            x,
            y,
            width,
            height,
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
    let mut client = RECT::default();
    if unsafe { GetClientRect(window, &mut client) } == 0 {
        unsafe {
            DestroyWindow(window);
        }
        return Err("Não foi possível determinar o tamanho da janela.".into());
    }
    let setup = (|| -> Result<(HWND, HWND), String> {
        let client_width = client.right - client.left;
        let client_height = client.bottom - client.top;
        let mut flow = Flow::new(client_width);
        child(
            window,
            "STATIC",
            "Modo de compatibilidade: escolha um perfil, analise e confirme antes de aplicar.",
            0,
            [12, 10, (client_width - 24).max(1), 24],
            0,
        )?;
        let mut combo_rect = flow.place(200);
        combo_rect[3] = 200;
        let combo = child(
            window,
            "COMBOBOX",
            "",
            CBS_DROPDOWNLIST as u32 | WS_VSCROLL | WS_TABSTOP,
            combo_rect,
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
            flow.place(105),
            ANALYZE,
        )?;
        child(
            window,
            "BUTTON",
            "Aplicar / iniciar",
            WS_TABSTOP,
            flow.place(135),
            APPLY,
        )?;
        child(
            window,
            "BUTTON",
            "Restaurar backup",
            WS_TABSTOP,
            flow.place(145),
            RESTORE,
        )?;
        child(
            window,
            "BUTTON",
            "Selecionar jogo (.exe)",
            WS_TABSTOP,
            flow.place(185),
            SELECT_GAME,
        )?;
        child(
            window,
            "BUTTON",
            "Restaurar sessão",
            WS_TABSTOP,
            flow.place(160),
            END_SESSION,
        )?;
        child(
            window,
            "BUTTON",
            "Arquivar backup",
            WS_TABSTOP,
            flow.place(150),
            ARCHIVE_BACKUP,
        )?;
        child(
            window,
            "BUTTON",
            "Reativar backup arquivado",
            WS_TABSTOP,
            flow.place(200),
            ACTIVATE_BACKUP,
        )?;
        child(
            window,
            "BUTTON",
            "Arquivar sessão",
            WS_TABSTOP,
            flow.place(150),
            ARCHIVE_SESSION,
        )?;
        child(
            window,
            "BUTTON",
            "Reativar visual da sessão",
            WS_TABSTOP,
            flow.place(215),
            ACTIVATE_VISUAL,
        )?;
        child(
            window,
            "BUTTON",
            "Analisar temporários",
            WS_TABSTOP,
            flow.place(185),
            ANALYZE_TEMP,
        )?;
        child(
            window,
            "BUTTON",
            "Remover temporários analisados",
            WS_TABSTOP,
            flow.place(240),
            CLEAN_TEMP,
        )?;
        let output_top = flow.next_y();
        let output = child(
            window,
            "EDIT",
            "Este modo não depende de OpenGL ou DirectX.\r\n\r\nSeguro e Equilibrado: escolha o perfil e clique em Analisar.\r\nMáximo FPS: selecione o jogo e clique em Aplicar / iniciar.\r\nA limpeza de temporários é opcional e exige análise e confirmação. Outras ferramentas avançadas exigem a interface completa.",
            WS_BORDER
                | WS_VSCROLL
                | ES_MULTILINE as u32
                | ES_READONLY as u32
                | ES_AUTOVSCROLL as u32,
            [
                12,
                output_top,
                (client_width - 24).max(1),
                (client_height - output_top - 12).max(60),
            ],
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
    let mut cleanup_plan: Option<CleanupPlan> = None;
    let mut pending: Option<mpsc::Receiver<Finished>> = None;
    let mut ticks = 0u8;
    let mut next_session_check = Instant::now();
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
        if !smoke
            && msg.message == WM_TIMER
            && pending.is_none()
            && Instant::now() >= next_session_check
        {
            next_session_check = Instant::now() + Duration::from_secs(5);
            pending = Some(start(|| Finished::SessionCheck(app::check_session())));
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
                ANALYZE_TEMP => {
                    cleanup_plan = None;
                    set_text(output, "Analisando temporários sem remover arquivos...");
                    pending = Some(start(|| {
                        Finished::CleanupPlan(temp_cleanup::plan_user_temp())
                    }));
                }
                CLEAN_TEMP => {
                    if let Some(plan) = cleanup_plan.as_ref().filter(|plan| plan.files() > 0) {
                        let message = format!(
                            "Remover permanentemente até {} arquivo(s) analisados ({:.1} MiB) em {}? A Lixeira não será usada. Arquivos alterados ou bloqueados serão preservados.",
                            plan.files(),
                            plan.bytes as f64 / 1048576.0,
                            plan.folder().display()
                        );
                        if confirm(window, &message) {
                            let plan = cleanup_plan.take().unwrap();
                            set_text(output, "Verificando e removendo arquivos...");
                            pending = Some(start(move || {
                                Finished::CleanupDone(temp_cleanup::apply(&plan))
                            }));
                        }
                    } else {
                        set_text(output, "Analise os arquivos temporários antes de remover.");
                    }
                }
                ANALYZE => match selected(combo) {
                    Some(Preset::MaximumFps) => set_text(
                        output,
                        "Máximo FPS tenta ajustar a prioridade, reduzir efeitos visuais, usar o plano Alto Desempenho existente e impedir a suspensão. O plano pode aumentar consumo e temperatura. Selecione o jogo e confirme em Aplicar / iniciar.",
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
                                "Iniciar o jogo e tentar ajustar a prioridade, reduzir efeitos visuais, ativar o plano Alto Desempenho existente e impedir a suspensão? O plano pode aumentar consumo e temperatura. Os valores anteriores serão salvos. A tela ainda poderá apagar. Um monitor tentará restaurar a sessão quando o jogo terminar.",
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
                    set_text(output, "Restaurando sessão...");
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
                ACTIVATE_VISUAL => {
                    let mut dialog = rfd::FileDialog::new().add_filter("Backup JSON", &["json"]);
                    if let Some(path) = app::history_path() {
                        dialog = dialog.set_directory(path);
                    }
                    if let Some(path) = dialog.pick_file() {
                        set_text(output, "Reativando backup visual...");
                        pending = Some(start(move || {
                            Finished::Message(app::activate_session_visual(path))
                        }));
                    }
                }
                ARCHIVE_SESSION
                    if confirm(
                        window,
                        "Manter os efeitos visuais, o plano de energia e a prioridade atuais e arquivar os registros? Eles não serão restaurados automaticamente.",
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
                        Finished::SessionCheck(Ok(app::SessionCheck::Finished)) => set_text(
                            output,
                            "O jogo terminou; os registros da sessão foram restaurados ou finalizados.",
                        ),
                        Finished::SessionCheck(Ok(_)) => {}
                        Finished::SessionCheck(Err(error)) => set_text(
                            output,
                            &format!("Não foi possível verificar a sessão: {error}"),
                        ),
                        Finished::CleanupPlan(Ok(plan)) => {
                            set_text(
                                output,
                                &format!(
                                    "Análise: {} arquivo(s), {:.1} MiB, na pasta {}. {} item(ns) ignorados. {}\r\nNenhum arquivo foi removido.",
                                    plan.files(),
                                    plan.bytes as f64 / 1048576.0,
                                    plan.folder().display(),
                                    plan.skipped,
                                    if plan.truncated {
                                        "A análise atingiu o limite e é parcial."
                                    } else {
                                        ""
                                    }
                                ),
                            );
                            cleanup_plan = Some(plan);
                        }
                        Finished::CleanupDone(Ok(report)) => set_text(
                            output,
                            &format!(
                                "{} arquivo(s) marcados para exclusão ({:.1} MiB); {} item(ns) preservados por mudança ou acesso indisponível.",
                                report.marked,
                                report.bytes as f64 / 1048576.0,
                                report.skipped
                            ),
                        ),
                        Finished::Preview(Err(error))
                        | Finished::Applied(Err(error))
                        | Finished::CleanupPlan(Err(error))
                        | Finished::CleanupDone(Err(error))
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

#[cfg(test)]
mod layout_tests {
    use super::Flow;
    #[test]
    fn controls_wrap_inside_narrow_and_wide_windows() {
        for width in [320, 480, 640, 760] {
            let mut flow = Flow::new(width);
            for wanted in [200, 105, 135, 145, 185, 160, 150, 200, 150, 215, 185, 240] {
                let [x, y, w, h] = flow.place(wanted);
                assert!(x >= 12 && x + w <= width - 12 && y >= 42 && h == 30);
            }
            assert!(flow.next_y() < 300);
        }
    }
}
