use std::ffi::{CStr, CString, c_char};
use std::sync::atomic::{AtomicBool, Ordering};
static SUPPRESS_KEYCHAIN_RESTORE: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn companion_run();
    fn companion_voice_check();
    fn companion_native_tests() -> i32;
    fn mica_keychain_policy_tests() -> i32;
}

/// Return the matched command name as a static C string.
///
/// # Safety
/// `input` must be null or a live NUL-terminated string during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_match(input: *const c_char) -> *const c_char {
    if input.is_null() {
        return c"unsupported request (no action)".as_ptr();
    }
    let value = unsafe { CStr::from_ptr(input) }.to_string_lossy();
    match desktop_companion::parse(&value) {
        desktop_companion::Intent::Help => c"help",
        desktop_companion::Intent::Mac => c"Mac status",
        desktop_companion::Intent::Pi => c"Pi sync status (local)",
        desktop_companion::Intent::Time => c"time",
        desktop_companion::Intent::Capabilities => c"capabilities",
        desktop_companion::Intent::Unknown => c"OpenAI text route (only if enabled)",
    }
    .as_ptr()
}

/// Return a JSON reply envelope owned by the native caller.
///
/// # Safety
/// `input` must be null or a live NUL-terminated UTF-8 string for this call.
/// Copy the returned string, then release it with `companion_reply_free` once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_reply(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return CString::new(
            r#"{"text":"No input received.","source":"Input not sent","usage":"No API request."}"#,
        )
        .unwrap()
        .into_raw();
    }
    // SAFETY: the bridge passes a live, NUL-terminated UTF-8 NSString during this call.
    let input = unsafe { CStr::from_ptr(input) }.to_string_lossy();
    let reply = desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .dispatch(&input);
    CString::new(serde_json::to_string(&reply).unwrap())
        .unwrap()
        .into_raw()
}

/// Text-in, optional audio-out reply. No microphone data crosses this boundary.
/// # Safety
/// Both string pointers must be valid NUL-terminated strings during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_reply_with_voice(
    input: *const c_char,
    voice: *const c_char,
    ticket: u64,
) -> *mut c_char {
    if input.is_null() || voice.is_null() {
        return unsafe { companion_reply(input) };
    }
    let text = unsafe { CStr::from_ptr(input) }.to_string_lossy();
    let voice = unsafe { CStr::from_ptr(voice) }.to_string_lossy();
    let reply = desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .dispatch_audio(&text, Some(&voice), ticket);
    CString::new(serde_json::to_string(&reply).unwrap())
        .unwrap()
        .into_raw()
}
#[unsafe(no_mangle)]
pub extern "C" fn companion_audio_cancel() {
    desktop_companion::voice::cancel();
}
#[unsafe(no_mangle)]
pub extern "C" fn companion_audio_generation() -> u64 {
    desktop_companion::voice::generation()
}

