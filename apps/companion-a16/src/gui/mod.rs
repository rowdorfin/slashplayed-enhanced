// The window: the same install as slashplayed-cli (flow.rs), with its questions as screens. One fixed-size
// window; the screen follows the run (front.rs's Shared): the device, the Apple ID, the code, the team (only
// when there are several), the steps as they go, and the end. An error shows at the step it stopped, with
// Try Again and Copy Details.
//
// SP_GUI_DRILL=<state> opens one screen with made-up data and no run (drill.rs), for screenshots.

mod drill;
pub mod front;
mod theme;
mod home;
#[cfg(test)]
mod tests;

use eframe::egui;
use std::sync::Arc;

use egui::{Button, RichText, TextEdit};
use isideload::auth::apple_account::TwoFactorCallbackResponse;
use zeroize::{Zeroize, Zeroizing};

use crate::flow::{SignIn, Step, Wait};
use front::{Handle, Question, Shared, Starter, lock};
use theme::{DIM, ERROR, GOLD, GROUND, WELL};

/// Initial size of the resizable window.
pub const SIZE: [f32; 2] = [640.0, 760.0];

const STEPS: [(Step, &str); 6] = [
    (Step::Kit, "Obter o aplicativo Slashplayed"),
    (Step::Device, "Conectar ao dispositivo"),
    (Step::SignIn, "Entrar na Apple"),
    (Step::Provision, "Preparar os perfis de assinatura"),
    (Step::Install, "Assinar e instalar o aplicativo"),
    (Step::Container, "Preparar para instalar jogos"),
];

pub struct App {
    shared: Handle,
    starter: Starter,
    home: home::Home,
    /// Goodmountain is loaded (theme::apply).
    face: bool,
    apple_id: String,
    /// The password field's text, until Install hands it to the sign-in. Zeroed on drop.
    password: Zeroizing<String>,
    code: Zeroizing<String>,
    show_numbers: bool,
    device_choice: Option<String>,
    team_choice: Option<usize>,
    /// A drill's screenshot to save (SP_GUI_SHOT), and the frames drawn so far.
    shot: Option<(std::path::PathBuf, u32)>,
}

impl App {
    /// The window, with each run started by `starter`; or the drill's screen, and no run.
    pub fn new(ctx: &egui::Context, starter: Starter, drill: Option<&str>) -> Self {
        let face = theme::apply(ctx);
        let mut app = Self {
            shared: Handle::default(),
            starter,
            home: home::Home::new(drill.is_none(), if drill.is_none() {
                std::env::var_os("SP_GUI_KIT").map(std::path::PathBuf::from)
            } else { None }),
            face,
            apple_id: String::new(),
            password: Zeroizing::new(String::new()),
            code: Zeroizing::new(String::new()),
            show_numbers: false,
            device_choice: None,
            team_choice: None,
            shot: None,
        };
        match drill {
            Some("home") => {}
            Some(state) => {
                app.home.active = true;
                drill::fill(&mut app, state);
                app.shot = std::env::var_os("SP_GUI_SHOT").map(|p| (p.into(), 0));
            }
            None => {}
        }
        app
    }

    fn main_button(&self, ui: &mut egui::Ui, text: &str, enabled: bool) -> bool {
        let label = RichText::new(text).family(theme::family(self.face)).size(20.0).color(GROUND);
        ui.add_enabled(enabled, Button::new(label).fill(GOLD).min_size(egui::vec2(160.0, 40.0))).clicked()
    }

    fn header(&mut self, ui: &mut egui::Ui, title: &str) {
        ui.label(theme::title(title, self.face));
        ui.add_space(8.0);
    }

