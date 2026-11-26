// No tracing subscriber is installed anywhere in this tool, so nothing isideload logs reaches any output; and
// DEBUG_SENSITIVE, which makes it put whole plists and the full email into errors, is cleared before the
// runtime starts (lib.rs, init).

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use isideload::{
    anisette::{
        AnisetteClientInfo, AnisetteProvider,
        remote_v3::{ANISETTE_STATE_KEY, RemoteV3AnisetteProvider},
    },
    auth::apple_account::{AppToken, AppleAccount},
    dev::developer_session::DeveloperSession,
    util::storage::SideloadingStorage,
};
use rootcause::prelude::*;
use zeroize::Zeroizing;

use crate::{flow::Frontend, session::{self, StoredSession}};

/// iloader 2.4.1's default: a server backed by Apple's Mac ADI. The Android-ADI servers (ani.sidestore.io,
/// ani.stikstore.app, ani.jkcoxson.com) have been refused with GSA -80045 since about 2026-10-12
/// (research/isideload/README.md, "Anisette"). --anisette names another, such as one you run yourself.
pub const DEFAULT_ANISETTE: &str = "https://mac-ani.jkcoxson.com";

/// The client identity iloader 2.4.2 sends in place of the server's (its fix for SMS 2FA 403s), which
/// every request of the login must then claim, the device's renewals too (device_token records it). 2.4.1's,
/// `<Mac15,7> <macOS;27.0;26A5378j>`, gets a 503 from GrandSlam's login since about 2026-11-20: its edge
/// refuses a `<macOS;…>` one. iloader warns this older one may bring back SMS 2FA trouble for some.
fn client_info_override() -> AnisetteClientInfo {
    AnisetteClientInfo {
        client_info: "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>".into(),
        user_agent: "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0".into(),
    }
}

/// isideload's storage, in memory only: the anisette provisioning state lives as long as the run.
#[derive(Clone, Default)]
struct MemoryStorage(Arc<Mutex<HashMap<String, Zeroizing<String>>>>);

impl SideloadingStorage for MemoryStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).insert(key.into(), Zeroizing::new(value.into()));
        Ok(())
    }
    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        Ok(self.0.lock().unwrap_or_else(|p| p.into_inner()).get(key).map(|value| value.to_string()))
    }
    fn delete(&self, key: &str) -> Result<(), Report> {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).remove(key);
        Ok(())
    }
}

/// The credential pushed as Library/spappletoken.json for on-device profile renewal.
fn device_token(stored: &StoredSession) -> Result<Option<Zeroizing<Vec<u8>>>, Report> {
    if stored.server_client_info {
        return Ok(None);
    }
    #[derive(serde::Serialize)]
    struct DeviceToken<'a> {
        token: &'a str,
        expiry: u64,
        duration: u64,
        adsid: &'a str,
        anisette_url: &'a str,
        anisette_state: &'a str,
        client_identity: ClientIdentity<'a>,
    }
    #[derive(serde::Serialize)]
    struct ClientIdentity<'a> {
        client_info: &'a str,
        user_agent: &'a str,
    }
    let token = DeviceToken {
        token: &stored.token,
        expiry: stored.expiry,
        duration: stored.duration,
        adsid: &stored.adsid,
        anisette_url: &stored.anisette_url,
        anisette_state: &stored.anisette_state,
        client_identity: ClientIdentity { client_info: &stored.client_info, user_agent: &stored.user_agent },
    };
    Ok(Some(Zeroizing::new(serde_json::to_vec(&token)?)))
}

fn identity(stored: &StoredSession) -> AnisetteClientInfo {
    AnisetteClientInfo { client_info: stored.client_info.clone(), user_agent: stored.user_agent.clone() }
}

fn developer_session(stored: &StoredSession, account: AppleAccount) -> DeveloperSession {
    DeveloperSession::new(
        AppToken { token: stored.token.to_string(), expiry: stored.expiry, duration: stored.duration },
        stored.adsid.to_string(),
        account.grandslam_client,
        account.anisette_generator,
    )
}

pub struct Resumed {
    pub session: DeveloperSession,
    pub device_token: Option<Zeroizing<Vec<u8>>>,
    pub anisette_changed: bool,
}

pub async fn resume(stored: &mut StoredSession) -> Result<Resumed, Report> {
    let storage = MemoryStorage::default();
    storage.store(ANISETTE_STATE_KEY, &stored.anisette_state)?;
    let provider = RemoteV3AnisetteProvider::new(&stored.anisette_url, Box::new(storage.clone()), "0".into())?
        .set_client_info_override(Some(identity(stored)));
    let account = AppleAccount::builder(&stored.apple_id).anisette_provider(provider).build().await?;
    let mut session = developer_session(stored, account);
    // Warm the same generator listTeams will use. If anisette reprovisions, keep the resulting state.
    session.get_headers().await?;
    let current = anisette_state(&storage)?;
    let changed = current.as_str() != stored.anisette_state.as_str();
    stored.anisette_state = current;
    Ok(Resumed { session, device_token: device_token(stored)?, anisette_changed: changed })
}

