// SP_GUI_DRILL=<state>: one screen with made-up data and no run, for screenshots and a look at each screen
// without a device (as the launcher's SP_START_DRILL does). Nothing here reaches a device or Apple; a
// question's answer goes nowhere.

use tokio::sync::oneshot;

use super::{App, front::Question, lock};
use crate::flow::{DeviceInfo, Done, Step, Wait};

pub const STATES: &[&str] = &[
    "device", "unlock", "developer-mode", "sign-in", "code", "team", "installing", "done", "error", "cert-limit",
];

fn phone(udid: &str, name: &str, class: &str, os: &str) -> DeviceInfo {
    DeviceInfo { udid: udid.into(), name: name.into(), class: class.into(), os: os.into() }
}

pub fn fill(app: &mut App, state: &str) {
    let mut s = lock(&app.shared);
    let iphone = phone("A", "iPhone de Alex", "iPhone", "27.1");
    let lines = [
        "Kit do dispositivo 1.5.0",
        "iPhone de Alex (iPhone, iOS 27.1)",
        "Iniciando login na Apple.",
        "Equipe Alex (A1B2C3D4E5)",
        "O iPhone já está registrado na equipe.",
        "Reutilizando o certificado Slashplayed deste computador.",
        "Perfis preparados.",
        "Aplicativo assinado.",
        "Instalando em iPhone de Alex (61 MB)",
    ];
    let numbers = vec![(1, "+1 (•••) •••-••42".to_string()), (2, "+44 ••••• ••••91".to_string())];
    s.step = Some(Step::Device);
    match state {
        "device" => {
            s.devices = vec![iphone.clone(), phone("B", "iPad de Alex", "iPad", "26.4")];
            app.device_choice = Some("A".into());
        }
        "unlock" => {
            s.device = Some(iphone.clone());
            s.wait = Some(Wait::UnlockToTrust { device: iphone.name.clone() });
        }
        "developer-mode" => {
            s.device = Some(iphone.clone());
            s.wait = Some(Wait::DeveloperMode { device: iphone.name.clone() });
        }
        "sign-in" => {
            s.step = Some(Step::SignIn);
            s.device = Some(iphone.clone());
            s.question = Some(Question::SignIn(oneshot::channel().0));
            app.apple_id = "alex@example.com".into();
        }
        "code" => {
            s.step = Some(Step::SignIn);
            s.question = Some(Question::TwoFactor { sms: false, retry: false, unknown: false, numbers, reply: oneshot::channel().0 });
            app.show_numbers = true;
        }
        "team" => {
            s.step = Some(Step::SignIn);
            s.question = Some(Question::Team {
                teams: vec![("Alex Example (Equipe pessoal)".into(), "A1B2C3D4E5".into()), ("Example Studio LLC".into(), "F6G7H8J9K0".into())],
                reply: oneshot::channel().0,
            });
            app.team_choice = Some(0);
        }
        "installing" => {
            s.step = Some(Step::Install);
            s.lines = lines.iter().map(|l| l.to_string()).collect();
            s.progress = Some(64);
        }
        "done" => {
            s.step = Some(Step::Container);
            s.lines = lines.iter().map(|l| l.to_string()).collect();
            s.outcome = Some(Ok(Done { device: iphone.name.clone(), free: true, renews: true }));
        }
        "error" => {
            s.step = Some(Step::SignIn);
            s.lines = lines[..3].iter().map(|l| l.to_string()).collect();
            s.outcome = Some(Err("Apple didn't accept the sign-in: the Apple ID or password is wrong".into()));
        }
        "cert-limit" => {
            s.step = Some(Step::Provision);
            s.lines = lines[..6].iter().map(|l| l.to_string()).collect();
            s.outcome = Some(Err(crate::provision::CERT_QUOTA.into()));
        }
        other => {
            drop(s);
            eprintln!("SP_GUI_DRILL: no state {other} (one of: {})", STATES.join(", "));
            std::process::exit(2);
        }
    }
}
