use std::ffi::{CStr, CString, c_char};

unsafe extern "C" {
    fn companion_run();
    fn companion_voice_check();
    fn companion_native_tests() -> i32;
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
        desktop_companion::Intent::Unknown => c"unsupported request (no action)",
    }
    .as_ptr()
}

/// Return a locally generated reply owned by the native caller.
///
/// # Safety
/// `input` must be null or a live NUL-terminated UTF-8 string for this call.
/// Copy the returned string, then release it with `companion_reply_free` once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_reply(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return CString::new("No input received.").unwrap().into_raw();
    }
    // SAFETY: the bridge passes a live, NUL-terminated UTF-8 NSString during this call.
    let input = unsafe { CStr::from_ptr(input) }.to_string_lossy();
    CString::new(desktop_companion::respond(&input))
        .unwrap()
        .into_raw()
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
        Some("--native-self-test") => std::process::exit(unsafe { companion_native_tests() }),
        Some("--help" | "-h") => println!(
            "Mica — Desktop Companion\nRun the .app bundle for the floating UI and permission identity.\n--ask COMMAND   Run a read-only local command\n--voice-check   Report recognition capability; no prompts or capture"
        ),
        None => unsafe { companion_run() },
        _ => {
            eprintln!("Unknown option; use --help.");
            std::process::exit(2);
        }
    }
}
