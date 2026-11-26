use std::{
    path::PathBuf,
    sync::mpsc::{self, Receiver, TryRecvError},
    time::{Duration, Instant},
};

use eframe::egui::{self, TextEdit};
use rootcause::prelude::*;
use zeroize::{Zeroize, Zeroizing};

use crate::{checksum, device, github, logs, secret, session, state};
use session::SessionStore;

use super::{App, Shared, details, front::RunOptions};

struct Job<T>(Receiver<Result<T, String>>);

impl<T: Send + 'static> Job<T> {
    fn spawn(ctx: &egui::Context, work: impl FnOnce() -> Result<T, Report> + Send + 'static) -> Self {
        let (tx, rx) = mpsc::channel();
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let result = work().map_err(|e| secret::safe_error(&e));
            let _ = tx.send(result);
            ctx.request_repaint();
        });
        Self(rx)
    }

    fn poll(job: &mut Option<Self>) -> Option<Result<T, String>> {
        let result = match job.as_ref()?.0.try_recv() {
            Ok(result) => result,
            Err(TryRecvError::Empty) => return None,
            Err(TryRecvError::Disconnected) => Err("A operação foi interrompida.".into()),
        };
        *job = None;
        Some(result)
    }
}

fn runtime() -> Result<tokio::runtime::Runtime, Report> {
    Ok(tokio::runtime::Builder::new_current_thread().enable_all().build()?)
}

struct UsbStatus {
    devices: Vec<device::Device>,
    // Associate a profile response with the selected device at the time of the request.
    profile: Option<(String, String)>,
}

#[derive(Default)]
struct AccountStatus {
    team: Option<String>,
    expires: Option<u64>,
}

type Verification = (String, bool, bool);

pub struct Home {
    pub active: bool,
    live: bool,
    pub(super) kit: String,
    pasted_hash: String,
    pub(super) verified: Option<Result<Verification, String>>,
    verifying: Option<Job<Verification>>,
    remember_session: bool,
    remember_password: bool,
    usb: Option<UsbStatus>,
    installed: Option<state::Installation>,
    state_error: Option<String>,
    usb_job: Option<Job<UsbStatus>>,
    usb_error: Option<String>,
    next_usb: Instant,
    account: Option<Result<AccountStatus, String>>,
    account_job: Option<Job<AccountStatus>>,
    account_id: String,
    account_changed: Instant,
    logout: Option<Job<()>>,
    logout_result: Option<Result<(), String>>,
    confirm_logout: bool,
    forget_key: bool,
    ci: Option<(github::Run, github::Artifact)>,
    ci_job: Option<Job<(github::Run, github::Artifact, Option<github::Token>)>>,
    pending_token: Option<github::Token>,
    download: Option<github::Download>,
    downloading: Option<Job<github::Download>>,
    ci_error: Option<String>,
    token: Zeroizing<String>,
    remember_token: bool,
    logs_dir: String,
    jetsam_limit: usize,
    exporting: Option<Job<logs::Export>>,
    export: Option<Result<logs::Export, String>>,
}

impl Home {
    pub fn new(live: bool, kit: Option<PathBuf>) -> Self {
        Self {
            active: false, live, kit: kit.map(|path| path.to_string_lossy().into_owned()).unwrap_or_default(),
            pasted_hash: String::new(), verified: None, verifying: None,
            remember_session: true, remember_password: false,
            usb: None, installed: None, state_error: None, usb_job: None, usb_error: None, next_usb: Instant::now(),
            account: None, account_job: None, account_id: String::new(), account_changed: Instant::now(),
            logout: None, logout_result: None, confirm_logout: false, forget_key: false,
            ci: None, ci_job: None, pending_token: None, download: None, downloading: None, ci_error: None,
            token: Zeroizing::new(String::new()), remember_token: false,
            logs_dir: String::new(), jetsam_limit: logs::DEFAULT_JETSAM_LIMIT, exporting: None, export: None,
        }
    }

    pub fn options(&self, apple_id: &str) -> RunOptions {
        RunOptions {
            kit: (!self.kit.trim().is_empty()).then(|| PathBuf::from(self.kit.trim())),
            hash: self.verified.as_ref().and_then(|result| result.as_ref().ok()).map(|(hash, _, _)| hash.clone()),
            remember_session: self.remember_session,
            remember_password: self.remember_password,
            apple_id: apple_id.trim().into(),
        }
    }

    pub fn refresh(&mut self) {
        self.account_id.clear();
        self.account = None;
        self.account_job = None;
        self.next_usb = Instant::now();
    }