    fn restart(&mut self, ctx: &egui::Context) {
        {
            let mut s = lock(&self.shared);
            // Kept for the next run, unless that device is where it failed: then the person picks again.
            let failed_there = s.step == Some(Step::Device) && s.outcome.as_ref().is_some_and(|o| o.is_err());
            let picked = s.picked.take().filter(|_| !failed_there);
            *s = Shared { picked, ..Default::default() };
        }
        self.code.zeroize();
        forget_typing(ctx);
        self.show_numbers = false;
        self.team_choice = None;
        self.device_choice = None;
        self.home.active = true;
        (self.starter)(self.shared.clone(), ctx.clone(), self.home.options(&self.apple_id));
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let shared = self.shared.clone();
        let mut s = lock(&shared);
        if s.outcome.is_some() && s.cancelled {
            self.home.active = false;
            self.home.refresh();
            self.code.zeroize();
            forget_typing(&ctx);
            s.cancelled = false;
        }
        let frame = egui::Frame::new().fill(GROUND).inner_margin(24.0);
        egui::CentralPanel::default().frame(frame).show(ui, |ui| {
            egui::ScrollArea::vertical().id_salt("a16-main").show(ui, |ui| {
                if !self.home.active {
                    self.dashboard(ui, &mut s);
                    return;
                }
                match (&s.outcome, &s.question) {
                    (Some(Ok(_)), _) => self.done(ui, &mut s),
                    (Some(Err(_)), _) => self.steps(ui, &mut s, "Algo deu errado"),
                    (None, Some(Question::SignIn(_))) => self.sign_in(ui, &mut s),
                    (None, Some(Question::Password(_))) => self.ask_password(ui, &mut s),
                    (None, Some(Question::TwoFactor { .. })) => self.two_factor(ui, &mut s),
                    (None, Some(Question::Team { .. })) => self.team(ui, &mut s),
                    (None, _) if s.step == Some(Step::Device) => self.device(ui, &mut s),
                    (None, _) => self.steps(ui, &mut s, "Instalando"),
                }
                if let Some(step) = s.step {
                    let stage = step as usize + 1;
                    let done = s.outcome.as_ref().is_some_and(Result::is_ok);
                    let progress = if done { 1.0 } else { (stage - 1) as f32 / STEPS.len() as f32 };
                    ui.add(egui::ProgressBar::new(progress).text(format!("Etapa {stage} de {}", STEPS.len())));
                }
                ui.add_space(12.0);
                details(ui, &s);
            });
        });
        drop(s);
        if ctx.data(|d| d.get_temp::<bool>(retry_id())) == Some(true) {
            ctx.data_mut(|d| d.remove::<bool>(retry_id()));
            self.restart(&ctx);
        }
        if ctx.data(|d| d.get_temp::<bool>(home_id())) == Some(true) {
            ctx.data_mut(|d| d.remove::<bool>(home_id()));
            self.home.active = false;
            self.home.refresh();
        }
        self.screenshot(&ctx);
    }
}

impl App {
    /// A drill with SP_GUI_SHOT=<file.png>: the window's own frame, once it has settled, saved there, and
    /// the window closed. The rendered frame, on every system, with nothing else on the screen.
    fn screenshot(&mut self, ctx: &egui::Context) {
        let Some((path, frames)) = &mut self.shot else { return };
        *frames += 1;
        if *frames == 20 {
            let (path, ctx2) = (path.clone(), ctx.clone());
            ctx.request_screenshot(move |image| {
                let [w, h] = image.size;
                if let Err(e) = image::save_buffer(&path, image.as_raw(), w as u32, h as u32, image::ExtendedColorType::Rgba8) {
                    eprintln!("SP_GUI_SHOT: couldn't save {}: {e}", path.display());
                }
                ctx2.send_viewport_cmd(egui::ViewportCommand::Close);
            });
        }
        ctx.request_repaint();
    }
}

fn home_id() -> egui::Id { egui::Id::unique("sp-home") }

fn retry_id() -> egui::Id {
    egui::Id::unique("sp-retry")
}

fn password_id() -> egui::Id {
    egui::Id::unique("sp-password")
}

fn code_id() -> egui::Id {
    egui::Id::unique("sp-code")
}

/// egui keeps each text field's undo history, its text included, in the Context for as long as the
/// window is open: Ctrl+Z in an emptied password field would bring the password back. Dropped once the
/// text is sent (egui's own copies are freed, not zeroed: best effort, as the zeroing is).
fn forget_typing(ctx: &egui::Context) {
    ctx.data_mut(|d| {
        d.remove::<egui::text_edit::TextEditState>(password_id());
        d.remove::<egui::text_edit::TextEditState>(code_id());
    });
}

/// A note in a well, for what the person has to do on the device.
fn note(ui: &mut egui::Ui, text: &str) {
    egui::Frame::new().fill(WELL).stroke(egui::Stroke::new(1.0, GOLD.linear_multiply(0.6))).inner_margin(12.0).corner_radius(4.0).show(
        ui,
        |ui| {
            ui.set_width(ui.available_width());
            ui.label(text);
        },
    );
}

enum Mark {
    Done,
    Failed,
    ToCome,
}

/// A step's mark, drawn: the default faces have no check mark or cross.
fn mark(ui: &mut egui::Ui, m: Mark) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(18.0, 18.0), egui::Sense::hover());
    let p = ui.painter();
    let c = rect.center();
    let at = |x: f32, y: f32| c + egui::vec2(x, y);
    match m {
        Mark::Done => {
            p.line(vec![at(-5.5, 0.5), at(-1.5, 4.5), at(6.0, -4.5)], egui::Stroke::new(2.2, GOLD));
        }
        Mark::Failed => {
            let s = egui::Stroke::new(2.2, ERROR);
            p.line_segment([at(-4.5, -4.5), at(4.5, 4.5)], s);
            p.line_segment([at(-4.5, 4.5), at(4.5, -4.5)], s);
        }
        Mark::ToCome => {
            p.circle_stroke(c, 4.0, egui::Stroke::new(1.2, DIM));
        }
    }
}

