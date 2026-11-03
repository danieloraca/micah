//! In-memory AI state; persistence is a separate, explicit Keychain controller.
use crate::{Intent, ai, parse, respond};
use serde::Serialize;
use serde_json::json;
use std::sync::{Mutex, OnceLock};

#[derive(Serialize)]
pub struct Reply {
    pub text: String,
    pub source: String,
    pub usage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_wav: Option<String>,
}
#[derive(Default)]
pub struct Session {
    settings: Option<ai::Settings>,
    history: ai::History,
    disabled_reason: Option<String>,
}
impl Session {
    pub fn configure(&mut self, key: String, model: &str, cap: u32) -> Result<(), String> {
        self.settings = Some(ai::Settings::new(key, model, cap)?);
        self.history.clear();
        self.disabled_reason = None;
        Ok(())
    }
    pub fn disable(&mut self) {
        self.settings = None;
        self.history.clear();
        self.disabled_reason = None;
    }
    pub fn disable_with_reason(&mut self, reason: String) {
        self.disable();
        self.disabled_reason = Some(reason);
    }
    pub fn clear_history(&mut self) {
        self.history.clear();
    }
    pub fn public_status(&self) -> String {
        let (enabled, model, cap) = self
            .settings
            .as_ref()
            .map(|s| (true, s.model.as_str(), s.cap))
            .unwrap_or((false, ai::DEFAULT_MODEL, ai::DEFAULT_CAP));
        json!({"enabled":enabled,"model":model,"cap":cap,"history_pairs":self.history.len(),"disabled_reason":self.disabled_reason})
            .to_string()
    }
    pub fn dispatch(&mut self, input: &str) -> Reply {
        self.dispatch_audio(input, None, crate::voice::generation())
    }
    pub fn dispatch_audio(&mut self, input: &str, voice: Option<&str>, ticket: u64) -> Reply {
        let intent = parse(input);
        if intent != Intent::Unknown {
            return Reply {
                text: respond(input),
                source: format!("Local · {}", local_label(&intent)),
                usage: "Local command — no API request or API token usage.".into(),
                audio_wav: None,
            };
        }
        if input.trim().is_empty() || input.len() > 2000 {
            return Reply {
                text: "Use 1–2000 UTF-8 bytes of text. No request sent.".into(),
                source: "Input not sent".into(),
                usage: "No API request.".into(),
                audio_wav: None,
            };
        }
        let Some(settings) = self.settings.as_ref() else {
            return Reply {
                text: format!(
                    "AI is off. {}\n\nTry a local command (help, mac status, pi status, time), or open AI settings and choose Enable AI now. Nothing was sent.",
                    self.disabled_reason
                        .as_deref()
                        .unwrap_or("This running instance has not been enabled.")
                ),
                source: "AI off · no action".into(),
                usage: "No API request.".into(),
                audio_wav: None,
            };
        };
        let audio = voice.is_some();
        let model = if audio {
            crate::voice::MODEL
        } else {
            &settings.model
        };
        let route = if audio { "realtime" } else { "responses" };
        let (mut reply, completed, measurement) = if let Some(voice) = voice {
            match crate::voice::ask(settings,&self.history,input,voice,ticket) {
                Ok(answer)=>(Reply{text:answer.text,source:format!("OpenAI audio · {} · {voice} · output cap {}",crate::voice::MODEL,settings.cap),usage:answer.usage,audio_wav:answer.wav},Some(answer.completed),Some(answer.measurement)),
                Err(error)=>(Reply{text:format!("{error}\nSwitch to Mac voice and Send again manually for a text answer. No additional paid fallback request was made."),source:"OpenAI audio request failed".into(),usage:"Audio API usage unavailable. Cost estimate: not calculated; usage may have occurred.".into(),audio_wav:None},None,None),
            }
        } else {
            match ai::ask(settings, &self.history, input) {
                Ok(answer) => (
                    Reply {
                        text: answer.text,
                        source: format!(
                            "OpenAI · {} · output cap {}",
                            settings.model, settings.cap
                        ),
                        usage: answer.usage,
                        audio_wav: None,
                    },
                    Some(answer.completed),
                    Some(answer.measurement),
                ),
                Err(error) => (
                    Reply {
                        text: error,
                        source: "OpenAI request failed".into(),
                        usage: "API-reported tokens: unavailable. Cost estimate: not calculated."
                            .into(),
                        audio_wav: None,
                    },
                    None,
                    None,
                ),
            }
        };
        if completed == Some(true) {
            self.history.push(input, &reply.text);
        }
        if !crate::metering::record(model, route, completed, measurement.as_ref()) {
            reply.usage.push_str("\nLocal usage export failed; this turn may be missing from LLM Usage. No retry was sent.");
        }
        reply
    }
}
pub fn local_label(intent: &Intent) -> &'static str {
    match intent {
        Intent::Help => "help",
        Intent::Mac => "Mac status",
        Intent::Pi => "Pi sync status (local)",
        Intent::Time => "time",
        Intent::Capabilities => "capabilities",
        Intent::Unknown => "OpenAI text (if enabled)",
    }
}
pub fn session() -> &'static Mutex<Session> {
    static SESSION: OnceLock<Mutex<Session>> = OnceLock::new();
    SESSION.get_or_init(|| Mutex::new(Session::default()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credential_free_startup_and_local_commands_never_call_openai() {
        let mut s = Session::default();
        assert!(s.dispatch("Explain a rainbow").text.contains("AI is off"));
        assert!(s.dispatch("Time.").source.starts_with("Local"));
        // A dummy key may enable state but local commands must still bypass HTTP.
        s.configure("fixture-only".into(), ai::DEFAULT_MODEL, 128)
            .unwrap();
        assert!(
            s.dispatch_audio("Time.", Some("marin"), crate::voice::generation())
                .source
                .starts_with("Local")
        );
        assert!(s.dispatch("Max status.").source.starts_with("Local"));
        assert!(s.history.is_empty());
        assert!(!s.public_status().contains("fixture-only"));
        s.disable();
        assert!(s.dispatch("Another question").text.contains("AI is off"));
    }
    #[test]
    fn enable_failures_remain_visible_at_send_without_a_request() {
        let mut s = Session::default();
        s.disable_with_reason("Fixture Keychain access denied (OSStatus -25293).".into());
        assert!(s.dispatch("How are you").text.contains("OSStatus -25293"));
        s.configure("fixture-only".into(), ai::DEFAULT_MODEL, 128)
            .unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&s.public_status()).unwrap()["disabled_reason"].is_null());
    }
}
