//! Only non-secret preferences go to disk. Password bytes belong to Keychain.
use crate::ai;
use serde::{Deserialize, Serialize};
use std::{
    ffi::c_char,
    fs,
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
use zeroize::Zeroizing;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Preferences {
    pub version: u8,
    pub model: String,
    pub cap: u32,
    pub auto_enable: bool,
    pub key_saved: bool,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            version: 1,
            model: ai::DEFAULT_MODEL.into(),
            cap: ai::DEFAULT_CAP,
            auto_enable: false,
            key_saved: false,
        }
    }
}
impl Preferences {
    pub fn validate(&self) -> Result<(), String> {
        if self.version != 1 {
            return Err("Unsupported saved settings version. AI remains off.".into());
        }
        ai::validate_model_cap(&self.model, self.cap)
    }
}
pub trait Store {
    fn load_preferences(&mut self) -> Result<Preferences, String>;
    fn save_preferences(&mut self, prefs: &Preferences) -> Result<(), String>;
    fn put_key(&mut self, key: &str) -> Result<(), String>;
    fn get_key(&mut self) -> Result<Option<Zeroizing<String>>, String>;
    fn delete_key(&mut self) -> Result<(), String>;
}
pub struct Controller<S: Store> {
    pub store: S,
    pub prefs: Preferences,
    pub notice: String,
}
impl<S: Store> Controller<S> {
    pub fn new(mut store: S) -> Self {
        let loaded = store.load_preferences().and_then(|p| {
            p.validate()?;
            Ok(p)
        });
        match loaded {
            Ok(prefs) => Self {
                store,
                prefs,
                notice: String::new(),
            },
            Err(notice) => Self {
                store,
                prefs: Preferences::default(),
                notice,
            },
        }
    }
    /// Saving never reads a key and never enables AI or makes a request.
    pub fn save(
        &mut self,
        model: &str,
        cap: u32,
        auto: bool,
        key: &str,
        remember: bool,
    ) -> Result<(), String> {
        ai::validate_model_cap(model, cap)?;
        let saving_new_key = remember && !key.is_empty();
        let startup_key_available = self.prefs.key_saved || saving_new_key;
        if auto && (!startup_key_available || (!key.is_empty() && !remember)) {
            return Err("Enable-at-launch requires a saved Keychain key. Select Save/replace key when entering a new key.".into());
        }
        if remember && key.is_empty() && !self.prefs.key_saved {
            return Err("Enter a key to save in Keychain, or leave Save/replace unchecked.".into());
        }
        let mut prefs = Preferences {
            version: 1,
            model: model.into(),
            cap,
            auto_enable: auto,
            key_saved: self.prefs.key_saved,
        };
        if remember && !key.is_empty() {
            // Validate without persisting or exposing the secret in diagnostics.
            ai::Settings::new(key.into(), model, cap)?;
            self.store.put_key(key)?;
            prefs.key_saved = true;
        }
        if let Err(error) = self.store.save_preferences(&prefs) {
            if remember && !key.is_empty() {
                self.prefs.key_saved = true;
                return Err(format!(
                    "Keychain updated, but non-secret settings were not saved: {error} You may retry Save without replacing the key."
                ));
            }
            return Err(error);
        }
        self.prefs = prefs;
        self.notice.clear();
        Ok(())
    }
    pub fn enable_key(&mut self, typed: &str) -> Result<Zeroizing<String>, String> {
        if !typed.is_empty() {
            return Ok(Zeroizing::new(typed.into()));
        }
        self.store.get_key()?.ok_or_else(|| {
            "No saved Mica OpenAI key found. Enter your key yourself and select Save/replace."
                .into()
        })
    }
    pub fn remove(&mut self) -> Result<(), String> {
        self.store.delete_key()?; // Exact service/account; never a broad Keychain delete.
        self.prefs.key_saved = false;
        self.prefs.auto_enable = false;
        self.store.save_preferences(&self.prefs).map_err(|e| {
            format!("Saved key removed, but settings could not be updated: {e} AI is off.")
        })
    }
    pub fn restore_key(&mut self, suppressed: bool) -> Result<Option<Zeroizing<String>>, String> {
        if suppressed || !self.prefs.auto_enable {
            return Ok(None);
        }
        self.enable_key("").map(Some)
    }
}