/// Configure an explicitly user-entered session key; never persists it.
/// # Safety
/// Both pointers must be live NUL-terminated strings for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ai_configure(
    key: *const c_char,
    model: *const c_char,
    cap: u32,
) -> *mut c_char {
    if key.is_null() || model.is_null() {
        return CString::new("Missing AI settings. No request sent.")
            .unwrap()
            .into_raw();
    }
    let key = unsafe { CStr::from_ptr(key) }
        .to_string_lossy()
        .into_owned();
    let model = unsafe { CStr::from_ptr(model) }.to_string_lossy();
    let result = desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .configure(key, &model, cap);
    CString::new(result.err().unwrap_or_default())
        .unwrap()
        .into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn companion_ai_status() -> *mut c_char {
    let public = desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .public_status();
    let mut value: serde_json::Value = serde_json::from_str(&public).unwrap();
    let controller = desktop_companion::persistence::controller().lock().unwrap();
    value["saved_model"] = serde_json::json!(controller.prefs.model);
    value["saved_cap"] = serde_json::json!(controller.prefs.cap);
    value["auto_enable"] = serde_json::json!(controller.prefs.auto_enable);
    value["key_saved"] = serde_json::json!(controller.prefs.key_saved);
    value["persistence_notice"] = serde_json::json!(controller.notice);
    CString::new(value.to_string()).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn companion_persistence_startup() -> *mut c_char {
    let mut c = desktop_companion::persistence::controller().lock().unwrap();
    let result = c.restore_key(SUPPRESS_KEYCHAIN_RESTORE.load(Ordering::Relaxed));
    let message = match result {
        Ok(Some(key)) => desktop_companion::runtime::session()
            .lock()
            .unwrap()
            .configure(key.to_string(), &c.prefs.model, c.prefs.cap)
            .err()
            .unwrap_or_else(|| "Saved AI startup preference restored. No request sent.".into()),
        Ok(None) => {
            if c.notice.is_empty() {
                "AI is off. Saved settings loaded without reading a key.".into()
            } else {
                c.notice.clone()
            }
        }
        Err(error) => error,
    };
    CString::new(message).unwrap().into_raw()
}

/// Save non-secret preferences and optionally a user-entered Keychain key.
/// # Safety
/// Pointers must be live NUL-terminated UTF-8 strings during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_ai_save(
    key: *const c_char,
    model: *const c_char,
    cap: u32,
    remember: u8,
    auto: u8,
    enable: u8,
) -> *mut c_char {
    if key.is_null() || model.is_null() {
        return CString::new("Missing settings. No request sent.")
            .unwrap()
            .into_raw();
    }
    let key = zeroize::Zeroizing::new(
        unsafe { CStr::from_ptr(key) }
            .to_string_lossy()
            .into_owned(),
    );
    let model = unsafe { CStr::from_ptr(model) }.to_string_lossy();
    desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .disable();
    let mut c = desktop_companion::persistence::controller().lock().unwrap();
    let result = desktop_companion::persistence::apply_settings(
        &mut c,
        &mut desktop_companion::runtime::session().lock().unwrap(),
        desktop_companion::persistence::ApplyOptions {
            key: &key,
            model: &model,
            cap,
            remember: remember != 0,
            auto: auto != 0,
            enable: enable != 0,
        },
    );
    let message = result.unwrap_or_else(|error: String| {
        c.notice = error.clone();
        desktop_companion::runtime::session()
            .lock()
            .unwrap()
            .disable_with_reason(error.clone());
        error
    });
    CString::new(message).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn companion_ai_remove_saved() -> *mut c_char {
    desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .disable();
    let result = desktop_companion::persistence::controller()
        .lock()
        .unwrap()
        .remove();
    CString::new(result.err().unwrap_or_else(|| {
        "Saved Micah key removed. AI and saved startup enablement are off.".into()
    }))
    .unwrap()
    .into_raw()
}
#[unsafe(no_mangle)]
pub extern "C" fn companion_ai_disable() {
    desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .disable();
}
#[unsafe(no_mangle)]
pub extern "C" fn companion_ai_clear() {
    desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .clear_history();
}

#[unsafe(no_mangle)]
pub extern "C" fn companion_ai_session_enabled() -> u8 {
    let state = desktop_companion::runtime::session()
        .lock()
        .unwrap()
        .public_status();
    serde_json::from_str::<serde_json::Value>(&state).unwrap()["enabled"]
        .as_bool()
        .unwrap_or(false) as u8
}

#[unsafe(no_mangle)]
/// Release the reply allocated by `companion_reply`.
///
/// # Safety
/// `value` must be null or an unfreed pointer returned by `companion_reply`.
pub unsafe extern "C" fn companion_reply_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: pointer came from companion_reply and is freed only once by the bridge.
        drop(unsafe { CString::from_raw(value) });
    }
}

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str) {
        Some("--ask") => println!("{}", desktop_companion::respond(&args[1..].join(" "))),
        Some("--voice-check") => unsafe { companion_voice_check() },
        Some("--native-self-test") => {
            std::process::exit(unsafe { companion_native_tests() + mica_keychain_policy_tests() })
        }
        Some("--no-keychain-restore") => {
            SUPPRESS_KEYCHAIN_RESTORE.store(true, Ordering::Relaxed);
            unsafe { companion_run() };
        }
        Some("--help" | "-h") => println!(
            "Micah — Desktop Companion\nRun the .app bundle for the floating UI and permission identity.\n--ask COMMAND   Run a read-only local command\n--voice-check   Report recognition capability; no prompts or capture"
        ),
        None => unsafe { companion_run() },
        _ => {
            eprintln!("Unknown option; use --help.");
            std::process::exit(2);
        }
    }
}
