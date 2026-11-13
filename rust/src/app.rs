use eframe::egui::{self, Color32, RichText};
use std::{
    path::PathBuf,
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};
#[cfg(windows)]
use windows_fps_optimizer::windows_registry::WindowsRegistry;
use windows_fps_optimizer::{
    Preset,
    benchmark::{self, Capture},
    compatibility,
    diagnostics::{self, PowerSource, Snapshot},
    engine::{self, Preview},
    process_inventory::{self, Inventory},
    storage::FileStore,
    temp_scan::{self, Estimate},
    transaction::Setting,
};

enum JobResult {
    Preview(Result<Preview, String>),
    Applied(Result<(), String>),
    Restored(Result<String, String>),
    Capture(bool, Result<Capture, String>),
    SessionStarted(Result<String, String>),
    SessionStopped(Result<String, String>),
    SessionChecked(Result<SessionCheck, String>),
    Diagnostics(Snapshot),
    TempEstimate(Result<Estimate, String>),
    ProcessInventory(Result<Inventory, String>),
}

enum SessionCheck {
    None,
    Running,
    Finished,
}

#[derive(serde::Deserialize, serde::Serialize)]
struct Preferences {
    schema: u8,
    onboarded: bool,
    advanced: bool,
    #[serde(default)]
    last_game: Option<PathBuf>,
}

pub struct App {
    preset: Preset,
    preferences: Preferences,
    onboarding_step: u8,
    preview: Option<Preview>,
    confirm: bool,
    confirm_session: bool,
    confirm_archive_session: bool,
    confirm_archive_backup: bool,
    game_path: Option<PathBuf>,
    session_notice: String,
    next_session_check: Instant,
    status: String,
    status_error: bool,
    receiver: Option<Receiver<JobResult>>,
    before: Option<Capture>,
    after: Option<Capture>,
    diagnostics: Option<Snapshot>,
    temp_estimate: Option<Estimate>,
    processes: Option<Inventory>,
    smoke_frames: Option<u8>,
}

