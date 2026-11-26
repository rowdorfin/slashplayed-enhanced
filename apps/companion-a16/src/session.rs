use std::{
    fmt,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rootcause::prelude::*;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub const VERSION: u32 = 1;
#[cfg(not(windows))]
const SESSION_SERVICE: &str = "com.rowdorfin.slashplayed-a16.session";
const PASSWORD_SERVICE: &str = "com.rowdorfin.slashplayed-a16.password";

#[derive(Serialize, Deserialize)]
pub struct StoredSession {
    pub version: u32,
    pub apple_id: String,
    #[serde(with = "secret_string")]
    pub adsid: Zeroizing<String>,
    #[serde(with = "secret_string")]
    pub token: Zeroizing<String>,
    pub expiry: u64,
    pub duration: u64,
    pub anisette_url: String,
    #[serde(with = "secret_string")]
    pub anisette_state: Zeroizing<String>,
    pub client_info: String,
    pub user_agent: String,
    #[serde(default)]
    pub server_client_info: bool,
    pub team_id: Option<String>,
    pub saved_at: u64,
}

mod secret_string {
    use serde::{Deserialize, Deserializer, Serializer};
    use zeroize::Zeroizing;

    pub fn serialize<S: Serializer>(value: &str, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(value)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Zeroizing<String>, D::Error> {
        String::deserialize(deserializer).map(Zeroizing::new)
    }
}

impl fmt::Debug for StoredSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredSession")
            .field("version", &self.version)
            .field("token", &"<redacted>")
            .field("adsid", &"<redacted>")
            .field("anisette_state", &"<redacted>")
            .field("expiry", &self.expiry)
            .finish_non_exhaustive()
    }
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

impl StoredSession {
    pub fn valid_until(&self) -> Option<String> {
        // Apple sends Unix milliseconds. Bound the date to the ISO calendar.
        (self.expiry > now_ms() && self.expiry < 253_402_300_800_000).then(|| {
            plist::Date::from(UNIX_EPOCH + Duration::from_millis(self.expiry)).to_xml_format()
        })
    }
}

pub trait SessionStore: Sync {
    fn load(&self, apple_id: &str) -> Result<Option<StoredSession>, Report>;
    fn save(&self, session: &StoredSession) -> Result<(), Report>;
    fn delete(&self, apple_id: &str) -> Result<bool, Report>;
    fn load_password(&self, apple_id: &str) -> Result<Option<Zeroizing<String>>, Report>;
    fn save_password(&self, apple_id: &str, password: &str) -> Result<(), Report>;
    fn delete_password(&self, apple_id: &str) -> Result<bool, Report>;
}

trait BlobStore: Sync {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>, Report>;
    fn write(&self, id: &str, bytes: &[u8]) -> Result<(), Report>;
    fn remove(&self, id: &str) -> Result<bool, Report>;
}

struct Store<S, P> {
    sessions: S,
    passwords: P,
}

impl<S: BlobStore, P: BlobStore> SessionStore for Store<S, P> {
    fn load(&self, apple_id: &str) -> Result<Option<StoredSession>, Report> {
        let id = apple_id.to_lowercase();
        let Some(bytes) = self.sessions.read(&id)? else {
            return Ok(None);
        };
        match serde_json::from_slice::<StoredSession>(&bytes) {
            Ok(session) if session.version == VERSION && session.apple_id.to_lowercase() == id => Ok(Some(session)),
            _ => {
                self.sessions.remove(&id)?;
                Ok(None)
            }
        }
    }

    fn save(&self, session: &StoredSession) -> Result<(), Report> {
        let bytes = Zeroizing::new(serde_json::to_vec(session)?);
        self.sessions.write(&session.apple_id.to_lowercase(), &bytes)
    }

    fn delete(&self, apple_id: &str) -> Result<bool, Report> {
        self.sessions.remove(&apple_id.to_lowercase())
    }

    fn load_password(&self, apple_id: &str) -> Result<Option<Zeroizing<String>>, Report> {
        self.passwords.read(&apple_id.to_lowercase())?.map(|bytes| {
            std::str::from_utf8(&bytes).map(|s| Zeroizing::new(s.to_owned()))
                .map_err(|_| report!("Senha guardada inválida."))
        }).transpose()
    }

    fn save_password(&self, apple_id: &str, password: &str) -> Result<(), Report> {
        self.passwords.write(&apple_id.to_lowercase(), password.as_bytes())
    }

    fn delete_password(&self, apple_id: &str) -> Result<bool, Report> {
        self.passwords.remove(&apple_id.to_lowercase())
    }
}

pub fn system_store() -> impl SessionStore {
    #[cfg(windows)]
    let sessions = Directory {
        root: std::env::var_os("LOCALAPPDATA").map(|p| std::path::PathBuf::from(p).join("SlashplayedA16").join("sessions")),
        protect: |bytes| dpapi(bytes, true),
        unprotect: |bytes| dpapi(bytes, false),
    };
    #[cfg(not(windows))]
    let sessions = Keyring(SESSION_SERVICE);
    Store { sessions, passwords: Keyring(PASSWORD_SERVICE) }
}

pub fn logout(
    store: &dyn SessionStore,
    apple_id: &str,
    forget_key: bool,
    delete_key: impl FnOnce(&str) -> Result<bool, Report>,
) -> Result<(), Report> {
    let session = store.delete(apple_id);
    let password = store.delete_password(apple_id);
    let key = if forget_key { delete_key(apple_id) } else { Ok(false) };
    session?;
    password?;
    key?;
    Ok(())
}

struct Keyring(&'static str);

impl Keyring {
    fn access<T: Send + 'static>(
        &self, id: &str, action: impl FnOnce(keyring::Entry) -> Result<T, keyring::Error> + Send + 'static,
    ) -> Result<T, Report> {
        let (id, service) = (id.to_owned(), self.0);
        crate::keystore::off_runtime(move || keyring::Entry::new(service, &id).and_then(action))
            .map_err(|_| report!("Falha ao acessar o gerenciador de credenciais."))
    }
}

impl BlobStore for Keyring {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>, Report> {
        self.access(id, |entry| match entry.get_secret() {
            Ok(bytes) => Ok(Some(Zeroizing::new(bytes))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e),
        })
    }

    fn write(&self, id: &str, bytes: &[u8]) -> Result<(), Report> {
        let bytes = Zeroizing::new(bytes.to_vec());
        self.access(id, move |entry| entry.set_secret(&bytes))
    }

    fn remove(&self, id: &str) -> Result<bool, Report> {
        self.access(id, |entry| match entry.delete_credential() {
            Ok(()) => Ok(true),
            Err(keyring::Error::NoEntry) => Ok(false),
            Err(e) => Err(e),
        })
    }
}

#[cfg(any(windows, test))]
type Transform = fn(&[u8]) -> Result<Zeroizing<Vec<u8>>, Report>;

#[cfg(any(windows, test))]
struct Directory {
    root: Option<std::path::PathBuf>,
    protect: Transform,
    unprotect: Transform,
}

#[cfg(any(windows, test))]
impl Directory {
    fn path(&self, id: &str) -> Result<std::path::PathBuf, Report> {
        use sha2::{Digest, Sha256};
        let root = self.root.as_ref().ok_or_else(|| report!("LOCALAPPDATA indisponível."))?;
        Ok(root.join(format!("{}.bin", hex::encode(Sha256::digest(id.as_bytes())))))
    }
}

#[cfg(any(windows, test))]
impl BlobStore for Directory {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>, Report> {
        match std::fs::read(self.path(id)?) {
            Ok(bytes) => (self.unprotect)(&bytes).map(Some),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn write(&self, id: &str, bytes: &[u8]) -> Result<(), Report> {
        use std::io::Write;
        let path = self.path(id)?;
        std::fs::create_dir_all(path.parent().unwrap())?;
        let encrypted = (self.protect)(bytes)?;
        let tmp = path.with_extension(format!("{:032x}.tmp", rand::random::<u128>()));
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        let result = file.write_all(&encrypted).and_then(|()| file.sync_all());
        drop(file);
        let result = result.and_then(|()| std::fs::rename(&tmp, path));
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result.map_err(Into::into)
    }

    fn remove(&self, id: &str) -> Result<bool, Report> {
        match std::fs::remove_file(self.path(id)?) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(windows)]
fn dpapi(bytes: &[u8], protect: bool) -> Result<Zeroizing<Vec<u8>>, Report> {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData},
    };
    use zeroize::Zeroize;

    let input = CRYPT_INTEGER_BLOB { cbData: bytes.len().try_into()?, pbData: bytes.as_ptr().cast_mut() };
    let entropy = b"com.rowdorfin.slashplayed-a16.session.v1";
    let entropy = CRYPT_INTEGER_BLOB { cbData: entropy.len() as u32, pbData: entropy.as_ptr().cast_mut() };
    let mut output = CRYPT_INTEGER_BLOB::default();
    // DPAPI reads the inputs and allocates the output with LocalAlloc.
    let ok = unsafe {
        if protect {
            CryptProtectData(&input, null(), &entropy, null(), null(), CRYPTPROTECT_UI_FORBIDDEN, &mut output)
        } else {
            CryptUnprotectData(&input, null_mut(), &entropy, null(), null(), CRYPTPROTECT_UI_FORBIDDEN, &mut output)
        }
    };
    if ok == 0 {
        return Err(std::io::Error::last_os_error()).context("Falha na proteção DPAPI da sessão")?;
    }
    if output.pbData.is_null() {
        return Ok(Zeroizing::new(Vec::new()));
    }
    // Copy while the allocation is live, then clear and release it.
    unsafe {
        let data = std::slice::from_raw_parts_mut(output.pbData, output.cbData as usize);
        let bytes = Zeroizing::new(data.to_vec());
        data.zeroize();
        LocalFree(output.pbData.cast());
        Ok(bytes)
    }
}

#[cfg(test)]
pub(crate) mod test_store {
    use super::*;
    use std::{collections::HashMap, sync::Mutex};

    #[derive(Default)]
    struct Memory(Mutex<HashMap<String, Zeroizing<Vec<u8>>>>);

    impl BlobStore for Memory {
        fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>, Report> {
            Ok(self.0.lock().unwrap().get(id).cloned())
        }

        fn write(&self, id: &str, bytes: &[u8]) -> Result<(), Report> {
            self.0.lock().unwrap().insert(id.into(), Zeroizing::new(bytes.to_vec()));
            Ok(())
        }

        fn remove(&self, id: &str) -> Result<bool, Report> {
            Ok(self.0.lock().unwrap().remove(id).is_some())
        }
    }

    pub fn memory_store() -> impl SessionStore {
        Store { sessions: Memory::default(), passwords: Memory::default() }
    }

    pub fn sample(apple_id: &str) -> StoredSession {
        StoredSession {
            version: VERSION,
            apple_id: apple_id.into(),
            adsid: Zeroizing::new("fake-adsid".into()),
            token: Zeroizing::new("fake-xcode-token".into()),
            expiry: now_ms() + 86_400_000,
            duration: 86_400,
            anisette_url: "https://anisette.example".into(),
            anisette_state: Zeroizing::new("fake-adi".repeat(500)),
            client_info: "test-client".into(),
            user_agent: "test-agent".into(),
            server_client_info: false,
            team_id: Some("T2".into()),
            saved_at: now_ms(),
        }
    }

    fn directory(root: &std::path::Path) -> Store<Directory, Memory> {
        Store {
            sessions: Directory {
                root: Some(root.into()),
                protect: |bytes| Ok(Zeroizing::new(bytes.to_vec())),
                unprotect: |bytes| Ok(Zeroizing::new(bytes.to_vec())),
            },
            passwords: Memory::default(),
        }
    }

    #[test]
    fn directory_round_trip_and_replace() {
        let tmp = tempfile::tempdir().unwrap();
        let store = directory(tmp.path());
        let mut original = sample("X@example.com");
        store.save(&original).unwrap();
        original.team_id = Some("T1".into());
        store.save(&original).unwrap();
        let stored = store.load("x@example.com").unwrap().unwrap();
        let expected = Zeroizing::new(serde_json::to_vec(&original).unwrap());
        let actual = Zeroizing::new(serde_json::to_vec(&stored).unwrap());
        assert!(*actual == *expected);
        assert_eq!(std::fs::read_dir(tmp.path()).unwrap().count(), 1);
    }

    #[test]
    fn directory_discards_corrupt_json_and_unknown_versions() {
        let tmp = tempfile::tempdir().unwrap();
        let store = directory(tmp.path());
        let id = "x@example.com";
        let path = store.sessions.path(id).unwrap();
        std::fs::write(&path, "{").unwrap();
        assert!(store.load(id).unwrap().is_none());
        assert!(!path.exists());
        let mut unknown = sample(id);
        unknown.version += 1;
        store.save(&unknown).unwrap();
        assert!(store.load(id).unwrap().is_none());
        assert!(!path.exists());
    }

    #[test]
    fn debug_redacts_credentials() {
        let stored = sample("x@example.com");
        let text = format!("{stored:?}");
        for secret in [&stored.token, &stored.adsid, &stored.anisette_state] {
            assert!(!text.contains(secret.as_str()));
        }
        assert_eq!(text.matches("<redacted>").count(), 3);
    }

    #[test]
    fn logout_only_deletes_signing_key_when_requested() {
        let id = "x@example.com";
        let store = memory_store();
        store.save(&sample(id)).unwrap();
        store.save_password(id, &crate::flow::fake::password()).unwrap();
        logout(&store, id, false, |_| panic!("signing key must remain")).unwrap();
        assert!(store.load(id).unwrap().is_none());
        assert!(store.load_password(id).unwrap().is_none());
        let mut called = false;
        logout(&store, id, true, |key_id| {
            called = key_id == id;
            Ok(true)
        }).unwrap();
        assert!(called);
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip() {
        let data = vec![42; 4096];
        let encrypted = dpapi(&data, true).unwrap();
        assert!(*encrypted != data);
        assert!(*dpapi(&encrypted, false).unwrap() == data);
    }
}
