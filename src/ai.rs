//! Text-only, bounded OpenAI Responses adapter. Never reads credentials or files.
use reqwest::blocking::Client;
use serde::Serialize;
use serde_json::{Value, json};
use std::{collections::VecDeque, io::Read, time::Duration};
use zeroize::Zeroizing;

pub const DEFAULT_MODEL: &str = "gpt-5.4-nano";
pub const DEFAULT_CAP: u32 = 512;
pub const MAX_PAIRS: usize = 3;
pub const MAX_HISTORY_BYTES: usize = 12_000;
const MAX_RESPONSE_BYTES: u64 = 256 * 1024;
pub(crate) const INSTRUCTIONS: &str = "You are Micah, a friendly desktop conversation companion. Answer concisely in plain text. You have no tools, files, live device data, or ability to take actions. Never claim to have inspected or changed the user's computer. Ask the user to use Micah's local status commands for current device information. Do not claim to be the user's ChatGPT account or to know its conversations.";

pub struct Settings {
    key: Zeroizing<String>,
    pub model: String,
    pub cap: u32,
}

impl Settings {
    pub(crate) fn api_key(&self) -> &str {
        &self.key
    }
    pub fn new(key: String, model: &str, cap: u32) -> Result<Self, String> {
        let key = Zeroizing::new(key);
        if key.is_empty() || key.len() > 512 || !key.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(
                "Enter an API key in Micah's secure field (session memory only). No request sent."
                    .into(),
            );
        }
        validate_model_cap(model, cap)?;
        Ok(Self {
            key,
            model: model.into(),
            cap,
        })
    }
}

pub fn validate_model_cap(model: &str, cap: u32) -> Result<(), String> {
    if model.is_empty()
        || model.len() > 128
        || !model
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._:".contains(&b))
    {
        return Err("Use a valid OpenAI model ID. No request sent.".into());
    }
    if !(32..=4096).contains(&cap) {
        return Err("Output-token cap must be 32–4096. No request sent.".into());
    }
    Ok(())
}

#[derive(Default)]
pub struct History(VecDeque<(String, String)>);
impl History {
    pub(crate) fn pairs(&self) -> impl Iterator<Item = &(String, String)> {
        self.0.iter()
    }
    pub fn clear(&mut self) {
        self.0.clear();
    }
    pub fn len(&self) -> usize {
        self.0.len()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn push(&mut self, user: &str, assistant: &str) {
        self.0
            .push_back((user.into(), assistant.chars().take(4000).collect()));
        while self.0.len() > MAX_PAIRS
            || self.0.iter().map(|(u, a)| u.len() + a.len()).sum::<usize>() > MAX_HISTORY_BYTES
        {
            self.0.pop_front();
        }
    }
}

pub fn request_body(settings: &Settings, history: &History, input: &str) -> Value {
    let mut messages = Vec::new();
    for (user, assistant) in &history.0 {
        messages.push(json!({"role":"user", "content":user}));
        messages.push(json!({"role":"assistant", "content":assistant}));
    }
    messages.push(json!({"role":"user", "content":input}));
    let mut body = json!({"model":settings.model, "input":messages,
        "instructions":INSTRUCTIONS, "max_output_tokens":settings.cap,
        "service_tier":"default", "store":false, "stream":false, "tools":[], "tool_choice":"none"});
    // This default model officially supports none. Other models retain their own
    // defaults; the cap still covers reasoning tokens as well as visible text.
    if settings.model.starts_with("gpt-5.4-nano") {
        body["reasoning"] = json!({"effort":"none"});
    }
    body
}

#[derive(Debug, Serialize)]
pub struct Answer {
    pub text: String,
    pub usage: String,
    pub completed: bool,
    #[serde(skip)]
    pub measurement: crate::metering::Measurement,
}

fn count(value: Option<u64>) -> String {
    value
        .map(|v| v.to_string())
        .unwrap_or_else(|| "unavailable".into())
}
pub fn usage(value: &Value) -> String {
    let u = &value["usage"];
    format!(
        "API-reported tokens — input: {}; cached input (subset): {}; output: {}; reasoning (subset of output): {}; total: {}.\nCost estimate: not calculated; token counts are not a bill.",
        count(u["input_tokens"].as_u64()),
        count(u["input_tokens_details"]["cached_tokens"].as_u64()),
        count(u["output_tokens"].as_u64()),
        count(u["output_tokens_details"]["reasoning_tokens"].as_u64()),
        count(u["total_tokens"].as_u64())
    )
}

pub fn parse_response(bytes: &[u8]) -> Result<Answer, String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| {
        "OpenAI returned unreadable JSON. Usage unavailable; no automatic retry.".to_string()
    })?;
    let usage = usage(&value);
    let measurement = crate::metering::Measurement::from_response(&value, false);
    let mut pieces = Vec::new();
    for item in value["output"].as_array().into_iter().flatten() {
        match item["type"].as_str() {
            Some("message") if item["role"] == "assistant" => {
                for part in item["content"].as_array().into_iter().flatten() {
                    if part["type"] == "output_text" {
                        if let Some(text) = part["text"].as_str() {
                            pieces.push(text.to_owned());
                        }
                    } else if part["type"] == "refusal" {
                        pieces.push(
                            part["refusal"]
                                .as_str()
                                .unwrap_or("The model declined this request.")
                                .into(),
                        );
                    }
                }
            }
            Some("reasoning") => {}
            _ => {
                return Ok(Answer {
                    text: "Unexpected non-text output was not executed. No action was taken."
                        .into(),
                    usage,
                    completed: false,
                    measurement,
                });
            }
        }
    }
    let completed = value["status"] == "completed" && !pieces.is_empty();
    let mut text = pieces.join("\n");
    if !completed {
        let reason = if value["incomplete_details"]["reason"] == "max_output_tokens" {
            "output-token cap reached (including any reasoning)"
        } else {
            "response not completed"
        };
        text = format!("[Incomplete: {reason}. No automatic retry.]\n{text}");
    }
    if text.trim().is_empty() {
        text = "OpenAI returned no displayable text. No action was taken.".into();
    }
    Ok(Answer {
        text,
        usage,
        completed,
        measurement,
    })
}

