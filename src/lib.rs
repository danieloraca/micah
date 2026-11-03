//! Fixed, read-only commands. User input never becomes shell code or arguments.
pub mod ai;
pub mod persistence;
pub mod runtime;
use std::{
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub const HELP: &str = "Hi Dan. I'm Mica. Try: mac status, pi status, time, or capabilities.\n\nLocal commands stay on this Mac. Optional OpenAI text answers can be enabled in AI settings using your key, with optional macOS Keychain saving. API usage is billed separately from ChatGPT. No background recording or automatic submission. Character design can come later.";

#[derive(Debug, PartialEq, Eq)]
pub enum Intent {
    Help,
    Mac,
    Pi,
    Time,
    Capabilities,
    Unknown,
}

/// Keep an exact allowlist after harmless speech formatting normalization.
pub fn normalize(input: &str) -> String {
    input
        .trim_matches(|c: char| {
            c.is_whitespace()
                || matches!(
                    c,
                    '.' | '?' | '!' | ',' | '"' | '\'' | '“' | '”' | '‘' | '’'
                )
        })
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub fn parse(input: &str) -> Intent {
    if input.len() > 2000 {
        return Intent::Unknown;
    }
    match normalize(input).as_str() {
        "help" | "hello" | "hi" | "hey" => Intent::Help,
        "mac" | "mac status" | "max status" | "system status" | "how is my mac" => Intent::Mac,
        "pi" | "pi status" | "pi sync" | "sync status" => Intent::Pi,
        "time" | "what time is it" | "date" => Intent::Time,
        "capabilities" | "voice" | "what can you do" => Intent::Capabilities,
        _ => Intent::Unknown,
    }
}

// Only callers in this module supply fixed program paths and fixed arguments.
// All commands have small output. Drop stdin, bound runtime, kill/reap on timeout.
fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let mut child = Command::new(program)
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Could not run {program}: {e}"))?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < Duration::from_secs(3) => {
                thread::sleep(Duration::from_millis(20))
            }
            result => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(match result {
                    Err(e) => e.to_string(),
                    _ => "Local check timed out after 3 seconds.".into(),
                });
            }
        }
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("Local check unavailable (exit {}).", output.status));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim()
        .chars()
        .take(6000)
        .collect())
}

fn check(program: &str, args: &[&str]) -> String {
    run(program, args).unwrap_or_else(|e| e)
}

pub fn pi_summary(loaded: bool, text: &str) -> String {
    if !loaded {
        return "The local Token Grove Pi sync agent is not loaded, or launchctl could not read it.\n\nThis does not tell me whether the Pi is online. I have not contacted the Pi or restarted anything.".into();
    }
    // Ignore coalition states in nested launchctl dictionaries.
    let mut depth: i32 = 0;
    let mut fields = Vec::new();
    for line in text.lines().map(str::trim) {
        if depth == 1
            && (line.starts_with("state = ")
                || line.starts_with("runs = ")
                || line.starts_with("last exit code = "))
        {
            fields.push(line);
        }
        depth += line.chars().filter(|c| *c == '{').count() as i32;
        depth -= line.chars().filter(|c| *c == '}').count() as i32;
    }
    let fields = fields.join("\n");
    format!(
        "Local Token Grove Pi sync agent: loaded.\n{fields}\n\nThis is launchd's local agent state. A waiting agent may simply be between scheduled runs. Even exit code 0 does not prove Pi reachability or fresh data. No remote service check was performed; no restart or sync was triggered."
    )
}

