// What Xcode does for Slashplayed on the Mac (Signing.swift's stub build), done through isideload's
// developer-services calls, as research/isideload proved on a free and a paid team: the device, the App IDs
// for the app and its .helper extension, their capabilities, the development certificate, and both profiles.
// isideload's high-level Sideloader isn't used: it turns on app groups, can revoke any certificate, and
// installs its own way.
//
// The owner's rules, enforced here:
// - App IDs are found and reused. One is made only when it's missing (the first run for a bundle ID) and the
//   team has room (a free team gets 10 a week); nothing else is ever made, and nothing is deleted.
// - The signing key identifies a reusable certificate. At the team limit, the user frees a slot.
// - The key is stored before Apple sees a request for it (keystore.rs): a certificate whose key is lost is a
//   wasted slot.
// - Free or paid is a profile question (listTeams has no flag): a free team's profile lasts 7 days and is
//   marked IsFreeProvisioningProfile, and Apple refuses it extended-virtual-addressing.

use idevice::usbmuxd::UsbmuxdDevice;
use isideload::{
    SideloadError,
    dev::{
        app_ids::{AppId, AppIdsApi},
        certificates::{CertificatesApi, DevelopmentCertificate},
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::DeveloperTeam,
    },
};
use http::HeaderValue;
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, PKCS_RSA_SHA256};
use rootcause::prelude::*;
use rsa::{
    RsaPrivateKey,
    pkcs1::EncodeRsaPublicKey,
    pkcs8::{EncodePrivateKey, LineEnding},
};
use serde_json::{Value as Json, json};
use x509_cert::{
    Certificate,
    der::{Decode, Encode},
};
use zeroize::Zeroizing;

use crate::{
    flow::Frontend,
    keystore, profile,
};

/// The name Apple shows for this tool's certificate (the developer site, Xcode's Manage Certificates): how
/// a person, and this tool at the certificate limit, tells it from Xcode's and other tools'.
pub const MACHINE_NAME: &str = "Slashplayed companion";
pub const IML: &str = "com.apple.developer.kernel.increased-memory-limit";
pub const EVA: &str = "com.apple.developer.kernel.extended-virtual-addressing";
/// submitDevelopmentCSR's result code when the team has all the development certificates it may.
const MAX_CERTS: i64 = 7460;
pub(crate) const CERT_QUOTA: &str =
    "A cota de certificados de desenvolvimento da equipe está cheia. Libere uma vaga manualmente no portal Apple Developer e tente novamente.";

pub fn developer_code(e: &Report) -> Option<i64> {
    e.iter_reports().find_map(|n| match n.downcast_current_context::<SideloadError>() {
        Some(SideloadError::DeveloperError(code, _)) => Some(*code),
        _ => None,
    })
}

/// The device, registered on the team (once; a free team's limit is Apple's to say).
pub async fn register_device(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    device: &UsbmuxdDevice,
    name: &str,
    ui: &dyn Frontend,
) -> Result<(), Report> {
    let devices = session.list_devices(team, None).await?;
    if devices.iter().any(|d| d.device_number == device.udid) {
        ui.say(&format!("{name} já está registrado na equipe"));
        return Ok(());
    }
    session.add_device(team, name, &device.udid, None).await?;
    ui.say(&format!("{name} foi registrado na equipe"));
    Ok(())
}

/// The app's and the helper's App IDs, found or (only when missing) made.
pub async fn app_ids(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    bundle_id: &str,
    ui: &dyn Frontend,
) -> Result<(AppId, AppId), Report> {
    let helper = crate::kit::helper_id(bundle_id);
    let list = session.list_app_ids(team, None).await?;
    let missing: Vec<String> = [bundle_id.to_string(), helper.clone()]
        .into_iter()
        .filter(|b| !list.app_ids.iter().any(|a| &a.identifier == b))
        .collect();
    if !missing.is_empty() {
        if let Some(avail) = list.available_quantity
            && avail < missing.len() as i64
        {
            bail!(
                "the team can make {avail} more App ID(s) right now and Slashplayed needs {}. A free team can make 10 a week: wait a few days and try again. Nothing was made",
                missing.len()
            );
        }
        for b in &missing {
            let name = if b.ends_with(".helper") { "Slashplayed helper" } else { "Slashplayed" };
            session.add_app_id(team, name, b, None).await?;
            ui.say(&format!("App ID {b} criado"));
        }
    }
    let list = session.list_app_ids(team, None).await?;
    let find = |b: &str| {
        list.app_ids
            .iter()
            .find(|a| a.identifier == b)
            .cloned()
            .ok_or_else(|| report!("Apple doesn't list the App ID {b} after making it"))
    };
    Ok((find(bundle_id)?, find(&helper)?))
}

/// What became of extended-virtual-addressing in the capability PATCH. `Refused` keeps Apple's status code
/// (and only that: the response body may carry account details) so a paid team's bail in `profiles()` can
/// say why, rather than blaming a free team it isn't.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Eva {
    Granted,
    Refused(u16),
}