fn small(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).small().color(DIM));
}

impl App {
    fn device(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        self.header(ui, "Conecte o dispositivo");
        let Some(d) = s.device.clone() else {
            if s.devices.is_empty() {
                ui.label("Conecte seu iPhone ou iPad com um cabo e desbloqueie-o.");
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(RichText::new("Procurando o dispositivo…").color(DIM));
                });
                return;
            }
            ui.label("Selecione o dispositivo que receberá o Slashplayed.");
            ui.add_space(8.0);
            for d in &s.devices {
                let label = format!("{} ({}, iOS {})", d.name, d.class, d.os);
                ui.radio_value(&mut self.device_choice, Some(d.udid.clone()), label);
            }
            ui.add_space(16.0);
            let chosen = self.device_choice.as_ref().filter(|u| s.devices.iter().any(|d| &d.udid == *u));
            if self.main_button(ui, "Continuar", chosen.is_some()) {
                s.picked = chosen.cloned();
            }
            return;
        };
        ui.label(RichText::new(&d.name).size(18.0));
        small(ui, &format!("{}, iOS {}", d.class, d.os));
        ui.add_space(12.0);
        match &s.wait {
            Some(Wait::DeveloperMode { device }) => {
                ui.label(format!("O Modo de Desenvolvedor está desativado em {device}."));
                ui.add_space(4.0);
                for (i, line) in [
                    "Abra Ajustes > Privacidade e Segurança > Modo de Desenvolvedor.".to_string(),
                    "Ative o modo e reinicie quando solicitado.".to_string(),
                    "Após reiniciar, desbloqueie, toque em Ativar e digite o código do dispositivo.".to_string(),
                ]
                .iter()
                .enumerate()
                {
                    ui.label(format!("{}. {line}", i + 1));
                }
                ui.add_space(12.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(RichText::new("A instalação continua assim que o modo for ativado.").color(DIM));
                });
            }
            Some(w) => {
                note(ui, &w.text());
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(RichText::new("Aguardando o dispositivo…").color(DIM));
                });
            }
            None => {
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label("Conectando…");
                });
            }
        }
    }

    fn sign_in(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        self.header(ui, "Entre com seu Apple ID");
        if let Some(d) = &s.device {
            ui.label(format!("Seu Apple ID assinará o Slashplayed para {}.", d.name));
            ui.add_space(8.0);
        }
        let id_label = ui.label("Apple ID");
        let id = ui.add(TextEdit::singleline(&mut self.apple_id).hint_text("nome@exemplo.com").desired_width(f32::INFINITY))
            .labelled_by(id_label.id);
        ui.add_space(16.0);
        let ready = !self.apple_id.trim().is_empty();
        let enter = id.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        if (self.main_button(ui, "Continuar", ready) || (enter && ready))
            && let Some(Question::SignIn(reply)) = s.question.take()
        {
            let sign_in = SignIn { apple_id: self.apple_id.trim().to_string(), pair_again: false };
            let _ = reply.send(sign_in);
        }
    }

    fn ask_password(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        self.header(ui, "Digite a senha do Apple ID");
        if s.rejected {
            note(ui, "Sessão rejeitada pela Apple. Entre novamente para continuar.");
        }
        let pw_label = ui.label("Senha");
        let pw = ui
            .add(TextEdit::singleline(&mut *self.password).id(password_id()).password(true).desired_width(f32::INFINITY))
            .labelled_by(pw_label.id);
        small(ui, "A senha só será guardada se você tiver marcado essa opção.");
        ui.add_space(16.0);
        let ready = !self.password.is_empty();
        let enter = pw.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        if (self.main_button(ui, "Enviar senha", ready) || (enter && ready))
            && let Some(Question::Password(reply)) = s.question.take()
        {
            let password = Zeroizing::new(std::mem::take(&mut *self.password));
            forget_typing(ui.ctx());
            let _ = reply.send(password);
        }
    }

    fn two_factor(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        let Some(Question::TwoFactor { sms, retry, unknown, numbers, .. }) = &s.question else { return };
        let (sms, retry, unknown, numbers) = (*sms, *retry, *unknown, numbers.clone());
        self.header(ui, "Digite o código de verificação");
        if retry {
            ui.label(RichText::new("Não foi possível verificar. Tente novamente ou solicite outro código.").color(ERROR));
        }
        let mut answer = None;
        if unknown {
            // The last way failed and Apple says nothing of where a code went: a code can't be sent, nor
            // resent, only asked for again (isideload's NeedsUnknown2FA).
            ui.label("Solicite um novo código nos dispositivos Apple ou por SMS.");
            ui.add_space(12.0);
            ui.horizontal(|ui| {
                if ui.button("Enviar aos meus dispositivos Apple").clicked() {
                    answer = Some(TwoFactorCallbackResponse::SendToDevices);
                }
                if ui.button("Cancelar").clicked() {
                    answer = Some(TwoFactorCallbackResponse::Abort);
                }
            });
            self.numbers(ui, &numbers, &mut answer);
            self.answer_code(&ui.ctx().clone(), s, answer);
            return;
        }
        ui.label(if sms {
            "A Apple enviou um código por SMS."
        } else {
            "Autorize o início de sessão em um dispositivo Apple para ver o código."
        });
        ui.add_space(8.0);
        let label = ui.label(if sms { "Código recebido por SMS" } else { "Código do dispositivo Apple" });
        let field = ui
.add(TextEdit::singleline(&mut *self.code).id(code_id()).password(true).char_limit(6).desired_width(140.0).font(egui::TextStyle::Heading))
            .labelled_by(label.id);
        self.code.retain(|c| c.is_ascii_digit());
        ui.add_space(12.0);
        let ready = self.code.len() == 6;
        let enter = field.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        if self.main_button(ui, "Continuar", ready) || (enter && ready) {
            answer = Some(TwoFactorCallbackResponse::SubmitCode(self.code.to_string()));
        }
        ui.add_space(16.0);
        ui.horizontal(|ui| {
            if !numbers.is_empty() && ui.button("Receber por SMS").clicked() {
                self.show_numbers = !self.show_numbers;
            }
            if sms && ui.button("Enviar aos meus dispositivos Apple").clicked() {
                answer = Some(TwoFactorCallbackResponse::SendToDevices);
            }
            if ui.button("Reenviar").clicked() {
                answer = Some(TwoFactorCallbackResponse::ResendCode);
            }
            if ui.button("Cancelar").clicked() {
                answer = Some(TwoFactorCallbackResponse::Abort);
            }
        });
        if self.show_numbers {
            self.numbers(ui, &numbers, &mut answer);
        }
        self.answer_code(&ui.ctx().clone(), s, answer);
    }

    fn numbers(&mut self, ui: &mut egui::Ui, numbers: &[(u32, String)], answer: &mut Option<TwoFactorCallbackResponse>) {
        if numbers.is_empty() {
            return;
        }
        ui.add_space(8.0);
        ui.label("Escolha um número para receber o código");
        for (id, number) in numbers {
            // Apple sends them masked; they're shown only here, on the person's own screen.
            if ui.button(format!("Enviar SMS para {number}")).clicked() {
                *answer = Some(TwoFactorCallbackResponse::SendSms(*id));
            }
        }
    }

    fn answer_code(&mut self, ctx: &egui::Context, s: &mut Shared, answer: Option<TwoFactorCallbackResponse>) {
        if let Some(a) = answer
            && let Some(Question::TwoFactor { reply, .. }) = s.question.take()
        {
            self.code.zeroize();
            forget_typing(ctx);
            self.show_numbers = false;
            let _ = reply.send(a);
        }
    }

    fn team(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        let Some(Question::Team { teams, .. }) = &s.question else { return };
        let teams = teams.clone();
        self.header(ui, "Escolha uma equipe");
        ui.label("Escolha qual equipe deste Apple ID vai assinar o Slashplayed.");
        ui.add_space(8.0);
        for (i, (name, id)) in teams.iter().enumerate() {
            ui.radio_value(&mut self.team_choice, Some(i), format!("{name} ({id})"));
        }
        ui.add_space(16.0);
        if self.main_button(ui, "Continuar", self.team_choice.is_some())
            && let (Some(i), Some(Question::Team { reply, .. })) = (self.team_choice, s.question.take())
        {
            let _ = reply.send(i);
        }
    }

    /// The six steps as a checklist: done, the current one (with its wait, its progress, or its error), and
    /// those to come; and the Details below.
    fn steps(&mut self, ui: &mut egui::Ui, s: &mut Shared, title: &str) {
        self.header(ui, title);
        let error = s.outcome.as_ref().and_then(|o| o.as_ref().err().cloned());
        let current = s.step.unwrap_or(Step::Kit);
        for (step, label) in STEPS {
            ui.horizontal(|ui| {
                ui.set_min_height(24.0);
                if step < current || s.outcome.as_ref().is_some_and(|o| o.is_ok()) {
                    mark(ui, Mark::Done);
                    ui.label(label);
                } else if step == current {
                    if error.is_some() {
                        mark(ui, Mark::Failed);
                    } else {
                        ui.spinner();
                    }
                    ui.label(RichText::new(label).strong());
                } else {
                    mark(ui, Mark::ToCome);
                    ui.label(RichText::new(label).color(DIM));
                }
            });
            if step == current {
                ui.indent(label, |ui| {
                    if let Some(e) = &error {
                        let message = if e.contains("A cota de certificados") {
                            crate::provision::CERT_QUOTA
                        } else {
                            match current {
                                Step::Kit => "Não foi possível preparar o ZIP. Confira o caminho e verifique o SHA-256 na tela principal.",
                                Step::Device => "Não foi possível preparar o dispositivo. Confira o cabo, o desbloqueio e a autorização USB.",
                                Step::SignIn => "Não foi possível entrar na Apple. Confira os dados da conta e tente novamente.",
                                Step::Provision => "Não foi possível preparar os perfis de assinatura.",
                                Step::Install => "Não foi possível assinar ou instalar o aplicativo no dispositivo.",
                                Step::Container => "O aplicativo foi instalado, mas a configuração no dispositivo ficou incompleta.",
                            }
                        };
                        home::error(ui, message, e);
                    } else if let Some(w) = &s.wait {
                        note(ui, &w.text());
                    } else if step == Step::Install
                        && let Some(p) = s.progress
                    {
                        ui.add(egui::ProgressBar::new(p as f32 / 100.0).show_percentage().fill(GOLD.linear_multiply(0.8)));
                    } else if step == Step::Install && s.lines.last().is_some_and(|l| l.starts_with("Instalando em")) {
                        // The copy to the device reports nothing (idevice's upload has no progress), and on a
                        // phone it takes a minute or so: say it's going, until the install's percentages come.
                        small(ui, "Copiando o aplicativo para o dispositivo. Isso pode levar alguns minutos.");
                    }
                });
            }
        }
        if error.is_some() {
            ui.add_space(16.0);
            ui.horizontal(|ui| {
                if self.main_button(ui, "Tentar novamente", true) {
                    ui.ctx().data_mut(|d| d.insert_temp(retry_id(), true));
                }
                if ui.button("Voltar").clicked() {
                    ui.ctx().data_mut(|d| d.insert_temp(home_id(), true));
                }
            });
        }
    }

    fn done(&mut self, ui: &mut egui::Ui, s: &mut Shared) {
        let Some(Ok(done)) = &s.outcome else { return };
        let lines = done.lines();
        self.header(ui, "Instalação concluída");
        for (i, line) in lines.iter().enumerate() {
            if i == 0 {
                ui.label(RichText::new(line).size(18.0));
            } else {
                ui.label(line);
            }
            ui.add_space(4.0);
        }
        ui.add_space(16.0);
        if self.main_button(ui, "Voltar à tela principal", true) {
            ui.ctx().data_mut(|d| d.insert_temp(home_id(), true));
        }
    }

}