    fn update(&mut self, ctx: &egui::Context, id: &str, selected: Option<&str>, selected_team: Option<&str>) {
        if let Some(result) = Job::poll(&mut self.usb_job) {
            match result {
                Ok(usb) => { self.usb = Some(usb); self.usb_error = None; }
                Err(e) => { self.usb = None; self.usb_error = Some(e); }
            }
        }
        if self.live && self.usb_job.is_none() && Instant::now() >= self.next_usb {
            self.next_usb = Instant::now() + Duration::from_secs(3);
            match state::load() {
                Ok(state) => { self.installed = state; self.state_error = None; }
                Err(e) => { self.installed = None; self.state_error = Some(secret::safe_error(&e)); }
            }
            let selected = selected.map(str::to_owned);
            let bundle = self.installed.as_ref().map(|state| state.bundle_id.clone())
                .or_else(|| selected_team.map(|team| format!("{team}.slashplayed")));
            self.usb_job = Some(Job::spawn(ctx, move || {
                runtime()?.block_on(async {
                    let devices = tokio::time::timeout(Duration::from_secs(5), device::list()).await??;
                    let selected = match selected {
                        Some(id) => devices.iter().find(|d| d.usb.udid == id),
                        None => devices.first().filter(|_| devices.len() == 1),
                    };
                    let profile = if let (Some(device), Some(bundle)) = (selected, bundle) {
                        tokio::time::timeout(Duration::from_secs(3), state::profile_expiry(device, &bundle))
                            .await.ok().and_then(Result::ok).flatten().map(|date| (device.usb.udid.clone(), date))
                    } else { None };
                    Ok(UsbStatus { devices, profile })
                })
            }));
        }
        if self.live {
            ctx.request_repaint_after(Duration::from_secs(1));
        }
        if let Some(result) = Job::poll(&mut self.logout) {
            if result.is_ok() {
                self.refresh();
            }
            self.logout_result = Some(result);
        }
        if self.live && id != self.account_id {
            self.account_id = id.into();
            self.account_job = None;
            self.account = None;
            self.account_changed = Instant::now();
        }
        if self.live && !id.is_empty() && self.logout.is_none() && self.account_job.is_none() && self.account.is_none() {
            let delay = Duration::from_millis(400);
            if self.account_changed.elapsed() >= delay {
                let id = id.to_owned();
                self.account_job = Some(Job::spawn(ctx, move || {
                    let stored = session::system_store().load(&id)?;
                    Ok(stored.map(|s| AccountStatus { team: s.team_id.clone(), expires: Some(s.expiry) }).unwrap_or_default())
                }));
            } else {
                ctx.request_repaint_after(delay);
            }
        }
        if let Some(result) = Job::poll(&mut self.account_job) { self.account = Some(result); }
        if let Some(result) = Job::poll(&mut self.verifying) { self.verified = Some(result); }
        if let Some(result) = Job::poll(&mut self.ci_job) {
            match result {
                Ok((run, artifact, token)) => { self.ci = Some((run, artifact)); self.pending_token = token; }
                Err(e) => self.ci_error = Some(e),
            }
        }
        if let Some(result) = Job::poll(&mut self.downloading) {
            match result {
                Ok(download) => {
                    self.pasted_hash.clear();
                    self.kit = download.path().to_string_lossy().into_owned();
                    self.download = Some(download);
                    self.verify(ctx);
                }
                Err(e) => self.ci_error = Some(e),
            }
        }
        if let Some(result) = Job::poll(&mut self.exporting) { self.export = Some(result); }
    }

    fn verify(&mut self, ctx: &egui::Context) {
        self.verified = None;
        let path = PathBuf::from(self.kit.trim());
        let pasted = self.pasted_hash.clone();
        self.verifying = Some(Job::spawn(ctx, move || checksum::check_file(&path, &pasted)));
    }