/// What the capabilities PATCH's status means. Observed on 2026-11-02 (iPhone 16 Pro, both teams): a free
/// team gets 403 for the request with extended-virtual-addressing, a paid team a 2xx. Anything else (a 5xx,
/// 401 for stale auth, 429, …) says nothing about the team, so the run stops with it rather than sign a paid
/// team's app as a free one's.
#[derive(Debug, PartialEq, Eq)]
enum PatchAnswer {
    Granted,
    Refused,
    Failed,
}

fn classify(status: u16) -> PatchAnswer {
    match status {
        200..=299 => PatchAnswer::Granted,
        403 => PatchAnswer::Refused,
        _ => PatchAnswer::Failed,
    }
}

/// Capabilities, in one v1 bundleIds PATCH as Xcode sends them (isideload's own call can send only
/// increased-memory-limit). Says whether extended-virtual-addressing was granted: Apple refuses it for a
/// free team (403, classify), which is then signed with increased-memory-limit alone
/// (Signing.freeTeamDropped).
pub async fn capabilities(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    app_id: &AppId,
    ui: &dyn Frontend,
) -> Result<Eva, Report> {
    let status = patch_capabilities(session, team, app_id, &["INCREASED_MEMORY_LIMIT", "EXTENDED_VIRTUAL_ADDRESSING"]).await?;
    match classify(status) {
        PatchAnswer::Granted => Ok(Eva::Granted),
        PatchAnswer::Refused => {
            // The status alone (no body), so a run shows which answer it took.
            ui.say(&format!("A Apple recusou extended-virtual-addressing (HTTP {status}). A assinatura usará increased-memory-limit."));
            session
                .add_increased_memory_limit(team, app_id)
                .await
                .context("Apple refused the increased-memory-limit capability")?;
            Ok(Eva::Refused(status))
        }
        PatchAnswer::Failed => bail!(
            "Apple's capability service answered HTTP {status}, which isn't its refusal for a free team: try again in a few minutes"
        ),
    }
}

async fn patch_capabilities(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    app_id: &AppId,
    caps: &[&str],
) -> Result<u16, Report> {
    let mut headers = session.get_headers().await?;
    headers.insert("Content-Type", HeaderValue::from_static("application/vnd.api+json"));
    headers.insert("Accept", HeaderValue::from_static("application/vnd.api+json"));
    let data: Vec<Json> = caps
        .iter()
        .map(|c| {
            json!({
                "type": "bundleIdCapabilities",
                "attributes": { "settings": [], "enabled": true },
                "relationships": { "capability": { "data": { "id": c, "type": "capabilities" } } },
            })
        })
        .collect();
    let body = json!({ "data": {
        "id": app_id.app_id_id,
        "type": "bundleIds",
        "attributes": {
            "hasExclusiveManagedCapabilities": false, "teamId": team.team_id, "bundleType": "bundle",
            "identifier": app_id.identifier, "seedId": team.team_id, "name": app_id.name,
        },
        "relationships": { "bundleIdCapabilities": { "data": data } },
    }});
    let resp = session
        .get_grandslam_client()
        .patch(&format!("https://developerservices2.apple.com/services/v1/bundleIds/{}", app_id.app_id_id))?
        .headers(headers)
        .body(body.to_string())
        .send()
        .await
        .context("the capability request didn't go through")?;
    // The status alone is what the caller needs; the body (which may name the account) is never read into
    // an error.
    Ok(resp.status().as_u16())
}

/// The signing identity: our key and its certificate on the team.
pub struct Identity {
    pub key: RsaPrivateKey,
    pub cert_der: Vec<u8>,
}

fn csr(key: &RsaPrivateKey) -> Result<String, Report> {
    let mut params = CertificateParams::new(vec![])?;
    let mut dn = DistinguishedName::new();
    // Apple replaces the subject with its own; this is only what the request carries.
    dn.push(DnType::CommonName, MACHINE_NAME);
    params.distinguished_name = dn;
    let pem = Zeroizing::new(key.to_pkcs8_pem(LineEnding::LF)?.to_string());
    let pair = KeyPair::from_pkcs8_pem_and_sign_algo(&pem, &PKCS_RSA_SHA256)?;
    Ok(params.serialize_request(&pair)?.pem()?)
}

/// Whether a listed certificate's public key is `key`'s.
pub fn is_ours(c: &DevelopmentCertificate, key: &RsaPrivateKey) -> Option<Certificate> {
    let ours = key.to_public_key().to_pkcs1_der().ok()?;
    let x = Certificate::from_der(c.cert_content.as_ref()?.as_ref()).ok()?;
    (x.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes() == Some(ours.as_bytes())).then_some(x)
}

