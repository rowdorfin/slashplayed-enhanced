// GitHub Actions metadata and verified extraction. Requests are only made by explicit commands.
use std::{
    fmt,
    io::{Cursor, Read, Write},
    path::Path,
    process::Command,
    time::Duration,
};

use reqwest::{Client, Response, Url, header};
use rootcause::prelude::*;
use serde::Deserialize;
use zeroize::Zeroizing;

use crate::{checksum, secret::Scratch};

const API: &str = "https://api.github.com/repos/rowdorfin/slashplayed-enhanced/actions";
const SERVICE: &str = "com.rowdorfin.slashplayed-a16.github";
const KIT: &str = "slashplayed-device-kit.zip";
const MAX_ZIP: usize = 1024 * 1024 * 1024;

pub struct Token(Zeroizing<String>);

impl Token {
    pub fn new(text: &str) -> Option<Self> {
        (!text.trim().is_empty()).then(|| Self(Zeroizing::new(text.trim().into())))
    }
}

impl fmt::Debug for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redigido>")
    }
}

fn entry() -> Result<keyring::Entry, Report> {
    Ok(keyring::Entry::new(SERVICE, "github")?)
}

pub fn remember(token: &Token) -> Result<(), Report> {
    let value = token.0.clone();
    crate::keystore::off_runtime(move || {
        entry()?
            .set_password(&value)
            .map_err(|_| report!("Não foi possível guardar o token no gerenciador de credenciais."))
    })
}

pub fn resolve(pasted: Option<Token>) -> Result<Option<Token>, Report> {
    for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let Ok(value) = std::env::var(key) {
            let value = Zeroizing::new(value);
            if let Some(token) = Token::new(&value) {
                return Ok(Some(token));
            }
        }
    }
    if let Ok(output) = Command::new("gh")
        .args(["auth", "token", "--hostname", "github.com"])
        .output()
    {
        let stdout = Zeroizing::new(output.stdout);
        let _stderr = Zeroizing::new(output.stderr);
        if output.status.success()
            && let Some(token) = std::str::from_utf8(&stdout).ok().and_then(Token::new)
        {
            return Ok(Some(token));
        }
    }
    if pasted.is_some() {
        return Ok(pasted);
    }
    crate::keystore::off_runtime(|| match entry()?.get_password() {
        Ok(value) => Ok(Token::new(&Zeroizing::new(value))),
        Err(
            keyring::Error::NoEntry
            | keyring::Error::NoStorageAccess(_)
            | keyring::Error::PlatformFailure(_),
        ) => Ok(None),
        Err(_) => Err(report!(
            "Não foi possível ler o token no gerenciador de credenciais."
        )),
    })
}

#[derive(Deserialize)]
pub struct Run {
    pub id: u64,
    pub head_sha: String,
    pub created_at: String,
    pub status: String,
    pub conclusion: Option<String>,
    head_commit: Option<Commit>,
}

#[derive(Deserialize)]
struct Commit {
    message: String,
}

impl Run {
    pub fn summary(&self) -> String {
        let sha: String = self.head_sha.chars().take(7).collect();
        let message = self
            .head_commit
            .as_ref()
            .map(|commit| crate::secret::sanitize(&commit.message))
            .unwrap_or_else(|| "Sem mensagem".into());
        format!(
            "{sha} — {message}\n{} · CI concluída com sucesso",
            self.created_at
        )
    }
}

#[derive(Deserialize, Clone)]
pub struct Artifact {
    pub id: u64,
    pub name: String,
    pub size_in_bytes: u64,
    expired: bool,
}

fn select_run(json: &[u8]) -> Result<Run, Report> {
    #[derive(Deserialize)]
    struct Runs {
        workflow_runs: Vec<Run>,
    }
    serde_json::from_slice::<Runs>(json)?
        .workflow_runs
        .into_iter()
        .find(|run| run.conclusion.as_deref() == Some("success") && run.status == "completed")
        .ok_or_else(|| report!("Nenhuma execução bem-sucedida encontrada na branch a16-support."))
}

fn select_artifact(json: &[u8], sha: &str) -> Result<Artifact, Report> {
    #[derive(Deserialize)]
    struct Artifacts {
        artifacts: Vec<Artifact>,
    }
    let name = format!("a16-metal-diagnostic-kit-{sha}");
    serde_json::from_slice::<Artifacts>(json)?
        .artifacts
        .into_iter()
        .find(|artifact| !artifact.expired && artifact.name == name)
        .ok_or_else(|| report!("O artefato do commit está ausente ou expirado."))
}

fn client() -> Result<Client, Report> {
    Ok(Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("Slashplayed-Companion-A16")
        .timeout(Duration::from_secs(300))
        .build()?)
}

async fn get(client: &Client, url: &str, token: Option<&Token>) -> Result<Response, Report> {
    let mut request = client
        .get(url)
        .header("X-GitHub-Api-Version", "2022-11-28")
        .header(header::ACCEPT, "application/vnd.github+json");
    if let Some(token) = token {
        let bearer = Zeroizing::new(format!("Bearer {}", *token.0));
        let mut value = header::HeaderValue::from_str(&bearer)
            .map_err(|_| report!("Token do GitHub inválido."))?;
        value.set_sensitive(true);
        request = request.header(header::AUTHORIZATION, value);
    }
    Ok(request.send().await?.error_for_status()?)
}

pub async fn latest(token: Option<&Token>) -> Result<(Run, Artifact), Report> {
    let client = client()?;
    let runs = get(&client, &format!("{API}/workflows/a16-metal-diagnostic.yml/runs?branch=a16-support&status=success&per_page=1"), token).await?;
    let run = select_run(&runs.bytes().await?)?;
    let artifacts = get(&client, &format!("{API}/runs/{}/artifacts", run.id), token).await?;
    let artifact = select_artifact(&artifacts.bytes().await?, &run.head_sha)?;
    Ok((run, artifact))
}

