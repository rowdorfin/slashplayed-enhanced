// Credentials on the way to the device. The owner's rule (CLAUDE.md, "Pairing records are credentials"): a
// pairing record goes from memory to the device's container, never through a log; where one has to touch
// the disk it's a file only this user can read, zeroed, then deleted. This tool pushes it straight from
// memory over AFC (src/device.rs), so the disk is touched only by the scratch folder below, which never
// holds a credential: the unsigned app, the IPA, and the kit.

use std::path::{Path, PathBuf};

use rootcause::prelude::*;

/// A private scratch folder (0700 on Unix; on Windows under the user's own %TEMP%, which only they and
/// administrators can read), deleted with everything in it when dropped.
pub struct Scratch(PathBuf);

impl Scratch {
    pub fn new(label: &str) -> Result<Self, Report> {
        let mut bytes = [0u8; 8];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut bytes);
        let dir = std::env::temp_dir().join(format!("slashplayed-{label}-{}", hex::encode(bytes)));
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&dir)
                .map_err(|e| report!("couldn't make a scratch folder in {}: {e}", std::env::temp_dir().display()))?;
        }
        #[cfg(not(unix))]
        std::fs::create_dir(&dir)
            .map_err(|e| report!("couldn't make a scratch folder in {}: {e}", std::env::temp_dir().display()))?;
        Ok(Self(dir))
    }
    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Redact credential-shaped runs and mask the local part of email addresses.
pub fn sanitize(text: &str) -> String {
    fn word(c: char) -> bool {
        c.is_ascii_alphanumeric() || "+/=_-".contains(c)
    }
    fn email_word(c: char) -> bool {
        word(c) || c.is_alphanumeric() || "._%@".contains(c)
    }

    let mut output = String::with_capacity(text.len());
    for mut part in text.split_inclusive(|c| !email_word(c)) {
        if let Some((local, rest)) = part.split_once('@')
            && !local.is_empty()
            && rest.starts_with(|c: char| c.is_alphanumeric())
        {
            let domain_end = rest.find(|c: char| !c.is_alphanumeric() && c != '.' && c != '-').unwrap_or(rest.len());
            output.push_str("***@");
            output.push_str(&rest[..domain_end]);
            part = &rest[domain_end..];
        }
        for run in part.split_inclusive(|c| !word(c)) {
            let value = run.trim_end_matches(|c| !word(c));
            let digits = value.trim_start_matches('-');
            if value.len() >= 24
                || ((digits.len() == 6 || digits.len() >= 8) && digits.bytes().all(|b| b.is_ascii_digit()))
            {
                output.push_str("<redacted>");
                output.push_str(&run[value.len()..]);
            } else {
                output.push_str(run);
            }
        }
    }
    output
}

/// Format report contexts without attachments, URLs from HTTP errors, or server-supplied error bodies.
pub fn safe_error(e: &Report) -> String {
    let text = e.iter_reports()
        .map(|n| {
            if let Some(error) = n.downcast_current_context::<isideload::SideloadError>() {
                match error {
                    isideload::SideloadError::AuthWithMessage(code, _) => return format!("Erro de autenticação Apple ({code})"),
                    isideload::SideloadError::DeveloperError(code, _) => return format!("Erro do Apple Developer ({code})"),
                    isideload::SideloadError::PlistParseError(_) => return "Resposta plist inválida.".into(),
                    _ => {}
                }
            }
            if let Some(error) = n.downcast_current_context::<reqwest::Error>() {
                return match error.status() {
                    Some(status) => format!("HTTP {}", status.as_u16()),
                    None if error.is_timeout() => "Tempo limite da requisição HTTP.".into(),
                    None => "Falha na requisição HTTP.".into(),
                };
            }
            let context = n.format_current_context().to_string();
            // Older isideload 2FA errors embed server text directly in the context.
            for prefix in ["SMS 2FA request failed", "SMS 2FA code submission failed",
                "Failed to retrieve trusted phone numbers", "Unsupported SRP protocol selected",
                "Failed to deserialize plist struct", "WS connect failed", "WS send failed", "WS close failed",
            ]
            {
                if context.starts_with(prefix) {
                    return prefix.into();
                }
            }
            context.trim().to_owned()
        })
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(": ");
    sanitize(&text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_sensitive_apple_error_text() {
        let raw = "HTTP 401 amy+work@example.com ABCDEFGHIJKLMNOPQRSTUVWXYZ+/== 00112233445566778899aabb 123456 1234567890 -22411";
        assert_eq!(sanitize(raw), "HTTP 401 ***@example.com <redacted> <redacted> <redacted> <redacted> -22411");
        let error = report!(isideload::SideloadError::DeveloperError(1100, "fake-short-secret".into())).into_dynamic();
        assert_eq!(safe_error(&error), "Erro do Apple Developer (1100)");
    }

    #[test]
    fn scratch_is_private_and_goes_away() {
        let s = Scratch::new("test").unwrap();
        let p = s.path().to_path_buf();
        std::fs::write(p.join("f"), b"x").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o700);
        }
        drop(s);
        assert!(!p.exists());
    }
}
