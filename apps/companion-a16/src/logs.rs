use std::{fs, io::Write, path::Path};

use idevice::{
    IdeviceService,
    afc::{AfcClient, opcode::AfcFopenMode},
    crashreportcopymobile::CrashReportCopyMobileClient,
    house_arrest::HouseArrestClient,
};
use rootcause::prelude::*;
use sha2::{Digest, Sha256};

use crate::{device, secret, state};

pub const DEFAULT_JETSAM_LIMIT: usize = 20;

#[derive(Default)]
pub struct Export {
    pub copied: usize,
    pub limitations: Vec<String>,
}

fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && !name.ends_with(['.', ' '])
        && !name
            .chars()
            .any(|c| c.is_control() || "/\\:<>|\"?*".contains(c))
        && !matches!(
            name.split('.')
                .next()
                .unwrap_or("")
                .to_ascii_uppercase()
                .as_str(),
            "CON"
                | "PRN"
                | "AUX"
                | "NUL"
                | "COM1"
                | "COM2"
                | "COM3"
                | "COM4"
                | "COM5"
                | "COM6"
                | "COM7"
                | "COM8"
                | "COM9"
                | "LPT1"
                | "LPT2"
                | "LPT3"
                | "LPT4"
                | "LPT5"
                | "LPT6"
                | "LPT7"
                | "LPT8"
                | "LPT9"
                | "COM¹"
                | "COM²"
                | "COM³"
                | "LPT¹"
                | "LPT²"
                | "LPT³"
        )
}

fn document(name: &str) -> bool {
    safe_name(name)
        && name.ends_with(".log")
        && (name.starts_with("spconsole") || name.starts_with("sp-metal-diag"))
}

fn jetsam(name: &str) -> bool {
    safe_name(name) && name.starts_with("JetsamEvent") && name.ends_with(".ips")
}

fn crash(name: &str) -> bool {
    safe_name(name) && {
        let name = name.to_ascii_lowercase();
        ["slashplayed", "wow", "world of warcraft", "spguest"]
            .iter()
            .any(|needle| name.contains(needle))
    }
}

fn select_crashes<T: Ord>(files: Vec<(String, T)>, limit: usize) -> Vec<String> {
    let mut jetsams = Vec::new();
    let mut selected = Vec::new();
    for (name, time) in files {
        let basename = name.rsplit('/').next().unwrap_or(&name);
        if !name.split('/').all(safe_name) {
            continue;
        }
        if jetsam(basename) {
            jetsams.push((time, name));
        } else if crash(basename) {
            selected.push(name);
        }
    }
    selected.sort();
    jetsams.sort_unstable_by(|a, b| b.cmp(a));
    selected.extend(jetsams.into_iter().take(limit).map(|(_, name)| name));
    selected
}

async fn copy(afc: &mut AfcClient, remote: &str, local: &Path) -> Result<(u64, String), Report> {
    let info = afc.get_file_info(remote).await?;
    if info.st_ifmt != "S_IFREG" {
        bail!("O caminho remoto não é um arquivo regular.");
    }
    let mut source = afc.open(remote, AfcFopenMode::RdOnly).await?;
    let result = async {
        let mut target = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(local)?;
        let mut size = 0;
        let mut hash = Sha256::new();
        let copied = async {
            while size < info.size as u64 {
                let remaining = info.size as u64 - size;
                let bytes = source.read_n(remaining.min(64 * 1024) as usize).await?;
                if bytes.is_empty() {
                    bail!("O arquivo remoto foi truncado durante a cópia.");
                }
                target.write_all(&bytes)?;
                hash.update(&bytes);
                size += bytes.len() as u64;
            }
            target.flush()?;
            Ok((size, hex::encode(hash.finalize())))
        }
        .await;
        drop(target);
        if copied.is_err() {
            let _ = fs::remove_file(local);
        }
        copied
    }
    .await;
    let _ = source.close().await;
    result
}

impl Export {
    fn limitation(&mut self, context: &str, error: Report) {
        self.limitations.push(secret::sanitize(&format!(
            "{context} ({})",
            secret::safe_error(&error)
        )));
    }

    async fn collect(
        &mut self,
        afc: &mut AfcClient,
        root: &str,
        names: Vec<String>,
        out: &Path,
        group: &str,
        manifest: &mut fs::File,
    ) -> Result<(), Report> {
        if names.is_empty() {
            return Ok(());
        }
        let group_dir = out.join(group);
        fs::create_dir(&group_dir)
            .context("O diretório de saída do serviço precisa estar livre")?;
        for name in names {
            let relative = format!("{group}/{name}");
            let local = group_dir.join(&name);
            let copied = async {
                fs::create_dir_all(local.parent().unwrap())?;
                copy(afc, &format!("{root}/{name}"), &local).await
            }
            .await;
            match copied {
                Ok((size, hash)) => {
                    writeln!(manifest, "{relative}\t{size}\t{hash}")?;
                    self.copied += 1;
                }
                Err(e) => self.limitation(&format!("Falha ao copiar {relative}"), e),
            }
        }
        Ok(())
    }
}