fn send(
    client: &Client,
    endpoint: &str,
    settings: &Settings,
    history: &History,
    input: &str,
) -> Result<Answer, String> {
    let response = client.post(endpoint).bearer_auth(settings.key.as_str()).json(&request_body(settings, history, input)).send()
        .map_err(|e| if e.is_timeout() { "Request timed out. It may have completed and incurred API usage. No automatic retry; reported usage unavailable.".into() } else { "OpenAI connection failed. No automatic retry; reported usage unavailable.".to_string() })?;
    let status = response.status().as_u16();
    if status != 200 {
        // Never echo provider error bodies: they may contain request text or secrets.
        let detail = match status {
            401 | 403 => "API authentication/access rejected",
            429 => "rate limit or API quota reached",
            400 | 404 => "model or request parameters rejected",
            300..=399 => "redirect refused",
            _ => "service error",
        };
        return Err(format!(
            "OpenAI HTTP {status}: {detail}. No automatic retry. API-reported usage unavailable; this is not proof of zero cost."
        ));
    }
    let mut bytes = Vec::new();
    response
        .take(MAX_RESPONSE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| {
            "Could not read the complete response. Usage unavailable; no automatic retry."
                .to_string()
        })?;
    if bytes.len() as u64 > MAX_RESPONSE_BYTES {
        return Err(
            "Response exceeded the local size limit. Usage unavailable; no automatic retry.".into(),
        );
    }
    parse_response(&bytes)
}