impl App {
    fn set_status(&mut self, result: Result<(), String>, success: &str) {
        match result {
            Ok(()) => {
                self.status_error = false;
                self.status = success.into();
            }
            Err(error) => {
                self.status_error = true;
                self.status = error;
            }
        }
    }
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        cc.egui_ctx.set_theme(egui::Theme::Dark);
        let mut visuals = egui::Visuals::dark();
        visuals.panel_fill = Color32::from_rgb(15, 19, 29);
        visuals.window_fill = Color32::from_rgb(24, 29, 42);
        visuals.selection.bg_fill = Color32::from_rgb(47, 100, 196);
        cc.egui_ctx.set_visuals(visuals);
        cc.egui_ctx.style_mut_of(egui::Theme::Dark, |style| {
            style.spacing.item_spacing = egui::vec2(12.0, 10.0);
            style.spacing.button_padding = egui::vec2(14.0, 8.0);
            style
                .text_styles
                .insert(egui::TextStyle::Body, egui::FontId::proportional(16.0));
            style
                .text_styles
                .insert(egui::TextStyle::Button, egui::FontId::proportional(15.0));
            style
                .text_styles
                .insert(egui::TextStyle::Heading, egui::FontId::proportional(24.0));
        });
        let preferences = load_preferences();
        let game_path = preferences.last_game.clone();
        Self {
            preset: Preset::Safe,
            preferences,
            onboarding_step: 0,
            preview: None,
            confirm: false,
            confirm_session: false,
            confirm_archive_session: false,
            confirm_archive_backup: false,
            game_path,
            session_notice: String::new(),
            next_session_check: Instant::now(),
            status: "Selecione um perfil e faça uma análise antes de aplicar.".into(),
            status_error: false,
            receiver: None,
            before: None,
            after: None,
            diagnostics: None,
            temp_estimate: None,
            processes: None,
            smoke_frames: std::env::args_os()
                .any(|arg| arg == "--smoke-test")
                .then_some(0),
        }
    }
    fn run(&mut self, ctx: &egui::Context, action: impl FnOnce() -> JobResult + Send + 'static) {
        if self.receiver.is_some() {
            return;
        }
        self.status_error = false;
        let (tx, rx) = mpsc::channel();
        self.receiver = Some(rx);
        let ctx = ctx.clone();
        thread::spawn(move || {
            let result = action();
            let _ = tx.send(result);
            ctx.request_repaint();
        });
    }
    fn poll(&mut self) {
        let Some(receiver) = &self.receiver else {
            return;
        };
        match receiver.try_recv() {
            Ok(result) => {
                self.receiver = None;
                if !matches!(&result, JobResult::SessionChecked(_)) {
                    self.status_error = matches!(
                        &result,
                        JobResult::Preview(Err(_))
                            | JobResult::Applied(Err(_))
                            | JobResult::Restored(Err(_))
                            | JobResult::Capture(_, Err(_))
                            | JobResult::SessionStarted(Err(_))
                            | JobResult::SessionStopped(Err(_))
                            | JobResult::TempEstimate(Err(_))
                            | JobResult::ProcessInventory(Err(_))
                    );
                }
                match result {
                    JobResult::Preview(Ok(preview)) => {
                        if preview.preset == self.preset {
                            self.status = format!(
                                "Análise concluída: {} alteração(ões) disponível(is).",
                                preview.journal.entries.len()
                            );
                            self.preview = Some(preview);
                        } else {
                            self.preview = None;
                            self.status = "O perfil foi alterado. Faça uma nova análise.".into();
                        }
                    }
                    JobResult::Applied(Ok(())) => {
                        self.preview = None;
                        self.status =
                            "Operação concluída. O backup fica disponível para restauração.".into();
                    }
                    JobResult::Restored(Ok(message)) => {
                        self.preview = None;
                        self.status = message;
                    }
                    JobResult::SessionStarted(Ok(message))
                    | JobResult::SessionStopped(Ok(message)) => self.status = message,
                    JobResult::SessionChecked(Ok(state)) => {
                        self.session_notice = match state {
                            SessionCheck::None => String::new(),
                            SessionCheck::Running => {
                                "Há uma sessão de jogo em andamento ou aguardando restauração."
                                    .into()
                            }
                            SessionCheck::Finished => {
                                self.status =
                                    "O jogo encerrou e o registro da sessão foi finalizado.".into();
                                String::new()
                            }
                        };
                    }
                    JobResult::Diagnostics(snapshot) => {
                        self.diagnostics = Some(snapshot);
                        self.status = "Diagnóstico atualizado.".into();
                    }
                    JobResult::TempEstimate(Ok(estimate)) => {
                        self.temp_estimate = Some(estimate);
                        self.status = "Estimativa concluída; nenhum arquivo foi removido.".into();
                    }
                    JobResult::ProcessInventory(Ok(inventory)) => {
                        self.processes = Some(inventory);
                        self.status = "Lista de processos atualizada.".into();
                    }
                    JobResult::Capture(before, Ok(capture)) => {
                        if before {
                            self.before = Some(capture);
                        } else {
                            self.after = Some(capture);
                        }
                        self.status = "Captura carregada.".into();
                    }
                    JobResult::Preview(Err(error))
                    | JobResult::Applied(Err(error))
                    | JobResult::Restored(Err(error))
                    | JobResult::SessionStarted(Err(error))
                    | JobResult::SessionStopped(Err(error))
                    | JobResult::TempEstimate(Err(error))
                    | JobResult::ProcessInventory(Err(error))
                    | JobResult::Capture(_, Err(error)) => self.status = error,
                    JobResult::SessionChecked(Err(error)) => {
                        self.session_notice =
                            format!("Não foi possível verificar a sessão: {error}")
                    }
                }
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => {
                self.receiver = None;
                self.status_error = true;
                self.status =
                    "A operação foi interrompida. Verifique o backup antes de tentar novamente."
                        .into();
            }
        }
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.poll();
        let ctx = ui.ctx().clone();
        if let Some(frames) = &mut self.smoke_frames {
            *frames = frames.saturating_add(1);
            if *frames >= 3 {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            } else {
                ctx.request_repaint_after(Duration::from_millis(100));
            }
        }
        if self.receiver.is_none() && Instant::now() >= self.next_session_check {
            self.next_session_check = Instant::now() + Duration::from_secs(5);
            let was_error = self.status_error;
            self.run(&ctx, || JobResult::SessionChecked(check_session()));
            self.status_error = was_error;
        }
        ctx.request_repaint_after(Duration::from_secs(5));
        egui::CentralPanel::default().frame(egui::Frame::new().fill(Color32::from_rgb(15, 19, 29)).inner_margin(egui::Margin::symmetric(30, 20))).show(ui, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.set_max_width(1000.0);
                ui.add_space(20.0);
                ui.horizontal(|ui| {
                    ui.heading("Windows FPS Optimizer");
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.button("Primeiros passos").clicked() { self.onboarding_step = 0; self.preferences.onboarded = false; }
                        let label = if self.preferences.advanced { "Interface simplificada" } else { "Interface avançada" };
                        if ui.button(label).clicked() { self.preferences.advanced = !self.preferences.advanced; self.set_status(save_preferences(&self.preferences), "Preferência de interface salva."); }
                    });
                });
                ui.add_space(20.0);
                if !self.preferences.onboarded {
                    ui.label(format!("{} DE 3 • PRIMEIROS PASSOS", self.onboarding_step + 1));
                    ui.add_space(12.0);
                    let (title, body) = match self.onboarding_step {
                        0 => ("Bem-vindo", "O aplicativo ajuda a revisar opções de jogos sem prometer ganhos de FPS."),
                        1 => ("Você controla as alterações", "Analise antes de aplicar. O backup guarda os valores anteriores e a restauração preserva alterações posteriores em conflito."),
                        _ => ("Escolha sua interface", "A interface simplificada mostra os perfis. A avançada também apresenta a comparação de capturas."),
                    };
                    ui.heading(title); ui.add_space(8.0); ui.label(body); ui.add_space(14.0);
                    if self.onboarding_step == 2 { ui.checkbox(&mut self.preferences.advanced, "Começar na interface avançada"); }
                    ui.horizontal(|ui| {
                        if self.onboarding_step > 0 && ui.button("Voltar").clicked() { self.onboarding_step -= 1; }
                        if ui.button("Pular").clicked() { self.preferences.onboarded = true; self.set_status(save_preferences(&self.preferences), "Selecione um perfil e faça uma análise antes de aplicar."); }
                        if ui.button(if self.onboarding_step == 2 { "Começar" } else { "Continuar" }).clicked() {
                            if self.onboarding_step < 2 { self.onboarding_step += 1; } else { self.preferences.onboarded = true; self.set_status(save_preferences(&self.preferences), "Selecione um perfil e faça uma análise antes de aplicar."); }
                        }
                    });
                    return;
                }
                ui.heading("Seu Windows, suas escolhas");
                ui.label("Escolha um dos três perfis. O aplicativo mostra o que é compatível com este computador.");
                ui.add_space(12.0);
                ui.horizontal_wrapped(|ui| {
                    for preset in [Preset::Safe, Preset::Balanced, Preset::MaximumFps] {
                        if ui.selectable_value(&mut self.preset, preset, preset.name()).changed() {
                            self.preview = None; self.confirm = false; self.confirm_session = false; self.confirm_archive_session = false; self.confirm_archive_backup = false;
                            self.status_error = false;
                            self.status = if preset == Preset::MaximumFps { "Selecione o executável do jogo para iniciar a sessão." } else { "Perfil selecionado. Faça uma nova análise antes de aplicar." }.into();
                        }
                    }
                });
                ui.add_space(12.0);
                ui.label(match self.preset {
                    Preset::Safe => "Modo de Jogo quando suportado e transparência. Capturas são revisadas manualmente.",
                    Preset::Balanced => "Inclui os ajustes do perfil Seguro quando a memória virtual já é gerenciada pelo Windows. Se estiver manual, revise-a nas opções avançadas do sistema.",
                    Preset::MaximumFps => "Inicia o executável selecionado e tenta elevar sua prioridade para Acima do normal. A prioridade pode ser restaurada sem fechar o jogo; o resultado varia conforme o jogo e o computador.",
                });
                if self.preset == Preset::Balanced {
                    ui.label("Se necessário: Sistema > Sobre > Configurações avançadas do sistema > Desempenho > Avançado > Memória virtual > Alterar, e escolha o gerenciamento automático. A mudança pode exigir administrador e reinicialização.");
                    if ui.button("Abrir informações do sistema").clicked() {
                        self.set_status(open_windows_settings(SettingsPage::About), "Configurações abertas. A localização dos controles pode variar.");
                    }
                }
                ui.add_space(12.0);
                if self.preset == Preset::MaximumFps {
                    ui.horizontal_wrapped(|ui| {
                        if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Selecionar jogo (.exe)")).clicked()
                            && let Some(path) = rfd::FileDialog::new().add_filter("Executável", &["exe"]).pick_file() {
                            self.game_path = Some(path.clone()); self.preferences.last_game = Some(path);
                            self.set_status(save_preferences(&self.preferences), "Jogo selecionado.");
                        }
                        if ui.add_enabled(self.receiver.is_none() && self.game_path.is_some(), egui::Button::new("Iniciar jogo e sessão")).clicked() { self.confirm_session = true; }
                        if ui.add_enabled(self.receiver.is_none() && self.game_path.is_some(), egui::Button::new("Esquecer jogo salvo")).clicked() {
                            self.game_path = None; self.preferences.last_game = None;
                            self.set_status(save_preferences(&self.preferences), "Jogo removido das preferências.");
                        }
                        if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Restaurar prioridade da sessão")).clicked() {
                            self.status = "Verificando a sessão...".into(); self.run(&ctx, || JobResult::SessionStopped(stop_session()));
                        }
                        if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Arquivar registro sem restaurar")).clicked() { self.confirm_archive_session = true; }
                    });
                    if let Some(path) = &self.game_path { ui.label(format!("Executável: {}", path.display())); }
                    ui.label("Se o executável abrir um launcher e terminar, selecione o executável do jogo. Recuperação também fica disponível após fechar o aplicativo.");
                }
                ui.horizontal_wrapped(|ui| {
                    if ui.add_enabled(self.receiver.is_none() && self.preset != Preset::MaximumFps, egui::Button::new("Analisar sem alterar")).clicked() {
                        self.preview = None; self.status = "Analisando compatibilidade e backup...".into();
                        let preset = self.preset; self.run(&ctx, move || JobResult::Preview(preview_system(preset)));
                    }
                    if ui.add_enabled(self.receiver.is_none() && self.preview.as_ref().is_some_and(|p| !p.journal.entries.is_empty()), egui::Button::new("Aplicar perfil")).clicked() { self.confirm = true; }
                    if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Restaurar último backup")).clicked() {
                        self.status = "Restaurando configurações...".into(); self.run(&ctx, || JobResult::Restored(restore_system()));
                    }
                });
                ui.add_space(10.0);
                if let Some(preview) = &self.preview {
                    ui.label(RichText::new("O que será alterado").strong());
                    if preview.journal.entries.is_empty() { ui.label("As opções automáticas já estão no estado solicitado."); }
                    for entry in &preview.journal.entries {
                        ui.label(format!("• {}: {} para {}", setting_name(entry.setting), display_value(entry.original.as_ref()), display_value(Some(&entry.applied))));
                    }
                    for note in &preview.notes { ui.label(note); }
                }
                ui.add_space(8.0);
                ui.horizontal_wrapped(|ui| {
                    if ui.button("Abrir Modo de Jogo no Windows").clicked() {
                        self.set_status(open_windows_settings(SettingsPage::GameMode), "Configurações abertas. Confira o estado diretamente no Windows.");
                    }
                    if ui.button("Abrir configurações de captura").clicked() {
                        self.set_status(open_windows_settings(SettingsPage::Capture), "Configurações abertas. A disponibilidade depende da edição e das políticas do Windows.");
                    }
                });
                ui.separator();
                ui.label(RichText::new(&self.status).color(if self.status_error { Color32::from_rgb(255, 160, 150) } else { Color32::from_rgb(190, 220, 160) }));
                if !self.session_notice.is_empty() { ui.label(&self.session_notice); }
                if self.preferences.advanced {
                    ui.add_space(24.0);
                    ui.heading("Recuperação");
                    ui.label("Se houver conflito, você pode preservar os valores atuais e arquivar o backup ativo para liberar uma nova análise.");
                    if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Arquivar backup sem restaurar")).clicked() { self.confirm_archive_backup = true; }
                    if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Reativar backup arquivado")).clicked() {
                        let mut dialog = rfd::FileDialog::new().add_filter("Backup JSON", &["json"]);
                        if let Some(path) = history_path() { dialog = dialog.set_directory(path); }
                        if let Some(path) = dialog.pick_file() { self.run(&ctx, move || JobResult::Restored(activate_backup(path))); }
                    }
                    ui.add_space(24.0);
                    ui.heading("Configurações do Windows");
                    ui.label("Abra os controles oficiais para revisar gráficos, inicialização, energia ou armazenamento. Algumas páginas dependem da versão do Windows.");
                    ui.horizontal_wrapped(|ui| {
                        for (label, page) in [("Gráficos por aplicativo", SettingsPage::Graphics), ("Aplicativos de inicialização", SettingsPage::Startup), ("Energia e suspensão", SettingsPage::Power), ("Armazenamento", SettingsPage::Storage)] {
                            if ui.button(label).clicked() { self.set_status(open_windows_settings(page), "Configurações abertas; a página pode variar conforme o Windows."); }
                        }
                    });
                    ui.add_space(24.0);
                    ui.heading("Diagnóstico do computador");
                    ui.label("Informações atuais, sem alterar o Windows.");
                    if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Atualizar diagnóstico")).clicked() {
                        self.status = "Consultando o computador...".into(); self.run(&ctx, || JobResult::Diagnostics(diagnostics::read()));
                    }
                    if let Some(snapshot) = &self.diagnostics {
                        if let (Some(available), Some(total)) = (snapshot.available_memory, snapshot.total_memory) {
                            ui.label(format!("Memória RAM disponível: {:.1} de {:.1} GiB", available as f64 / 1073741824.0, total as f64 / 1073741824.0));
                        }
                        if let Some(available) = snapshot.system_disk_available { ui.label(format!("Espaço disponível para este usuário no disco do Windows: {:.1} GiB", available as f64 / 1073741824.0)); }
                        if let Some(cores) = snapshot.logical_processors_available { ui.label(format!("Processadores lógicos disponíveis ao aplicativo: {cores}")); }
                        ui.label(match snapshot.power { PowerSource::Ac => "Energia: conectado à tomada", PowerSource::Battery => "Energia: usando bateria", PowerSource::Unknown => "Energia: estado indisponível" });
                        if let Some(plan) = &snapshot.active_power_plan { ui.label(format!("Plano de energia ativo: {plan}")); }
                        if let Some(percent) = snapshot.battery_percent { ui.label(format!("Bateria: {percent}%")); }
                        if snapshot.battery_saver == Some(true) { ui.label("Economia de bateria está ativada."); }
                    }
                    ui.add_space(24.0);
                    ui.heading("Processos em execução");
                    ui.label("Consulta pontual: a lista pode mudar a qualquer momento. Nenhum processo será encerrado.");
                    if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Listar processos")).clicked() {
                        self.status = "Consultando processos...".into(); self.run(&ctx, || JobResult::ProcessInventory(process_inventory::collect()));
                    }
                    if let Some(inventory) = &self.processes {
                        ui.label(format!("{} processo(s) listado(s){}", inventory.processes.len(), if inventory.truncated { " (lista limitada)" } else { "" }));
                        egui::ScrollArea::vertical().id_salt("process-list").max_height(260.0).show_rows(ui, 24.0, inventory.processes.len(), |ui, rows| {
                            for index in rows { let process = &inventory.processes[index]; ui.label(format!("{}  •  PID {}  •  {} thread(s)", process.name, process.pid, process.threads)); }
                        });
                    }
                    ui.add_space(24.0);
                    ui.heading("Arquivos temporários");
                    ui.label("Estime arquivos com mais de sete dias diretamente na pasta temporária; subpastas não são incluídas.");
                    if ui.add_enabled(self.receiver.is_none(), egui::Button::new("Estimar sem remover arquivos")).clicked() {
                        self.status = "Estimando arquivos temporários...".into(); self.run(&ctx, || JobResult::TempEstimate(temp_scan::estimate_user_temp()));
                    }
                    if let Some(estimate) = self.temp_estimate {
                        ui.label(format!("{} arquivo(s), {:.1} MiB estimados.", estimate.files, estimate.bytes as f64 / 1048576.0));
                        if estimate.skipped > 0 || estimate.truncated { ui.label("A estimativa é parcial porque alguns itens não puderam ser lidos ou o limite foi atingido."); }
                    }
                    ui.add_space(24.0);
                    ui.heading("Comparar capturas");
                    ui.label("Importe CSVs do PresentMon com MsBetweenPresents para comparar a mesma cena.");
                    ui.horizontal(|ui| {
                        for (before, label) in [(true, "Selecionar antes"), (false, "Selecionar depois")] {
                            if ui.add_enabled(self.receiver.is_none(), egui::Button::new(label)).clicked()
                                && let Some(path) = rfd::FileDialog::new().add_filter("CSV", &["csv"]).set_title(label).pick_file() {
                                self.status = "Lendo captura...".into(); self.run(&ctx, move || JobResult::Capture(before, benchmark::from_path(&path)));
                            }
                        }
                    });
                    if let (Some(before), Some(after)) = (&self.before, &self.after) {
                        match benchmark::compare(before, after) {
                            Ok(rows) => {
                                egui::Grid::new("benchmark").striped(true).show(ui, |ui| {
                                    for heading in ["Métrica", "Antes", "Depois", "Variação"] { ui.strong(heading); } ui.end_row();
                                    for (name, a, b, delta) in rows { ui.label(name); ui.label(format!("{a:.2}")); ui.label(format!("{b:.2}")); ui.label(format!("{delta:+.1}%")); ui.end_row(); }
                                });
                                if before.summary.frame_count < 1000 || after.summary.frame_count < 1000 { ui.label("Captura curta: 1% low e percentis podem variar muito."); }
                                if !before.complete_identity || !after.complete_identity { ui.label("Confirme que cada CSV contém apenas o jogo e uma swap chain."); }
                                if (after.seconds / before.seconds - 1.0).abs() > 0.1 { ui.label("As durações diferem mais de 10%."); }
                                ui.label("Repita a mesma cena; uma comparação isolada não comprova ganho.");
                            }
                            Err(error) => { ui.colored_label(Color32::LIGHT_RED, error); }
                        }
                    }
                }
            });
        });
        if self.confirm {
            egui::Window::new("Confirmar alterações").collapsible(false).resizable(false).show(&ctx, |ui| {
                ui.label("Aplicar somente as alterações listadas? Os valores anteriores serão salvos para restauração.");
                ui.horizontal(|ui| {
                    if ui.button("Cancelar").clicked() { self.confirm = false; }
                    if ui.button("Aplicar").clicked() {
                        self.confirm = false;
                        if let Some(preview) = self.preview.clone() { self.status = "Salvando backup e aplicando...".into(); self.run(&ctx, move || JobResult::Applied(apply_system(preview))); }
                    }
                });
            });
        }
        if self.confirm_session {
            egui::Window::new("Iniciar sessão do jogo").collapsible(false).resizable(false).show(&ctx, |ui| {
                ui.label("O executável selecionado será iniciado. O aplicativo tentará ajustar apenas a prioridade desse processo e salvará o valor anterior.");
                ui.horizontal(|ui| {
                    if ui.button("Cancelar").clicked() { self.confirm_session = false; }
                    if ui.button("Iniciar jogo").clicked() {
                        self.confirm_session = false;
                        if let Some(path) = self.game_path.clone() { self.status = "Iniciando jogo...".into(); self.run(&ctx, move || JobResult::SessionStarted(start_session(path))); }
                    }
                });
            });
        }
        if self.confirm_archive_session {
            egui::Window::new("Arquivar registro da sessão").collapsible(false).resizable(false).show(&ctx, |ui| {
                ui.label("A prioridade atual do jogo será mantida. O registro será arquivado e o aplicativo não poderá restaurá-la automaticamente a partir da sessão ativa.");
                ui.horizontal(|ui| {
                    if ui.button("Cancelar").clicked() { self.confirm_archive_session = false; }
                    if ui.button("Arquivar e manter prioridade").clicked() {
                        self.confirm_archive_session = false;
                        self.run(&ctx, || JobResult::SessionStopped(archive_session()));
                    }
                });
            });
        }
        if self.confirm_archive_backup {
            egui::Window::new("Arquivar backup ativo").collapsible(false).resizable(false).show(&ctx, |ui| {
                ui.label("As configurações atuais serão mantidas. O arquivo será guardado no histórico; para restaurá-lo depois, reative-o e use Restaurar último backup.");
                ui.horizontal(|ui| {
                    if ui.button("Cancelar").clicked() { self.confirm_archive_backup = false; }
                    if ui.button("Arquivar e manter configurações").clicked() {
                        self.confirm_archive_backup = false;
                        self.run(&ctx, || JobResult::Restored(archive_backup()));
                    }
                });
            });
        }
    }
}