pub struct Download {
    scratch: Scratch,
    pub app_sha: Option<String>,
}

impl Download {
    pub fn path(&self) -> std::path::PathBuf {
        self.scratch.path().join(KIT)
    }

    pub fn save_to(&self, dir: &Path) -> Result<(), Report> {
        use std::fs::{self, File, OpenOptions};
        fs::create_dir_all(dir)?;
        let mut created = Vec::new();
        let result = (|| -> Result<(), Report> {
            for name in [KIT, "SHA256SUMS"] {
                let mut source = File::open(self.scratch.path().join(name))?;
                let path = dir.join(name);
                let mut dest = OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&path)?;
                created.push(path);
                std::io::copy(&mut source, &mut dest)?;
                dest.sync_all()?;
            }
            Ok(())
        })();
        if result.is_err() {
            for path in created {
                let _ = fs::remove_file(path);
            }
        }
        result
            .context("Falha ao salvar o ZIP e o SHA256SUMS. Use um diretório sem esses arquivos")?;
        Ok(())
    }
}

fn extract(bytes: &[u8], dir: &Path) -> Result<Option<String>, Report> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))?;
    let read = |file: zip::read::ZipFile<'_, _>, limit: usize| -> Result<Vec<u8>, Report> {
        let mut bytes = Vec::new();
        file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
        if bytes.len() > limit {
            bail!("Arquivo acima do tamanho permitido no artefato.");
        }
        Ok(bytes)
    };
    let sums = read(archive.by_name("SHA256SUMS")?, 1024 * 1024)?;
    let want = checksum::expected(std::str::from_utf8(&sums)?, KIT)?;
    let kit = read(archive.by_name(KIT)?, MAX_ZIP)?;
    if checksum::digest(&kit) != want {
        bail!("SHA-256 divergente no ZIP do artefato.");
    }
    let app_sha = match archive.by_name("metadata.json") {
        Ok(file) => {
            #[derive(Deserialize)]
            struct Metadata {
                app_sha: Option<String>,
            }
            serde_json::from_slice::<Metadata>(&read(file, 1024 * 1024)?)?.app_sha
        }
        Err(zip::result::ZipError::FileNotFound) => None,
        Err(e) => return Err(e.into()),
    };
    std::fs::File::create(dir.join(KIT))?.write_all(&kit)?;
    std::fs::write(dir.join("SHA256SUMS"), sums)?;
    Ok(app_sha)
}

pub async fn download(artifact: &Artifact, token: &Token) -> Result<Download, Report> {
    let client = client()?;
    let mut response = get(
        &client,
        &format!("{API}/artifacts/{}/zip", artifact.id),
        Some(token),
    )
    .await?;
    if response.status().is_redirection() {
        let url = response
            .headers()
            .get(header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|url| Url::parse(url).ok())
            .filter(|url| {
                url.scheme() == "https" && url.username().is_empty() && url.password().is_none()
            })
            .ok_or_else(|| report!("Redirecionamento inválido no download do GitHub."))?;
        response = client.get(url).send().await?.error_for_status()?;
    }
    if !response.status().is_success() {
        bail!(
            "Download do GitHub retornou HTTP {}.",
            response.status().as_u16()
        );
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > MAX_ZIP {
            bail!("Artefato acima do tamanho permitido.");
        }
        bytes.extend_from_slice(&chunk);
    }
    let scratch = Scratch::new("github")?;
    let app_sha = extract(&bytes, scratch.path())?;
    Ok(Download { scratch, app_sha })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simulated_workflow_and_artifacts() {
        let run = select_run(r#"{"workflow_runs":[{"id":42,"head_sha":"abcdef012345","created_at":"2026-11-25T00:00:00Z","status":"completed","conclusion":"success","head_commit":{"message":"Diagnóstico"}}]}"#.as_bytes()).unwrap();
        assert!(run.summary().contains("abcdef0 — Diagnóstico"));
        let json = br#"{"artifacts":[{"id":1,"name":"a16-metal-diagnostic-kit-abcdef012345","expired":true,"size_in_bytes":10},{"id":2,"name":"a16-metal-diagnostic-kit-abcdef012345","expired":false,"size_in_bytes":20}]}"#;
        assert_eq!(select_artifact(json, &run.head_sha).unwrap().id, 2);
        assert!(select_artifact(json, "other").is_err());
        assert!(select_run(br#"{"workflow_runs":[]}"#).is_err());
        assert_eq!(format!("{:?}", Token::new("test").unwrap()), "<redigido>");
    }

    #[test]
    fn rejects_mismatched_kit_and_reads_metadata() {
        let dir = tempfile::tempdir().unwrap();
        for valid in [false, true] {
            let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
            for (name, text) in [
                (KIT, "kit".into()),
                (
                    "SHA256SUMS",
                    format!(
                        "{}  {KIT}",
                        checksum::digest(if valid { b"kit" } else { b"bad" })
                    ),
                ),
                ("metadata.json", r#"{"app_sha":"abc"}"#.into()),
            ] {
                zip.start_file(name, zip::write::SimpleFileOptions::default())
                    .unwrap();
                zip.write_all(text.as_bytes()).unwrap();
            }
            let result = extract(&zip.finish().unwrap().into_inner(), dir.path());
            if valid {
                assert_eq!(result.unwrap().as_deref(), Some("abc"));
            } else {
                assert!(result.is_err());
                assert!(!dir.path().join(KIT).exists());
            }
        }
    }
}