pub fn ask(settings: &Settings, history: &History, input: &str) -> Result<Answer, String> {
    let client = Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|_| "Could not initialize the HTTPS client. No request sent.".to_string())?;
    send(
        &client,
        "https://api.openai.com/v1/responses",
        settings,
        history,
        input,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };
    const FIXTURE: &str = include_str!("../fixtures/openai-completed.json");
    fn settings() -> Settings {
        Settings::new("fixture-only-not-a-secret".into(), DEFAULT_MODEL, 256).unwrap()
    }
    #[test]
    fn contract_is_text_only_bounded_and_stateless() {
        let s = settings();
        let mut history = History::default();
        for n in 0..10 {
            history.push(&format!("question {n}"), &"a".repeat(5000));
        }
        assert!(history.len() <= 3);
        let body = request_body(&s, &history, "current question");
        assert_eq!(body["store"], false);
        assert_eq!(body["max_output_tokens"], 256);
        assert_eq!(body["tool_choice"], "none");
        assert_eq!(body["tools"], json!([]));
        assert!(body.get("previous_response_id").is_none());
        assert!(body["input"].as_array().unwrap().len() <= 7);
        assert!(!body.to_string().contains("fixture-only"));
        assert!(
            history
                .0
                .iter()
                .map(|(u, a)| u.len() + a.len())
                .sum::<usize>()
                <= MAX_HISTORY_BYTES
        );
        history.clear();
        assert!(history.is_empty());
    }
    #[test]
    fn usage_is_reported_without_adding_subsets_or_inventing_missing_values() {
        let answer = parse_response(FIXTURE.as_bytes()).unwrap();
        assert_eq!(answer.text, "Fixture reply. No live API call.");
        assert!(answer.usage.contains("input: 120"));
        assert!(answer.usage.contains("total: 150"));
        assert!(answer.usage.contains("Cost estimate: not calculated"));
        let mut value: Value = serde_json::from_str(FIXTURE).unwrap();
        value["usage"] = Value::Null;
        assert!(
            parse_response(value.to_string().as_bytes())
                .unwrap()
                .usage
                .contains("input: unavailable")
        );
        value["status"] = json!("incomplete");
        value["incomplete_details"] = json!({"reason":"max_output_tokens"});
        assert!(
            parse_response(value.to_string().as_bytes())
                .unwrap()
                .text
                .contains("cap reached")
        );
        value["output"] = json!([{"type":"function_call","name":"shell"}]);
        assert!(
            parse_response(value.to_string().as_bytes())
                .unwrap()
                .text
                .contains("not executed")
        );
    }
    // Real HTTP client + serialization against a loopback fixture server. The
    // endpoint override exists only inside this test module; no real key used.
    fn mock(status: u16, body: String, delay: Duration) -> (String, thread::JoinHandle<Value>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let join = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut data = Vec::new();
            let mut buffer = [0u8; 4096];
            let header_end;
            loop {
                let n = socket.read(&mut buffer).unwrap();
                assert!(n > 0);
                data.extend_from_slice(&buffer[..n]);
                if let Some(i) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                    header_end = i + 4;
                    break;
                }
            }
            let headers = String::from_utf8_lossy(&data[..header_end]);
            assert!(headers.starts_with("POST /v1/responses HTTP/1.1"));
            assert!(
                headers
                    .to_lowercase()
                    .contains("authorization: bearer fixture-only-not-a-secret")
            );
            let length = headers
                .lines()
                .find_map(|s| {
                    s.to_lowercase()
                        .strip_prefix("content-length: ")
                        .and_then(|v| v.parse::<usize>().ok())
                })
                .unwrap();
            while data.len() < header_end + length {
                let n = socket.read(&mut buffer).unwrap();
                assert!(n > 0);
                data.extend_from_slice(&buffer[..n]);
            }
            let request = serde_json::from_slice(&data[header_end..header_end + length]).unwrap();
            thread::sleep(delay);
            let result = format!(
                "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(result.as_bytes());
            request
        });
        (format!("http://{addr}/v1/responses"), join)
    }
    #[test]
    fn http_success_failures_and_timeout_without_live_usage() {
        let client = Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_millis(250))
            .build()
            .unwrap();
        for (status, body, expected) in [
            (200, FIXTURE, "Fixture reply"),
            (401, "secret provider body", "authentication"),
            (429, "private quota details", "quota"),
            (500, "private error", "service error"),
            (200, "not json", "unreadable JSON"),
            (302, "redirect", "redirect refused"),
        ] {
            let (endpoint, server) = mock(status, body.into(), Duration::ZERO);
            let result = send(
                &client,
                &endpoint,
                &settings(),
                &History::default(),
                "synthetic prompt",
            );
            let shown = result.map(|a| a.text).unwrap_or_else(|e| e);
            assert!(shown.contains(expected), "{shown}");
            assert!(!shown.contains("private"));
            assert!(!shown.contains("secret provider"));
            let request = server.join().unwrap();
            assert_eq!(request["max_output_tokens"], 256);
            assert_eq!(request["store"], false);
        }
        let (endpoint, server) = mock(200, FIXTURE.into(), Duration::from_millis(500));
        assert!(
            send(
                &client,
                &endpoint,
                &settings(),
                &History::default(),
                "synthetic"
            )
            .unwrap_err()
            .contains("may have completed")
        );
        server.join().unwrap();
    }
    #[test]
    fn invalid_settings_fail_without_a_request() {
        assert!(Settings::new("".into(), DEFAULT_MODEL, 512).is_err());
        assert!(Settings::new("key\nInjected".into(), DEFAULT_MODEL, 512).is_err());
        assert!(Settings::new("fixture".into(), DEFAULT_MODEL, 0).is_err());
    }
}