fn setting_name(setting: Setting) -> &'static str {
    match setting {
        Setting::GameMode => "Ativar Modo de Jogo",
        Setting::Transparency => "Desativar transparência",
        Setting::GameCapturePolicy => "Política de capturas",
    }
}

fn display_value(value: Option<&windows_fps_optimizer::transaction::Value>) -> String {
    match value {
        None => "sem valor definido".into(),
        Some(v) if v.kind == 4 && v.bytes.len() == 4 => {
            let number = u32::from_le_bytes([v.bytes[0], v.bytes[1], v.bytes[2], v.bytes[3]]);
            format!("{number}")
        }
        Some(v) => format!(
            "tipo {}, {} bytes (será preservado no backup)",
            v.kind,
            v.bytes.len()
        ),
    }
}

enum SettingsPage {
    GameMode,
    Capture,
    Graphics,
    Startup,
    Power,
    Storage,
    About,
}

#[cfg(windows)]
fn open_windows_settings(page: SettingsPage) -> Result<(), String> {
    use std::ptr;
    use windows_sys::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};
    let uri = match page {
        SettingsPage::GameMode => "ms-settings:gaming-gamemode",
        SettingsPage::Capture => "ms-settings:gaming-gamedvr",
        SettingsPage::Graphics => "ms-settings:display-advancedgraphics",
        SettingsPage::Startup => "ms-settings:startupapps",
        SettingsPage::Power => "ms-settings:powersleep",
        SettingsPage::Storage => "ms-settings:storagesense",
        SettingsPage::About => "ms-settings:about",
    };
    let uri: Vec<u16> = uri.encode_utf16().chain(Some(0)).collect();
    let result = unsafe {
        ShellExecuteW(
            ptr::null_mut(),
            ptr::null(),
            uri.as_ptr(),
            ptr::null(),
            ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    if result as isize <= 32 {
        Err("Não foi possível abrir as Configurações. A página pode estar indisponível ou bloqueada neste Windows.".into())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn open_windows_settings(_: SettingsPage) -> Result<(), String> {
    Err("Esta opção requer Windows.".into())
}

#[cfg(windows)]
fn with_system<T>(
    action: impl FnOnce(&mut WindowsRegistry, &mut FileStore) -> Result<T, String>,
) -> Result<T, String> {
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    action(&mut WindowsRegistry::default(), &mut store)
}
#[cfg(windows)]
fn preview_system(preset: Preset) -> Result<Preview, String> {
    let version = compatibility::detect()?;
    let pagefile = if preset == Preset::Balanced {
        Some(windows_fps_optimizer::pagefile::detect_with_timeout(
            Duration::from_secs(8),
        )?)
    } else {
        None
    };
    let mut preview =
        with_system(|backend, store| engine::preview(backend, store, version, preset, pagefile))?;
    if legacy_backups_present() {
        preview.notes.push("Backups da versão anterior foram encontrados. Esta versão ainda não os restaura; mantenha a versão anterior para acessá-los.".into());
    }
    Ok(preview)
}

#[cfg(windows)]
fn legacy_backups_present() -> bool {
    let Some(root) = std::env::var_os("LOCALAPPDATA") else {
        return false;
    };
    let path = PathBuf::from(root)
        .join("WindowsFPSOptimizer")
        .join("Backups");
    match std::fs::read_dir(path) {
        Ok(mut entries) => entries.next().is_some(),
        Err(error) => error.kind() != std::io::ErrorKind::NotFound,
    }
}
#[cfg(windows)]
fn apply_system(preview: Preview) -> Result<(), String> {
    let version = compatibility::detect()?;
    let pagefile = if preview.preset == Preset::Balanced {
        Some(windows_fps_optimizer::pagefile::detect_with_timeout(
            Duration::from_secs(8),
        )?)
    } else {
        None
    };
    with_system(|backend, store| engine::apply(backend, store, version, &preview, pagefile))
}
#[cfg(windows)]
fn restore_system() -> Result<String, String> {
    with_system(|backend, store| {
        let report = engine::restore(backend, store)?;
        if !report.conflicts.is_empty() || !report.errors.is_empty() {
            let conflicts = report
                .conflicts
                .iter()
                .map(|s| setting_name(*s))
                .collect::<Vec<_>>()
                .join(", ");
            let errors = report
                .errors
                .iter()
                .map(|(s, e)| format!("{}: {e}", setting_name(*s)))
                .collect::<Vec<_>>()
                .join("; ");
            return Ok(format!(
                "Restauração parcial. Conflitos ou alterações de origem incerta: {}. Erros: {}. Os valores em conflito e o backup foram preservados; revise-os no Windows.",
                if conflicts.is_empty() {
                    "nenhum"
                } else {
                    &conflicts
                },
                if errors.is_empty() { "nenhum" } else { &errors }
            ));
        }
        Ok(format!(
            "Restauração concluída: {} ajuste(s) restaurado(s).",
            report.restored.len()
        ))
    })
}

#[cfg(windows)]
fn start_session(path: PathBuf) -> Result<String, String> {
    use windows_fps_optimizer::{
        session::{self, SessionStore},
        windows_process::{self, WindowsProcess},
    };
    let capabilities = compatibility::classify(Some(compatibility::detect()?));
    if !capabilities.supported {
        return Err(capabilities.reason.into());
    }
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    if store.load_session()?.is_some() {
        return Err(
            "Há uma sessão anterior. Restaure sua prioridade antes de iniciar outra.".into(),
        );
    }
    let process = windows_process::launch(&path)?;
    session::begin(&mut WindowsProcess, &mut store, process)
        .map_err(|e| format!("O jogo foi iniciado, mas a sessão não pôde ser aplicada: {e}"))?;
    Ok("Jogo iniciado. A prioridade original foi salva; use Restaurar prioridade da sessão para encerrá-la sem fechar o jogo.".into())
}

#[cfg(windows)]
fn stop_session() -> Result<String, String> {
    use windows_fps_optimizer::{
        session::{self, EndResult},
        windows_process::WindowsProcess,
    };
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    let result = session::end(&mut WindowsProcess, &mut store)?;
    Ok(match result {
        EndResult::Restored => "Prioridade original restaurada. O jogo permanece aberto.",
        EndResult::AlreadyOriginal => "A prioridade já estava no valor anterior.",
        EndResult::ProcessExited => "O processo do jogo já terminou; a sessão foi encerrada.",
        EndResult::Conflict => "A prioridade está em conflito ou sua origem é incerta. Ela e o registro da sessão foram preservados.",
    }.into())
}

#[cfg(windows)]
fn check_session() -> Result<SessionCheck, String> {
    use windows_fps_optimizer::{
        session::{self, ProcessBackend, SessionStore},
        windows_process::WindowsProcess,
    };
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    let Some(record) = store.load_session()? else {
        return Ok(SessionCheck::None);
    };
    if WindowsProcess.priority(record.process)?.is_none() {
        session::end(&mut WindowsProcess, &mut store)?;
        Ok(SessionCheck::Finished)
    } else {
        Ok(SessionCheck::Running)
    }
}

#[cfg(windows)]
fn archive_session() -> Result<String, String> {
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    let path = store.archive_session()?;
    Ok(format!(
        "Registro arquivado em {}. A prioridade atual foi preservada.",
        path.display()
    ))
}
#[cfg(windows)]
fn archive_backup() -> Result<String, String> {
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    let path = store.archive_backup()?;
    Ok(format!(
        "Backup arquivado em {}. As configurações atuais foram preservadas.",
        path.display()
    ))
}
#[cfg(windows)]
fn activate_backup(path: PathBuf) -> Result<String, String> {
    let mut store = FileStore::acquire(engine::state_directory()?)?;
    store.activate_backup(&path)?;
    Ok("Backup reativado. Use Restaurar último backup para restaurar os valores elegíveis.".into())
}
#[cfg(windows)]
fn history_path() -> Option<PathBuf> {
    engine::state_directory().ok().map(|p| p.join("History"))
}

#[cfg(not(windows))]
fn start_session(_: PathBuf) -> Result<String, String> {
    Err("Esta opção requer Windows.".into())
}
#[cfg(not(windows))]
fn stop_session() -> Result<String, String> {
    Err("Esta opção requer Windows.".into())
}
#[cfg(not(windows))]
fn check_session() -> Result<SessionCheck, String> {
    Ok(SessionCheck::None)
}
#[cfg(not(windows))]
fn archive_session() -> Result<String, String> {
    Err("Esta opção requer Windows.".into())
}
#[cfg(not(windows))]
fn archive_backup() -> Result<String, String> {
    Err("Esta opção requer Windows.".into())
}
#[cfg(not(windows))]
fn activate_backup(_: PathBuf) -> Result<String, String> {
    Err("Esta opção requer Windows.".into())
}
#[cfg(not(windows))]
fn history_path() -> Option<PathBuf> {
    None
}
#[cfg(not(windows))]
fn preview_system(_: Preset) -> Result<Preview, String> {
    Err("Este aplicativo requer Windows.".into())
}
#[cfg(not(windows))]
fn apply_system(_: Preview) -> Result<(), String> {
    Err("Este aplicativo requer Windows.".into())
}
#[cfg(not(windows))]
fn restore_system() -> Result<String, String> {
    Err("Este aplicativo requer Windows.".into())
}

fn preferences_path() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        engine::state_directory().ok().map(|p| p.join("ui.json"))
    }
    #[cfg(not(windows))]
    {
        None
    }
}
fn load_preferences() -> Preferences {
    let default = Preferences {
        schema: 1,
        onboarded: false,
        advanced: false,
        last_game: None,
    };
    let Some(path) = preferences_path() else {
        return default;
    };
    let Ok(bytes) = std::fs::read(path) else {
        return default;
    };
    match serde_json::from_slice::<Preferences>(&bytes) {
        Ok(p) if p.schema == 1 => p,
        _ => default,
    }
}
fn save_preferences(preferences: &Preferences) -> Result<(), String> {
    let path = preferences_path().ok_or("Pasta de preferências indisponível.")?;
    std::fs::create_dir_all(path.parent().ok_or("Pasta inválida.")?).map_err(|e| e.to_string())?;
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    let bytes = serde_json::to_vec(preferences).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Não foi possível salvar a preferência: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_preferences_remain_readable_without_a_game_path() {
        let input = r#"{"schema":1,"onboarded":true,"advanced":false}"#;
        let preferences: Preferences = serde_json::from_str(input).unwrap();
        assert!(preferences.onboarded);
        assert!(preferences.last_game.is_none());
    }
}