pub fn respond(input: &str) -> String {
    match parse(input) {
        Intent::Help => HELP.into(),
        Intent::Capabilities => "I can check this Mac's uptime, battery and OS; show local Pi sync agent state; and tell the time. These are read-only local checks.\n\nThe local dispatcher is not a language model. Optional OpenAI answers require explicit user setup; non-command text and up to three previous AI turns are then sent to OpenAI when you press Send. API billing is separate from ChatGPT. No files, codebase, local status results, or audio are automatically uploaded. AI output cannot run tools or actions.\n\nSpeak reply uses an installed macOS system voice on demand. This assistant's exact voice is not included or verified as reusable.\n\nClick-to-talk is experimental: English (US), device-only recognition, permission prompts on first click, 15-second limit, Stop anytime. Unsupported device recognition fails closed. A transcript fills the input for review; press Send yourself. No audio or transcript is saved locally by this app.\n\nThere is no wake word, always-on listening, automatic startup, or remote Pi control.".into(),
        Intent::Mac => format!("Mac status — checked now\n\nUptime: {}\n\nBattery / power:\n{}\n\nmacOS: {}", check("/usr/bin/uptime", &[]), check("/usr/bin/pmset", &["-g", "batt"]), check("/usr/bin/sw_vers", &["-productVersion"])),
        Intent::Time => check("/bin/date", &["+%A, %d %B %Y at %H:%M:%S %Z"]),
        Intent::Pi => {
            match run("/usr/bin/id", &["-u"]) {
                Ok(uid) if uid.chars().all(|c| c.is_ascii_digit()) && !uid.is_empty() => {
                    let target = format!("gui/{uid}/com.tokengrove.sync");
                    match run("/bin/launchctl", &["print", &target]) {
                        Ok(value) => pi_summary(true, &value), Err(_) => pi_summary(false, ""),
                    }
                },
                _ => "Could not determine the current user's launchd domain. No Pi check was performed.".into(),
            }
        },
        Intent::Unknown => "I don't have an offline command for that yet, so I haven't taken any action. Try help, mac status, pi status, time, or capabilities. I'm not connected to an AI model.".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn commands_accept_normal_spoken_punctuation() {
        assert_eq!(parse("  How is my Mac?  "), Intent::Mac);
        assert_eq!(parse("PI STATUS."), Intent::Pi);
        assert_eq!(parse("What time is it?"), Intent::Time);
    }
    #[test]
    fn speech_transcripts_dispatch_to_actions_instead_of_hints() {
        for input in [
            "Time",
            "Time.",
            "“Time.”",
            "\u{a0}time .  ",
            "What  time\nis it?",
        ] {
            assert_eq!(parse(input), Intent::Time, "{input:?}");
            let reply = respond(input);
            assert!(!reply.contains("Try:"));
            assert!(!reply.contains("offline command"));
        }
        // Observed in the actual app after Dan said "Mac status".
        for input in [
            "Max status",
            "Max status.",
            "Mac\u{a0}status.",
            "“Mac status.”",
        ] {
            assert_eq!(parse(input), Intent::Mac, "{input:?}");
            assert!(respond(input).starts_with("Mac status — checked now"));
        }
        for input in [
            "time; help",
            "Mac status && help",
            "time or help",
            "time help",
            "Max status reboot",
        ] {
            assert_eq!(parse(input), Intent::Unknown);
        }
    }
    #[test]
    fn free_text_and_shell_payloads_cannot_execute() {
        for input in [
            "rm -rf ~/Daniel",
            "time; touch /tmp/companion-pwned",
            "$(whoami)",
            "pi status && reboot",
            "open Safari",
            "",
        ] {
            assert_eq!(parse(input), Intent::Unknown);
            assert!(respond(input).contains("haven't taken any action"));
        }
        assert_eq!(parse(&"x".repeat(2001)), Intent::Unknown);
    }
    #[test]
    fn pi_status_never_claims_remote_health() {
        let result = pi_summary(
            true,
            "job = {\nstate = not running\nruns = 34\nlast exit code = 0\nsecret = don't display me\ncoalition = {\nstate = active\n}\n}",
        );
        assert!(result.contains("state = not running"));
        assert!(result.contains("does not prove Pi reachability"));
        assert!(!result.contains("don't display me"));
        assert!(!result.contains("state = active"));
        assert!(pi_summary(false, "").contains("not loaded"));
    }
    #[test]
    fn capabilities_disclose_limits() {
        let text = respond("capabilities");
        assert!(text.contains("not a language model"));
        assert!(text.contains("exact voice is not included"));
        assert!(text.contains("No audio or transcript is saved"));
    }
    #[test]
    fn command_failure_and_timeout_are_reported() {
        assert!(run("/nonexistent/desktop-companion", &[]).is_err());
        assert!(run("/usr/bin/false", &[]).is_err());
        assert!(run("/bin/sleep", &["5"]).unwrap_err().contains("timed out"));
    }
}
