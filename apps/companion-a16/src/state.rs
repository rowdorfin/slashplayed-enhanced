use rootcause::prelude::*;
use serde::{Deserialize, Serialize};
use std::{fs, io::Write, path::PathBuf};

#[derive(Clone, Deserialize, Serialize)]
pub struct Installation {
    pub bundle_id: String,
    pub team: String,
    pub expires: Option<String>,
}

fn path() -> Result<PathBuf, Report> {
    use std::env::var_os;
    let base = if cfg!(windows) {
        var_os("LOCALAPPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        var_os("HOME").map(|p| PathBuf::from(p).join("Library/Application Support"))
    } else {
        var_os("XDG_CONFIG_HOME")
            .filter(|p| PathBuf::from(p).is_absolute())
            .map(PathBuf::from)
            .or_else(|| var_os("HOME").map(|p| PathBuf::from(p).join(".config")))
    };
    Ok(base
        .ok_or_else(|| report!("Diretório de configuração indisponível."))?
        .join("SlashplayedA16")
        .join("state.json"))
}

pub fn load() -> Result<Option<Installation>, Report> {
    match fs::read(path()?) {
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

pub fn save(state: &Installation) -> Result<(), Report> {
    let bytes = serde_json::to_vec(state)?;
    let path = path()?;
    fs::create_dir_all(path.parent().unwrap())?;
    let tmp = path.with_extension(format!("{:032x}.tmp", rand::random::<u128>()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)?;
    let result = file.write_all(&bytes).and_then(|()| file.sync_all());
    drop(file);
    let result = result.and_then(|()| fs::rename(&tmp, path));
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    Ok(result?)
}

pub async fn profile_expiry(
    device: &crate::device::Device,
    bundle: &str,
) -> Result<Option<String>, Report> {
    use idevice::{IdeviceService, misagent::MisagentClient};
    let mut service = MisagentClient::connect(&device.provider()).await?;
    let date = service
        .copy_all()
        .await?
        .iter()
        .filter_map(|bytes| crate::profile::Profile::parse(bytes).ok())
        .filter(|profile| {
            profile
                .application_identifier()
                .and_then(|id| id.split_once('.'))
                .is_some_and(|(_, id)| id == bundle)
        })
        .filter_map(|profile| profile.expires())
        .max();
    Ok(date.map(|date| plist::Date::from(date).to_xml_format()))
}