fn details(ui: &mut egui::Ui, s: &Shared) {
    if ui.button("Copiar log").clicked() {
        ui.ctx().copy_text(s.details());
    }
    egui::CollapsingHeader::new("Log da instalação").default_open(false).show(ui, |ui| {
        egui::ScrollArea::vertical().max_height(160.0).stick_to_bottom(true).show(ui, |ui| {
            for l in &s.lines {
                ui.label(RichText::new(crate::secret::sanitize(l)).small().color(DIM));
            }
        });
    });
}

/// Runs the window, with the real device and Apple.
pub fn run() -> eframe::Result {
    let drill = std::env::var("SP_GUI_DRILL").ok();
    let starter = front::starter(crate::live::Live::new);
    let icon = eframe::icon_data::from_png_bytes(include_bytes!("../../icons/slashplayed.png")).expect("the window's icon");
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Slashplayed Companion")
            // Wayland has no window icons: the compositor matches this to a desktop entry, if there's one.
            .with_app_id("slashplayed-companion")
            .with_inner_size(SIZE)
            .with_resizable(true)
            .with_drag_and_drop(true)
            .with_icon(Arc::new(icon)),
        ..Default::default()
    };
    eframe::run_native(
        "Slashplayed Companion",
        options,
        Box::new(move |cc| Ok(Box::new(App::new(&cc.egui_ctx, starter, drill.as_deref())))),
    )
}