    fn zip(&mut self, ui: &mut egui::Ui) {
        let dropped = ui.input(|input| input.raw.dropped_files.first().map(|f| f.path().to_path_buf()));
        if let Some(path) = dropped {
            self.kit = path.to_string_lossy().into_owned();
            self.verify(ui.ctx());
        }
        ui.heading("ZIP do kit");
        ui.horizontal(|ui| {
            let label = ui.label("Caminho");
            if ui.add(TextEdit::singleline(&mut self.kit).hint_text("Digite um caminho ou solte o ZIP na janela")).labelled_by(label.id).changed() {
                self.verified = None;
                self.verifying = None;
            }
            #[cfg(windows)]
            if ui.button("Escolher…").clicked() {
                match choose_zip(ui.ctx()) {
                    Ok(Some(path)) => { self.kit = path; self.verify(ui.ctx()); }
                    Ok(None) => {}
                    Err(e) => self.verified = Some(Err(secret::safe_error(&e))),
                }
            }
        });
        ui.horizontal(|ui| {
            let label = ui.label("SHA-256 esperado");
            let pasted = ui.add(TextEdit::singleline(&mut self.pasted_hash).hint_text("Opcional, se houver SHA256SUMS ao lado do ZIP")).labelled_by(label.id);
            if pasted.changed() {
                self.verified = None;
                self.verifying = None;
            }
            if ui.add_enabled(!self.kit.trim().is_empty() && self.verifying.is_none(), egui::Button::new("Verificar")).clicked() {
                self.verify(ui.ctx());
            }
        });
        if self.verifying.is_some() {
            ui.spinner();
        } else if let Some(result) = &self.verified {
            match result {
                Ok((hash, reference, matched)) => {
                    ui.label(if !matched { "SHA-256 divergente" } else if *reference { "SHA-256 OK" } else { "SHA-256 calculado, sem referência para comparação" });
                    ui.monospace(hash);
                }
                Err(e) => error(ui, "Não foi possível verificar o ZIP.", e),
            }
        }
    }

    fn take_token(&mut self, ctx: &egui::Context) -> (Option<github::Token>, bool) {
        let token = github::Token::new(&self.token);
        self.token.zeroize();
        ctx.data_mut(|d| d.remove::<egui::text_edit::TextEditState>(egui::Id::unique("github-token")));
        (token, self.remember_token)
    }

    fn github(&mut self, ui: &mut egui::Ui) {
        egui::CollapsingHeader::new("Kit da CI no GitHub").show(ui, |ui| {
            let label = ui.label("Token do GitHub");
            ui.add(TextEdit::singleline(&mut *self.token).id(egui::Id::unique("github-token")).password(true)).labelled_by(label.id);
            ui.checkbox(&mut self.remember_token, "Lembrar token no Gerenciador de Credenciais");
            let busy = self.ci_job.is_some() || self.downloading.is_some();
            if ui.add_enabled(!busy, egui::Button::new("Consultar última CI bem-sucedida")).clicked() {
                self.ci_error = None;
                let (pasted, remember) = self.take_token(ui.ctx());
                let previous = self.pending_token.take();
                // Keep an unsaved token in memory for the explicit download that may follow.
                self.ci_job = Some(Job::spawn(ui.ctx(), move || {
                    if let Some(token) = pasted.as_ref().filter(|_| remember) {
                        github::remember(token)?;
                    }
                    let token = github::resolve(pasted.or(previous))?;
                    let (run, artifact) = runtime()?.block_on(github::latest(token.as_ref()))?;
                    Ok((run, artifact, token))
                }));
            }
            if let Some((run, artifact)) = &self.ci {
                ui.label(run.summary());
                ui.label(format!("{} · {} bytes", artifact.name, artifact.size_in_bytes));
                if ui.add_enabled(!busy, egui::Button::new("Baixar e verificar kit")).clicked() {
                    let artifact = artifact.clone();
                    let (pasted, remember) = self.take_token(ui.ctx());
                    let pending = self.pending_token.take();
                    self.ci_error = None;
                    self.downloading = Some(Job::spawn(ui.ctx(), move || {
                        if let Some(token) = pasted.as_ref().filter(|_| remember) { github::remember(token)?; }
                        let token = github::resolve(pasted.or(pending))?.ok_or_else(|| report!("Informe um token do GitHub para baixar o kit."))?;
                        runtime()?.block_on(github::download(&artifact, &token))
                    }));
                }
            }
            if busy { ui.spinner(); }
            if let Some(download) = &self.download
                && let Some(sha) = &download.app_sha {
                ui.label(format!("app_sha: {sha}"));
            }
            if let Some(e) = &self.ci_error { error(ui, "Não foi possível concluir a operação no GitHub.", e); }
        });
    }

