use rootcause::prelude::*;
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::Path};

pub fn normalize(hash: &str) -> Result<String, Report> {
    let hash = hash.trim();
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("SHA-256 inválido. Informe 64 dígitos hexadecimais.");
    }
    Ok(hash.to_ascii_lowercase())
}

pub fn expected(sums: &str, name: &str) -> Result<String, Report> {
    let mut matches = sums.lines().filter_map(|line| {
        let (hash, file) = line.split_once(char::is_whitespace)?;
        let file = file.trim_start().trim_start_matches('*');
        (file.strip_prefix("./").unwrap_or(file) == name).then_some(hash)
    });
    let hash = matches.next().ok_or_else(|| report!("O SHA256SUMS não contém uma entrada para o ZIP."))?;
    if matches.next().is_some() {
        bail!("O SHA256SUMS contém entradas repetidas para o ZIP.");
    }
    normalize(hash)
}

pub fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub fn check_file(path: &Path, pasted: &str) -> Result<(String, bool, bool), Report> {
    let name = path.file_name().and_then(|s| s.to_str()).ok_or_else(|| report!("Informe um caminho de ZIP válido."))?;
    let sidecar = match fs::read_to_string(path.with_file_name("SHA256SUMS")) {
        Ok(sums) => Some(expected(&sums, name)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(e).context("Falha ao ler SHA256SUMS")?,
    };
    let pasted = (!pasted.trim().is_empty()).then(|| normalize(pasted)).transpose()?;
    let mut hasher = Sha256::new();
    let mut file = fs::File::open(path)?;
    let mut buffer = [0; 64 * 1024];
    loop {
        let len = file.read(&mut buffer)?;
        if len == 0 { break; }
        hasher.update(&buffer[..len]);
    }
    let hash = hex::encode(hasher.finalize());
    let matched = [&pasted, &sidecar].into_iter().flatten().all(|want| *want == hash);
    Ok((hash, pasted.is_some() || sidecar.is_some(), matched))
}