fn anisette_state(storage: &MemoryStorage) -> Result<Zeroizing<String>, Report> {
    let state = storage.retrieve(ANISETTE_STATE_KEY)?.ok_or_else(|| report!("Estado anisette indisponível."))?;
    Ok(Zeroizing::new(state))
}

pub struct SignedIn {
    pub session: DeveloperSession,
    pub device_token: Option<Zeroizing<Vec<u8>>>,
    pub stored: StoredSession,
    pub password: Option<Zeroizing<String>>,
}

/// Builds an account, then asks for the password and lets Apple drive 2FA.
pub async fn sign_in(
    apple_id: &str,
    anisette_url: &str,
    server_client_info: bool,
    remembered_password: Option<Zeroizing<String>>,
    remember_password: bool,
    ui: &dyn Frontend,
) -> Result<SignedIn, Report> {
    let storage = MemoryStorage::default();
    let provider = RemoteV3AnisetteProvider::new(anisette_url, Box::new(storage.clone()), "0".into())?;
    let identity = if server_client_info { provider.get_client_info().await? } else { client_info_override() };
    let provider = provider.set_client_info_override(Some(identity.clone()));
    let mut account = AppleAccount::builder(apple_id).anisette_provider(provider).build().await?;
    let password = match remembered_password {
        Some(password) => password,
        None => ui.password(apple_id).await?,
    };
    if password.is_empty() {
        bail!("Nenhuma senha informada.");
    }
    account.login(&password, |params| ui.two_factor(params)).await.context("A Apple não aceitou o login")?;
    let password = remember_password.then_some(password);
    let token = account.get_app_token("xcode.auth").await?;
    let adsid = account
        .spd
        .as_ref()
        .and_then(|s| s.get("adsid"))
        .and_then(|v| v.as_string())
        .ok_or_else(|| report!("A Apple não enviou os dados da sessão."))?;
    let stored = StoredSession {
        version: session::VERSION,
        apple_id: apple_id.into(),
        adsid: Zeroizing::new(adsid.into()),
        token: Zeroizing::new(token.token),
        expiry: token.expiry,
        duration: token.duration,
        anisette_url: anisette_url.into(),
        anisette_state: anisette_state(&storage)?,
        client_info: identity.client_info,
        user_agent: identity.user_agent,
        server_client_info,
        team_id: None,
        saved_at: session::now_ms(),
    };
    Ok(SignedIn {
        session: developer_session(&stored, account),
        device_token: device_token(&stored)?,
        stored,
        password,
    })
}

pub(crate) fn authentication_rejected(error: &Report) -> bool {
    error.iter_reports().any(|node| {
        if let Some(e) = node.downcast_current_context::<reqwest::Error>() {
            return e.status() == Some(reqwest::StatusCode::UNAUTHORIZED)
                && e.url().and_then(reqwest::Url::host_str).is_some_and(|host| {
                    matches!(host, "developerservices2.apple.com" | "gsa.apple.com")
                });
        }
        matches!(
            node.downcast_current_context::<isideload::SideloadError>(),
            Some(isideload::SideloadError::AuthWithMessage(-22411 | -20101 | -20102, _)
                | isideload::SideloadError::DeveloperError(1100, _))
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_apple_401_is_an_explicit_session_rejection() {
        use reqwest::ResponseBuilderExt;

        for (host, status, rejected) in [
            ("developerservices2.apple.com", 401, true),
            ("anisette.example", 401, false),
            ("developerservices2.apple.com", 403, false),
            ("developerservices2.apple.com", 429, false),
            ("developerservices2.apple.com", 503, false),
        ] {
            let response = http::Response::builder().status(status)
                .url(format!("https://{host}/").parse().unwrap())
                .body("").unwrap();
            let error = reqwest::Response::from(response).error_for_status().unwrap_err();
            assert_eq!(authentication_rejected(&report!(error).into_dynamic()), rejected);
        }
    }

    /// The pushed file has exactly the fields spapple's Token reads (apps/client/spapple/src/lib.rs), with
    /// Apple's numbers as numbers: the launcher (spapple.m) refuses one that doesn't.
    #[test]
    fn device_token_is_spapples_token() {
        let mut stored = crate::session::test_store::sample("x@example.com");
        let info = client_info_override();
        stored.client_info = info.client_info;
        stored.user_agent = info.user_agent;
        let v: serde_json::Value = serde_json::from_slice(&device_token(&stored).unwrap().unwrap()).unwrap();
        let mut keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        assert_eq!(keys, ["adsid", "anisette_state", "anisette_url", "client_identity", "duration", "expiry", "token"]);
        // The identity the sign-in claimed, which the device's renewals must claim too.
        assert_eq!(v["client_identity"]["client_info"], client_info_override().client_info);
        assert_eq!(v["client_identity"]["user_agent"], client_info_override().user_agent);
        assert!(v["expiry"].is_u64() && v["duration"].is_u64());
    }
}