    fn logs(&mut self, ui: &mut egui::Ui, s: &Shared, selected_team: Option<&str>) {
        egui::CollapsingHeader::new("Logs do dispositivo").default_open(true).show(ui, |ui| {
            let label = ui.label("Diretório de saída");
            ui.add(TextEdit::singleline(&mut self.logs_dir)).labelled_by(label.id);
            ui.horizontal(|ui| {
                let label = ui.label("Limite de relatórios Jetsam");
                ui.add(egui::DragValue::new(&mut self.jetsam_limit)).labelled_by(label.id);
            });
            if ui.add_enabled(self.exporting.is_none() && !self.logs_dir.trim().is_empty(), egui::Button::new("Exportar logs")).clicked() {
                let out = PathBuf::from(self.logs_dir.trim());
                let udid = s.picked.clone();
                let team = selected_team.map(str::to_owned);
                let limit = self.jetsam_limit;
                self.export = None;
                self.exporting = Some(Job::spawn(ui.ctx(), move || runtime()?.block_on(logs::export(&out, None, team.as_deref(), udid.as_deref(), limit))));
            }
            if self.exporting.is_some() { ui.spinner(); }
            match &self.export {
                Some(Ok(result)) => {
                    ui.label(format!("{} arquivo(s) exportado(s). Consulte manifest.txt.", result.copied));
                    for limitation in &result.limitations { ui.label(limitation); }
                }
                Some(Err(e)) => error(ui, "Não foi possível exportar os logs.", e),
                None => {}
            }
        });
    }

    fn logout_dialog(&mut self, ctx: &egui::Context, id: &str) {
        if !self.confirm_logout { return; }
        egui::Modal::new(egui::Id::unique("logout")).show(ctx, |ui| {
            ui.heading("Desconectar conta");
            ui.label("A sessão e a senha guardadas serão removidas deste computador.");
            ui.checkbox(&mut self.forget_key, "Também apagar a chave do certificado");
            ui.horizontal(|ui| {
                if ui.button("Confirmar").clicked() {
                    let id = id.to_owned();
                    let key = self.forget_key;
                    self.logout_result = None;
                    self.logout = Some(Job::spawn(ctx, move || session::logout(&session::system_store(), &id, key, crate::keystore::forget)));
                    self.confirm_logout = false;
                }
                if ui.button("Cancelar").clicked() { self.confirm_logout = false; }
            });
        });
    }
}

impl App {
    pub(super) fn dashboard(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        self.header(ui, "Slashplayed Companion A16");
        let home = &mut self.home;
        let remembered_team = home.account.as_ref().and_then(|result| result.as_ref().ok()).and_then(|a| a.team.clone());
        let team = s.team.clone().or(remembered_team);
        home.update(ui.ctx(), self.apple_id.trim(), s.picked.as_deref(), team.as_deref());
        if let Some(usb) = &home.usb {
            if !usb.devices.iter().any(|d| Some(&d.usb.udid) == s.picked.as_ref()) {
                s.picked = None;
            }
            if usb.devices.is_empty() { ui.label("Nenhum dispositivo conectado por USB."); }
            for d in &usb.devices {
                let short: String = d.usb.udid.chars().take(8).collect();
                let text = format!("{} · {} · iOS {} · UDID {short}…", d.name, d.model, d.os);
                if usb.devices.len() == 1 {
                    ui.label(text);
                } else {
                    ui.radio_value(&mut s.picked, Some(d.usb.udid.clone()), text);
                }
            }
        } else {
            ui.label("Dispositivos USB");
        }
        if let Some(e) = &home.usb_error {
            error(ui, "Não foi possível consultar o dispositivo USB.", e);
        }
        if let Some(e) = &home.state_error {
            error(ui, "Não foi possível ler o registro da última instalação.", e);
        }
        let install = home.installed.as_ref();
        let profile = home.usb.as_ref().and_then(|usb| usb.profile.as_ref())
            .filter(|(id, _)| s.picked.as_ref().map_or_else(|| home.usb.as_ref().is_some_and(|usb| usb.devices.len() == 1), |picked| picked == id));
        let signature = if let Some((_, date)) = profile {
            format!("Assinatura · validade até {}", date_br(date))
        } else if let Some(date) = install.and_then(|state| state.expires.as_deref()) {
            format!("Assinatura · validade até {} (registrada na última instalação)", date_br(date))
        } else { "Assinatura · validade desconhecida".into() };
        ui.label(signature);
        ui.separator();
        ui.heading("Conta Apple");
        let masked = match self.apple_id.trim().split_once('@') {
            Some((_, domain)) => format!("***@{domain}"),
            None if self.apple_id.trim().is_empty() => "não informado".into(),
            None => "***".into(),
        };
        let team = team.or_else(|| install.map(|state| state.team.clone()));
        ui.label(format!("Apple ID · {masked}   Equipe · {}", team.as_deref().unwrap_or("desconhecida")));
        let label = ui.label("Apple ID para instalação");
        if ui.add(TextEdit::singleline(&mut self.apple_id).password(true)).labelled_by(label.id).changed() {
            s.rejected = false;
            s.team = None;
            home.logout_result = None;
        }
        let session_status = if s.rejected { "rejeitada pela Apple".into() }
        else if home.account_job.is_some() { "consultando armazenamento local…".into() }
        else if let Some(Ok(AccountStatus { expires: Some(expiry), .. })) = &home.account {
            if *expiry > session::now_ms() && *expiry < 253_402_300_800_000 {
                let date = plist::Date::from(std::time::UNIX_EPOCH + Duration::from_millis(*expiry)).to_xml_format();
                format!("válida até {}", date_br(&date))
            } else { "expirada".into() }
        } else if matches!(home.account, Some(Err(_))) { "consulta indisponível".into() }
        else { "nenhuma sessão guardada".into() };
        ui.label(format!("Sessão · {session_status}"));
        if let Some(Err(e)) = &home.account { error(ui, "Não foi possível ler a sessão local.", e); }
        ui.checkbox(&mut home.remember_session, "Lembrar sessão neste computador");
        ui.checkbox(&mut home.remember_password, "Guardar senha no Gerenciador de Credenciais");
        ui.small("Quem acessar o seu gerenciador de credenciais poderá usar a senha guardada.");
        if ui.add_enabled(!self.apple_id.trim().is_empty() && home.logout.is_none(), egui::Button::new("Desconectar conta")).clicked() {
            home.confirm_logout = true;
            home.forget_key = false;
        }
        if home.logout.is_some() { ui.spinner(); }
        if let Some(result) = &home.logout_result {
            match result {
                Ok(()) => { ui.label("Conta desconectada neste computador."); s.rejected = false; s.team = None; }
                Err(e) => error(ui, "Não foi possível desconectar a conta.", e),
            }
        }
        ui.separator();
        home.zip(ui);
        let ready = if home.kit.trim().is_empty() {
            crate::kit::pinned_sha256().is_some() && home.pasted_hash.trim().is_empty()
        } else {
            matches!(&home.verified, Some(Ok((_, _, true))))
        };
        let ready = ready && home.logout.is_none() && home.downloading.is_none();
        if self.main_button(ui, "Instalar", ready) {
            ui.ctx().data_mut(|d| d.insert_temp(super::retry_id(), true));
        }
        let home = &mut self.home;
        home.github(ui);
        home.logs(ui, s, team.as_deref());
        home.logout_dialog(ui.ctx(), self.apple_id.trim());
        details(ui, s);
    }
}