pub async fn identity(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    apple_id: &str,
    ui: &dyn Frontend,
) -> Result<Identity, Report> {
    let (key, stored) = match keystore::load(apple_id) {
        keystore::Loaded::Key(k) => (k, true),
        loaded => {
            let k = RsaPrivateKey::new(&mut rand::thread_rng(), 2048)?;
            let stored = match (&loaded, keystore::save(apple_id, &k)) {
                (_, Ok(())) => true,
                (keystore::Loaded::Unavailable(why), Err(_)) => {
                    ui.say(&format!(
                        "Gerenciador de credenciais indisponível ({why}). Será criado um certificado."
                    ));
                    false
                }
                (_, Err(e)) => {
                    ui.say(&format!("Será criado um certificado ({})", crate::secret::safe_error(&e)));
                    false
                }
            };
            (k, stored)
        }
    };
    let certs = session.list_ios_certs(team).await?;
    if let Some(cert) = certs.iter().find_map(|c| is_ours(c, &key)) {
        ui.say("Reutilizando o certificado Slashplayed deste computador.");
        let cert_der = cert.to_der()?;
        return Ok(Identity { key, cert_der });
    }
    let request = csr(&key)?;
    if let Err(e) = session.submit_development_csr(team, request, MACHINE_NAME.into(), None).await {
        if developer_code(&e) == Some(MAX_CERTS) {
            bail!(CERT_QUOTA);
        }
        return Err(e);
    }
    ui.say(if stored { "Certificado Slashplayed criado para este computador." } else { "Certificado Slashplayed criado para esta instalação." });
    let certs = session.list_ios_certs(team).await?;
    let cert = certs
        .iter()
        .find_map(|c| is_ours(c, &key))
        .ok_or_else(|| report!("Apple took the certificate request but lists no certificate with its key"))?;
    let cert_der = cert.to_der()?;
    Ok(Identity { key, cert_der })
}

/// Both profiles, checked: the app's with increased-memory-limit (and extended-virtual-addressing on a paid
/// team). The helper's may grant them too (a team whose helper App ID has the capabilities, as Xcode's
/// profile on the Mac does then): it's signed with its own template's entitlements, which leave them out
/// (Signing.helperDropped), and a signature may claim less than its profile grants. Returns them and whether
/// the team is free.
pub async fn profiles(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    app_id: &AppId,
    helper_id: &AppId,
    udid: &str,
    id: &Identity,
    eva: Eva,
    ui: &dyn Frontend,
) -> Result<(Vec<u8>, Vec<u8>, bool), Report> {
    let app = session.download_team_provisioning_profile(team, app_id, None).await?;
    let app_bytes: Vec<u8> = app.encoded_profile.as_ref().to_vec();
    let parsed = profile::Profile::parse(&app_bytes)?;
    let free = parsed.is_free() || app.is_free_provisioning_profile == Some(true);
    if let (false, Eva::Refused(status)) = (free, eva) {
        bail!(
            "Apple refused extended-virtual-addressing on {} (HTTP {status} to the capability request), but its profile isn't a free team's",
            team.team_id
        );
    }
    let want: &[&str] = if free { &[IML] } else { &[IML, EVA] };
    profile::check(&parsed, &team.team_id, &app_id.identifier, udid, &id.cert_der, want, &[])?;
    let helper = session.download_team_provisioning_profile(team, helper_id, None).await?;
    let helper_bytes: Vec<u8> = helper.encoded_profile.as_ref().to_vec();
    profile::check(&profile::Profile::parse(&helper_bytes)?, &team.team_id, &helper_id.identifier, udid, &id.cert_der, &[], &[])?;
    if let Some(exp) = parsed.expires() {
        let days = exp.duration_since(std::time::SystemTime::now()).map(|d| d.as_secs() / 86400).unwrap_or(0);
        ui.say(&format!(
            "Perfis da equipe {} preparados, válidos por mais {days} dias{}",
            if free { "gratuita" } else { "paga" },
            if free { " (repita a instalação dentro de uma semana para continuar usando o Slashplayed)" } else { "" }
        ));
    }
    Ok((app_bytes, helper_bytes, free))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_403_means_a_free_team() {
        for s in [200, 201, 204] {
            assert_eq!(classify(s), PatchAnswer::Granted, "{s}");
        }
        assert_eq!(classify(403), PatchAnswer::Refused);
        for s in [301, 400, 401, 404, 409, 429, 500, 503] {
            assert_eq!(classify(s), PatchAnswer::Failed, "{s}");
        }
    }

    #[test]
    fn our_certificate_is_found_by_key() {
        let key = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let other = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let pem = Zeroizing::new(key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string());
        let pair = KeyPair::from_pkcs8_pem_and_sign_algo(&pem, &PKCS_RSA_SHA256).unwrap();
        let der = CertificateParams::new(vec![]).unwrap().self_signed(&pair).unwrap().der().to_vec();
        let mut c: DevelopmentCertificate = serde_json::from_value(json!({"machineName": MACHINE_NAME})).unwrap();
        c.cert_content = Some(plist::Data::new(der));
        assert!(is_ours(&c, &key).is_some());
        assert!(is_ours(&c, &other).is_none());
    }
}