pub async fn export(
    out: &Path,
    bundle: Option<&str>,
    team: Option<&str>,
    udid: Option<&str>,
    limit: usize,
) -> Result<Export, Report> {
    let devices = device::list()
        .await
        .context("Falha ao listar dispositivos USB")?;
    let device = match udid {
        Some(id) => devices
            .iter()
            .find(|d| d.usb.udid == id)
            .ok_or_else(|| report!("O dispositivo selecionado não está conectado por USB."))?,
        None => match devices.as_slice() {
            [device] => device,
            [] => bail!("Nenhum dispositivo conectado por USB."),
            _ => bail!("Há vários dispositivos conectados. Selecione um UDID."),
        },
    };
    let mut result = Export::default();
    let installed = if bundle.is_none() {
        match state::load() {
            Ok(state) => state,
            Err(e) => {
                result.limitation("Falha ao ler state.json", e);
                None
            }
        }
    } else {
        None
    };
    let bundle = bundle
        .map(str::to_owned)
        .or_else(|| installed.map(|s| s.bundle_id))
        .or_else(|| team.map(|t| format!("{t}.slashplayed")));
    fs::create_dir_all(out)?;
    let mut manifest = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(out.join("manifest.txt"))
        .context("Use um diretório de saída sem manifest.txt")?;
    writeln!(manifest, "arquivo\tbytes\tSHA-256")?;
    if let Some(bundle) = bundle {
        let documents = async {
            let service = HouseArrestClient::connect(&device.provider()).await.context("Falha ao abrir house_arrest")?;
            let mut afc = service.vend_documents(&bundle).await.context(
                "house_arrest recusou VendDocuments. Confira o bundle ID, a instalação e UIFileSharingEnabled")?;
            // VendDocuments exposes the Documents directory as the AFC root.
            let names = afc.list_dir("/").await.context("Falha ao listar Documents via house_arrest")?
                .into_iter().filter(|name| document(name)).collect();
            result.collect(&mut afc, "", names, out, "Documents", &mut manifest).await
        }.await;
        if let Err(e) = documents {
            result.limitation("Logs do aplicativo indisponíveis", e);
        }
    } else {
        result.limitations.push("Logs do aplicativo ignorados. Informe o bundle ID ou a equipe, ou instale pelo Companion.".into());
    }
    let crashes = async {
        let mut afc = CrashReportCopyMobileClient::connect(&device.provider())
            .await
            .context("Falha ao abrir com.apple.crashreportcopymobile")?
            .to_afc_client();
        let mut folders = vec![String::new()];
        let mut files = Vec::new();
        while let Some(folder) = folders.pop() {
            let names = match afc.list_dir(format!("/{folder}")).await {
                Ok(names) => names,
                Err(e) => {
                    result.limitation(
                        &format!("Falha ao listar relatórios de falha em /{folder}"),
                        e.into(),
                    );
                    continue;
                }
            };
            for name in names.into_iter().filter(|name| safe_name(name)) {
                let relative = if folder.is_empty() {
                    name.clone()
                } else {
                    format!("{folder}/{name}")
                };
                match afc.get_file_info(format!("/{relative}")).await {
                    Ok(info) if info.st_ifmt == "S_IFDIR" => folders.push(relative),
                    Ok(info) if info.st_ifmt == "S_IFREG" && (crash(&name) || jetsam(&name)) => {
                        files.push((relative, info.modified));
                    }
                    Ok(_) => {}
                    Err(e) => {
                        result.limitation(&format!("Falha ao consultar {relative}"), e.into())
                    }
                }
            }
        }
        let names = select_crashes(files, limit);
        result
            .collect(&mut afc, "", names, out, "CrashReports", &mut manifest)
            .await
    }
    .await;
    if let Err(e) = crashes {
        result.limitation("Relatórios de falha indisponíveis", e);
    }
    manifest.flush()?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_only_requested_names_and_latest_jetsam() {
        assert!(document("spconsole.log"));
        assert!(document("sp-metal-diag-1.log"));
        assert!(!document("spconsole.json"));
        assert!(!document("spconsole/../a.log"));
        let files = [
            ("JetsamEvent-old.ips", 1),
            ("Retired/JetsamEvent-new.ips", 2),
            ("Slashplayed-1.ips", 1),
            ("spguest.ips", 2),
            ("WoW-1.ips", 2),
            ("World of Warcraft.ips", 2),
            ("../slashplayed.ips", 3),
            ("other.ips", 3),
        ]
        .map(|(name, date)| (name.into(), date))
        .to_vec();
        assert_eq!(
            select_crashes(files.clone(), 1),
            [
                "Slashplayed-1.ips",
                "WoW-1.ips",
                "World of Warcraft.ips",
                "spguest.ips",
                "Retired/JetsamEvent-new.ips"
            ]
        );
        assert_eq!(select_crashes(files, 0).len(), 4);
    }
}