pub(super) fn error(ui: &mut egui::Ui, message: &str, detail: &str) {
    ui.label(egui::RichText::new(message).color(super::ERROR));
    ui.collapsing("Detalhe técnico", |ui| { ui.label(secret::sanitize(detail)); });
}

fn date_br(iso: &str) -> String {
    match (iso.get(..4), iso.get(5..7), iso.get(8..10), iso.get(11..16)) {
        (Some(year), Some(month), Some(day), Some(time)) => format!("{day}/{month}/{year} às {time} UTC"),
        _ => iso.into(),
    }
}

#[cfg(windows)]
fn choose_zip(ctx: &egui::Context) -> Result<Option<String>, Report> {
    use windows_sys::Win32::UI::Controls::Dialogs::{
        CommDlgExtendedError, GetOpenFileNameW, OFN_EXPLORER, OFN_FILEMUSTEXIST, OFN_NOCHANGEDIR, OFN_PATHMUSTEXIST, OPENFILENAMEW,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};
    let foreground = unsafe { GetForegroundWindow() };
    let mut process = 0;
    if !foreground.is_null() {
        unsafe { GetWindowThreadProcessId(foreground, &mut process) };
    }
    let owner = if process == std::process::id() { foreground } else { std::ptr::null_mut() };
    let mut path = vec![0u16; 32768];
    let filter: Vec<u16> = "Arquivos ZIP\0*.zip\0\0".encode_utf16().collect();
    let title: Vec<u16> = "Escolher ZIP do kit\0".encode_utf16().collect();
    let mut dialog = OPENFILENAMEW {
        lStructSize: std::mem::size_of::<OPENFILENAMEW>() as u32,
        hwndOwner: owner,
        lpstrFilter: filter.as_ptr(),
        lpstrTitle: title.as_ptr(),
        lpstrFile: path.as_mut_ptr(),
        nMaxFile: path.len() as u32,
        Flags: OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR,
        ..Default::default()
    };
    // All buffers live through this synchronous call.
    if unsafe { GetOpenFileNameW(&mut dialog) } == 0 {
        let code = unsafe { CommDlgExtendedError() };
        if code != 0 { bail!("Diálogo de arquivos do Windows falhou (código {code})."); }
        return Ok(None);
    }
    ctx.request_repaint();
    let end = path.iter().position(|&c| c == 0).unwrap_or(path.len());
    Ok(Some(String::from_utf16(&path[..end])?))
}