unsafe extern "C" {
    fn mica_keychain_put(key: *const c_char) -> i32;
    fn mica_keychain_get(value: *mut *mut c_char) -> i32;
    fn mica_keychain_delete() -> i32;
    fn mica_secret_free(value: *mut c_char);
}
pub fn keychain_error(code: i32) -> String {
    let reason = match code {
        -25293 => "access denied",
        -25308 => "Keychain interaction required or device locked",
        -34018 => "signing entitlement/access-group unavailable",
        -128 => "operation canceled",
        _ => "Keychain operation failed",
    };
    format!("{reason} (OSStatus {code}). No plaintext fallback.")
}

/// Enabling with a valid typed key is independent of optional persistence.
/// No API request occurs here; an unavailable Keychain cannot block session use.
pub struct ApplyOptions<'a> {
    pub key: &'a str,
    pub model: &'a str,
    pub cap: u32,
    pub remember: bool,
    pub auto: bool,
    pub enable: bool,
}
pub fn apply_settings<S: Store>(
    c: &mut Controller<S>,
    session: &mut crate::runtime::Session,
    options: ApplyOptions<'_>,
) -> Result<String, String> {
    let ApplyOptions {
        key,
        model,
        cap,
        remember,
        auto,
        enable,
    } = options;
    session.disable();
    ai::validate_model_cap(model, cap)?;
    if !key.is_empty() {
        ai::Settings::new(key.into(), model, cap)?;
    }
    let saved = c.save(model, cap, auto, key, remember);
    if enable {
        let selected = c.enable_key(key)?;
        session.configure(selected.to_string(), model, cap)?;
        match saved {
            Ok(()) => {
                Ok("AI is enabled. Settings saved. No API request sent; use Send manually.".into())
            }
            Err(error) => {
                c.notice = error.clone();
                Ok(format!(
                    "AI is enabled for this session. Key/settings were not saved: {error}\nYour entered key remains only in memory for this session. No API request sent."
                ))
            }
        }
    } else {
        saved?;
        Ok("Settings saved. AI is off. Enable explicitly when ready.".into())
    }
}
pub struct MacStore {
    pub path: PathBuf,
}
impl Default for MacStore {
    fn default() -> Self {
        Self {
            path: std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_default()
                .join("Library/Application Support/Mica/settings.json"),
        }
    }
}
impl Store for MacStore {
    fn load_preferences(&mut self) -> Result<Preferences, String> {
        for path in [
            self.path.parent().ok_or("Invalid settings path")?,
            self.path.as_path(),
        ] {
            if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
                return Err(
                    "Refusing symbolic-link settings. AI remains off; no key was read.".into(),
                );
            }
        }
        let file = match fs::File::open(&self.path) {
            Ok(v) => v,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Preferences::default()),
            Err(_) => return Err("Could not read non-secret Mica settings. AI remains off.".into()),
        };
        let mut bytes = Vec::new();
        file.take(16 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "Could not read saved settings.".to_string())?;
        if bytes.len() > 16 * 1024 {
            return Err("Saved settings exceed the size limit. AI remains off.".into());
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| "Saved settings are invalid. AI remains off; no key was read.".into())
    }
    fn save_preferences(&mut self, prefs: &Preferences) -> Result<(), String> {
        prefs.validate()?;
        let parent = self.path.parent().ok_or("Invalid settings path")?;
        fs::create_dir_all(parent)
            .map_err(|_| "Could not create Mica settings directory.".to_string())?;
        if fs::symlink_metadata(parent)
            .map_err(|_| "Could not inspect settings directory")?
            .file_type()
            .is_symlink()
        {
            return Err("Refusing a symbolic-link settings directory.".into());
        }
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "Clock unavailable")?
            .as_nanos();
        let temp = parent.join(format!(".settings-{}-{nonce}.tmp", std::process::id()));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp)
                .map_err(|_| "Could not create private settings file")?;
            let bytes =
                serde_json::to_vec_pretty(prefs).map_err(|_| "Could not encode settings")?;
            file.write_all(&bytes)
                .map_err(|_| "Could not write settings")?;
            file.sync_all().map_err(|_| "Could not flush settings")?;
            fs::rename(&temp, &self.path).map_err(|_| "Could not replace settings file")?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temp);
        }
        result.map_err(str::to_owned)
    }
    fn put_key(&mut self, key: &str) -> Result<(), String> {
        let mut bytes = Zeroizing::new(key.as_bytes().to_vec());
        bytes.push(0);
        let status = unsafe { mica_keychain_put(bytes.as_ptr().cast()) };
        if status == 0 {
            Ok(())
        } else {
            Err(keychain_error(status))
        }
    }
    fn get_key(&mut self) -> Result<Option<Zeroizing<String>>, String> {
        let mut raw = std::ptr::null_mut();
        let status = unsafe { mica_keychain_get(&mut raw) };
        if status == -25300 {
            return Ok(None);
        }
        if status != 0 {
            return Err(keychain_error(status));
        }
        if raw.is_null() {
            return Err("Keychain returned no key data. AI remains off.".into());
        }
        let value = unsafe { std::ffi::CStr::from_ptr(raw) }
            .to_str()
            .map(|s| Zeroizing::new(s.into()))
            .map_err(|_| "Saved key encoding is invalid. AI remains off.".into());
        unsafe { mica_secret_free(raw) };
        value.map(Some)
    }
    fn delete_key(&mut self) -> Result<(), String> {
        let status = unsafe { mica_keychain_delete() };
        if status == 0 || status == -25300 {
            Ok(())
        } else {
            Err(keychain_error(status))
        }
    }
}
pub fn controller() -> &'static Mutex<Controller<MacStore>> {
    static VALUE: OnceLock<Mutex<Controller<MacStore>>> = OnceLock::new();
    VALUE.get_or_init(|| Mutex::new(Controller::new(MacStore::default())))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Fake {
        prefs: Preferences,
        key: Option<String>,
        reads: usize,
        writes: usize,
        fail_put: bool,
        fail_get: bool,
        fail_delete: bool,
        fail_prefs: bool,
    }
    impl Store for Fake {
        fn load_preferences(&mut self) -> Result<Preferences, String> {
            Ok(self.prefs.clone())
        }
        fn save_preferences(&mut self, p: &Preferences) -> Result<(), String> {
            if self.fail_prefs {
                Err("fixture disk error".into())
            } else {
                self.prefs = p.clone();
                Ok(())
            }
        }
        fn put_key(&mut self, k: &str) -> Result<(), String> {
            if self.fail_put {
                Err(keychain_error(-25308))
            } else {
                self.key = Some(k.into());
                self.writes += 1;
                Ok(())
            }
        }
        fn get_key(&mut self) -> Result<Option<Zeroizing<String>>, String> {
            self.reads += 1;
            if self.fail_get {
                Err(keychain_error(-25293))
            } else {
                Ok(self.key.clone().map(Zeroizing::new))
            }
        }
        fn delete_key(&mut self) -> Result<(), String> {
            if self.fail_delete {
                Err(keychain_error(-25293))
            } else {
                self.key = None;
                Ok(())
            }
        }
    }
    #[test]
    fn valid_typed_key_enables_even_when_storage_fails() {
        for failure in ["keychain", "preferences"] {
            let mut c = Controller::new(Fake {
                fail_put: failure == "keychain",
                fail_prefs: failure == "preferences",
                ..Fake::default()
            });
            let mut session = crate::runtime::Session::default();
            let result = apply_settings(
                &mut c,
                &mut session,
                ApplyOptions {
                    key: "fixture-only-not-a-secret",
                    model: ai::DEFAULT_MODEL,
                    cap: 128,
                    remember: true,
                    auto: false,
                    enable: true,
                },
            )
            .unwrap();
            assert!(result.contains("AI is enabled for this session"));
            assert!(result.contains("not saved"));
            assert_eq!(c.store.reads, 0);
            assert!(serde_json::from_str::<serde_json::Value>(&session.public_status()).unwrap()["enabled"].as_bool().unwrap());
        }
    }
    #[test]
    fn missing_saved_key_does_not_claim_enable_success() {
        let mut c = Controller::new(Fake::default());
        let mut session = crate::runtime::Session::default();
        assert!(
            apply_settings(
                &mut c,
                &mut session,
                ApplyOptions {
                    key: "",
                    model: ai::DEFAULT_MODEL,
                    cap: 128,
                    remember: false,
                    auto: false,
                    enable: true
                }
            )
            .is_err()
        );
        assert!(!serde_json::from_str::<serde_json::Value>(&session.public_status()).unwrap()["enabled"].as_bool().unwrap());
    }
    #[test]
    fn startup_is_secret_free_unless_user_saved_opt_in() {
        let mut c = Controller::new(Fake::default());
        assert!(c.restore_key(false).unwrap().is_none());
        assert_eq!(c.store.reads, 0);
        c.save(ai::DEFAULT_MODEL, 256, true, "fixture-not-secret", true)
            .unwrap();
        assert_eq!(c.store.reads, 0);
        assert!(c.restore_key(true).unwrap().is_none());
        assert_eq!(c.store.reads, 0);
        assert_eq!(
            c.restore_key(false).unwrap().unwrap().as_str(),
            "fixture-not-secret"
        );
        assert_eq!(c.store.reads, 1);
    }
    #[test]
    fn save_replace_remove_and_settings_do_not_store_secret_in_json() {
        let mut c = Controller::new(Fake::default());
        c.save(ai::DEFAULT_MODEL, 128, false, "first-fixture", true)
            .unwrap();
        c.save(ai::DEFAULT_MODEL, 1024, false, "replacement-fixture", true)
            .unwrap();
        assert_eq!(c.store.writes, 2);
        assert_eq!(c.store.reads, 0);
        let json = serde_json::to_string(&c.prefs).unwrap();
        assert!(!json.contains("fixture"));
        assert!(json.contains("1024"));
        c.remove().unwrap();
        assert!(c.store.key.is_none());
        assert!(!c.prefs.auto_enable);
        assert!(!c.prefs.key_saved);
        c.remove().unwrap();
    }
    #[test]
    fn failures_are_visible_and_never_fall_back_to_plaintext() {
        let mut c = Controller::new(Fake {
            fail_put: true,
            ..Fake::default()
        });
        assert!(
            c.save(ai::DEFAULT_MODEL, 512, false, "fixture", true)
                .is_err()
        );
        assert!(!c.prefs.key_saved);
        c.store.fail_put = false;
        c.store.fail_prefs = true;
        assert!(
            c.save(ai::DEFAULT_MODEL, 512, false, "fixture", true)
                .unwrap_err()
                .contains("Keychain updated")
        );
        c.store.fail_prefs = false;
        c.store.fail_get = true;
        assert!(c.enable_key("").unwrap_err().contains("access denied"));
        c.store.fail_delete = true;
        assert!(c.remove().is_err());
        assert!(c.prefs.key_saved);
        assert!(
            c.save(ai::DEFAULT_MODEL, 0, false, "fixture", true)
                .is_err()
        );
        assert!(
            Controller::new(Fake::default())
                .save(ai::DEFAULT_MODEL, 512, true, "", false)
                .is_err()
        );
    }
    #[test]
    fn nonsecret_file_roundtrip_permissions_and_corruption() {
        use std::os::unix::fs::PermissionsExt;
        let root =
            std::env::temp_dir().join(format!("mica-preferences-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let mut store = MacStore {
            path: root.join("settings.json"),
        };
        let prefs = Preferences {
            cap: 256,
            ..Preferences::default()
        };
        store.save_preferences(&prefs).unwrap();
        assert_eq!(store.load_preferences().unwrap().cap, 256);
        assert_eq!(
            fs::metadata(&store.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::write(&store.path, "invalid fixture").unwrap();
        assert!(store.load_preferences().is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
