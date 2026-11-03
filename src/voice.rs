//! Opt-in, text-in/audio-out Realtime replies. No microphone/audio input path.
use crate::ai::{self, History, Settings};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
use tungstenite::{
    Message, WebSocket, client::IntoClientRequest, protocol::WebSocketConfig,
    stream::MaybeTlsStream,
};

pub const MODEL: &str = "gpt-realtime-2.1-mini";
pub const VOICES: &[&str] = &[
    "marin", "coral", "sage", "cedar", "alloy", "ash", "ballad", "echo", "shimmer", "verse",
];
const MAX_PCM: usize = 2_880_000; // 60 seconds, PCM16 mono at 24 kHz.
const MAX_EVENT: usize = 512 * 1024;
const MAX_EVENTS: usize = 4096;
static CANCEL: AtomicU64 = AtomicU64::new(0);
pub fn generation() -> u64 {
    CANCEL.load(Ordering::Relaxed)
}
pub fn cancel() {
    CANCEL.fetch_add(1, Ordering::Relaxed);
}

pub struct AudioAnswer {
    pub text: String,
    pub usage: String,
    pub wav: Option<String>,
    pub completed: bool,
    pub measurement: crate::metering::Measurement,
}
pub fn request(voice: &str, cap: u32, history: &History, input: &str) -> Result<Value, String> {
    if !VOICES.contains(&voice) {
        return Err("Unsupported OpenAI voice. No audio request sent.".into());
    }
    if !(32..=4096).contains(&cap) || input.is_empty() || input.len() > 2000 {
        return Err("Invalid audio request bounds. Nothing sent.".into());
    }
    let mut items = Vec::new();
    for (user, assistant) in history.pairs() {
        items.push(
            json!({"type":"message","role":"user","content":[{"type":"input_text","text":user}]}),
        );
        items.push(json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":assistant}]}));
    }
    items.push(
        json!({"type":"message","role":"user","content":[{"type":"input_text","text":input}]}),
    );
    Ok(
        json!({"type":"response.create","response":{"conversation":"none","output_modalities":["audio"],"input":items,
        "instructions":format!("{} Speak warmly and naturally, with a concise answer in a conversational tone. This is AI-generated speech.",ai::INSTRUCTIONS),
        "max_output_tokens":cap,"tools":[],"tool_choice":"none","audio":{"output":{"voice":voice,"format":{"type":"audio/pcm","rate":24000}}}}}),
    )
}
fn count(v: &Value) -> String {
    v.as_u64()
        .map(|n| n.to_string())
        .unwrap_or_else(|| "unavailable".into())
}
fn usage(response: &Value) -> String {
    let u = &response["usage"];
    format!(
        "OpenAI audio API-reported tokens — input: {} (text: {}, audio: {}, cached subset: {}); output: {} (text: {}, audio: {}); total: {}.\nCost estimate: not calculated. Audio has separate rates; subsets are not added again.",
        count(&u["input_tokens"]),
        count(&u["input_token_details"]["text_tokens"]),
        count(&u["input_token_details"]["audio_tokens"]),
        count(&u["input_token_details"]["cached_tokens"]),
        count(&u["output_tokens"]),
        count(&u["output_token_details"]["text_tokens"]),
        count(&u["output_token_details"]["audio_tokens"]),
        count(&u["total_tokens"])
    )
}
fn wav(pcm: &[u8]) -> Option<String> {
    if pcm.is_empty() || pcm.len() > MAX_PCM || !pcm.len().is_multiple_of(2) {
        return None;
    }
    let mut out = Vec::with_capacity(pcm.len() + 44);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(pcm.len() as u32 + 36).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&24000u32.to_le_bytes());
    out.extend_from_slice(&48000u32.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    out.extend_from_slice(pcm);
    Some(STANDARD.encode(out))
}
#[derive(Default)]
struct Collector {
    pcm: Vec<u8>,
    transcript: String,
}
impl Collector {
    fn accept(&mut self, event: &Value) -> Result<Option<AudioAnswer>, String> {
        match event["type"].as_str() {
            Some("error") => {
                let code = event["error"]["code"]
                    .as_str()
                    .filter(|s| {
                        s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                    })
                    .unwrap_or("unavailable");
                Err(format!(
                    "OpenAI audio request rejected (code: {code}). No automatic retry. Usage unavailable; zero cost is not established."
                ))
            }
            Some("response.output_audio.delta") => {
                let delta = event["delta"].as_str().ok_or("Missing audio chunk")?;
                if delta.len() > MAX_EVENT {
                    return Err("Audio chunk exceeds local limit. No retry.".into());
                }
                let bytes = STANDARD
                    .decode(delta)
                    .map_err(|_| "Invalid audio encoding. No retry.")?;
                if self.pcm.len() + bytes.len() > MAX_PCM {
                    return Err(
                        "Audio exceeded the 60-second local limit. Usage unavailable; no retry."
                            .into(),
                    );
                }
                self.pcm.extend(bytes);
                Ok(None)
            }
            Some("response.output_audio_transcript.done") => {
                let text = event["transcript"].as_str().unwrap_or("");
                if text.len() > 32_000 {
                    return Err("Audio transcript exceeds local limit.".into());
                }
                self.transcript = text.into();
                Ok(None)
            }
            Some("response.done") => {
                let r = &event["response"];
                let mut text = Vec::new();
                for item in r["output"].as_array().into_iter().flatten() {
                    if item["type"] != "message" || item["role"] != "assistant" {
                        return Ok(Some(AudioAnswer {
                            text: "Unexpected non-message audio output was not executed.".into(),
                            usage: usage(r),
                            wav: None,
                            completed: false,
                            measurement: crate::metering::Measurement::from_response(r, true),
                        }));
                    }
                    for part in item["content"].as_array().into_iter().flatten() {
                        if let Some(t) = part["transcript"]
                            .as_str()
                            .or_else(|| part["text"].as_str())
                        {
                            text.push(t);
                        }
                    }
                }
                let mut text = if text.is_empty() {
                    self.transcript.clone()
                } else {
                    text.join("\n")
                };
                if text.len() > 32_000 {
                    return Err("Audio transcript exceeds local limit.".into());
                }
                let completed = r["status"] == "completed" && !text.is_empty();
                if !completed {
                    text = format!(
                        "[Audio response incomplete or failed; output cap may have been reached. No retry.]\n{text}"
                    );
                }
                let audio = wav(&self.pcm);
                if text.trim().is_empty() {
                    text="No transcript returned. Please switch to Mac voice and try again manually.".into();
                }
                Ok(Some(AudioAnswer {
                    text,
                    usage: usage(r),
                    wav: audio,
                    completed,
                    measurement: crate::metering::Measurement::from_response(r, true),
                }))
            }
            _ => Ok(None),
        }
    }
}

fn run<S: Read + Write>(
    ws: &mut WebSocket<S>,
    message: Value,
    ticket: u64,
    timeout: Duration,
) -> Result<AudioAnswer, String> {
    let deadline = Instant::now() + timeout;
    let mut collector = Collector::default();
    let mut sent = false;
    for _ in 0..MAX_EVENTS {
        if ticket != generation() {
            let _ = ws.close(None);
            return Err(
                "Audio request canceled. Provider usage may have occurred; no automatic retry."
                    .into(),
            );
        }
        if Instant::now() > deadline {
            return Err(
                "Audio request timed out. It may be billed; usage unavailable. No retry.".into(),
            );
        }
        let msg = match ws.read() {
            Ok(m) => m,
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) =>
            {
                continue;
            }
            Err(_) => return Err(
                "Audio connection ended without a complete response. Usage unavailable; no retry."
                    .into(),
            ),
        };
        if let Message::Text(text) = msg {
            if text.len() > MAX_EVENT {
                return Err("Audio event exceeds local limit.".into());
            }
            let event: Value =
                serde_json::from_str(&text).map_err(|_| "Malformed audio event. No retry.")?;
            match event["type"].as_str() {
                Some("session.created") if !sent => {
                    // No microphone input, transcription, VAD, tools, or session conversation.
                    ws.send(Message::Text(json!({"type":"session.update","session":{"type":"realtime","audio":{"input":{"turn_detection":null,"transcription":null}},"tools":[],"tool_choice":"none"}}).to_string().into())).map_err(|_|"Could not configure audio session")?;
                }
                Some("session.updated") if !sent => {
                    ws.send(Message::Text(message.to_string().into()))
                        .map_err(|_| "Could not send audio request")?;
                    sent = true;
                }
                _ => {}
            }
            if let Some(answer) = collector.accept(&event)? {
                let _ = ws.close(None);
                return Ok(answer);
            }
        }
    }
    Err("Audio event count exceeded local limit. No retry; usage unavailable.".into())
}
pub fn ask(
    settings: &Settings,
    history: &History,
    input: &str,
    voice: &str,
    ticket: u64,
) -> Result<AudioAnswer, String> {
    let message = request(voice, settings.cap, history, input)?;
    if ticket != generation() {
        return Err("Audio request canceled before connecting.".into());
    }
    let (send, recv) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = send.send(
            ("api.openai.com", 443)
                .to_socket_addrs()
                .map(|it| it.take(2).collect::<Vec<_>>()),
        );
    });
    let addresses = recv
        .recv_timeout(Duration::from_secs(5))
        .map_err(|_| "Audio DNS lookup timed out. No request sent.")?
        .map_err(|_| "Audio DNS lookup failed. No request sent.")?;
    let mut stream = None;
    for addr in addresses {
        if let Ok(s) = TcpStream::connect_timeout(&addr, Duration::from_secs(5)) {
            stream = Some(s);
            break;
        }
    }
    let tcp = stream.ok_or("Could not connect for audio. No automatic retry.")?;
    tcp.set_read_timeout(Some(Duration::from_secs(8)))
        .map_err(|_| "Could not set audio deadline")?;
    tcp.set_write_timeout(Some(Duration::from_secs(8)))
        .map_err(|_| "Could not set audio deadline")?;
    let mut request = format!("wss://api.openai.com/v1/realtime?model={MODEL}")
        .into_client_request()
        .map_err(|_| "Invalid audio endpoint")?;
    let mut auth =
        tungstenite::http::HeaderValue::from_str(&format!("Bearer {}", settings.api_key()))
            .map_err(|_| "Invalid audio authentication header")?;
    auth.set_sensitive(true);
    request.headers_mut().insert("Authorization", auth);
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_EVENT))
        .max_frame_size(Some(MAX_EVENT));
    if ticket != generation() {
        return Err("Audio request canceled before authentication.".into());
    }
    let (mut ws,_)=tungstenite::client_tls_with_config(request,tcp,Some(config),None).map_err(|error|match error {
        tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response))=>format!("Audio handshake HTTP {}. Check API access/model availability. No retry; usage unavailable.",response.status().as_u16()),
        _=>"Audio handshake failed (network, API access or authentication). No retry; usage unavailable.".into()
    })?;
    match ws.get_mut() {
        MaybeTlsStream::Rustls(s) => {
            let _ = s.sock.set_read_timeout(Some(Duration::from_secs(1)));
        }
        MaybeTlsStream::Plain(s) => {
            let _ = s.set_read_timeout(Some(Duration::from_secs(1)));
        }
        _ => {}
    }
    run(&mut ws, message, ticket, Duration::from_secs(40))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, thread};
    const DONE: &str = include_str!("../fixtures/realtime-done.json");
    #[test]
    fn bounded_text_only_contract_and_wav() {
        let mut history = History::default();
        for _ in 0..7 {
            history.push("question", "answer");
        }
        let body = request("marin", 512, &history, "Hello").unwrap();
        let s = body.to_string();
        assert_eq!(body["response"]["input"].as_array().unwrap().len(), 7);
        assert_eq!(body["response"]["max_output_tokens"], 512);
        assert!(!s.contains("input_audio"));
        assert!(!s.contains("input_file"));
        assert_eq!(body["response"]["conversation"], "none");
        assert_eq!(body["response"]["tools"], json!([]));
        assert!(request("unknown", 512, &history, "Hello").is_err());
        let data = STANDARD.decode(wav(&[0, 0, 1, 0]).unwrap()).unwrap();
        assert_eq!(&data[..4], b"RIFF");
        assert_eq!(data.len(), 48);
        assert!(wav(&[0]).is_none());
    }
    #[test]
    fn fixture_usage_no_double_count_and_missing_fields() {
        let mut c = Collector::default();
        c.accept(&json!({"type":"response.output_audio.delta","delta":"AAAAAA=="}))
            .unwrap();
        let mut event: Value = serde_json::from_str(DONE).unwrap();
        let answer = c.accept(&event).unwrap().unwrap();
        assert_eq!(answer.text, "Fixture audio answer.");
        assert!(answer.wav.is_some());
        assert!(answer.usage.contains("total: 150"));
        assert!(answer.usage.contains("audio: 25"));
        event["response"]["usage"] = Value::Null;
        assert!(
            Collector::default()
                .accept(&event)
                .unwrap()
                .unwrap()
                .usage
                .contains("unavailable")
        );
        assert!(
            Collector::default()
                .accept(&json!({"type":"error","error":{"message":"secret must not echo"}}))
                .err()
                .unwrap()
                .contains("rejected")
        );
    }
    #[test]
    fn malformed_oversized_and_non_message_audio_are_rejected() {
        assert!(
            Collector::default()
                .accept(&json!({"type":"response.output_audio.delta","delta":"not-base64!"}))
                .is_err()
        );
        let mut full = Collector {
            pcm: vec![0; MAX_PCM],
            transcript: String::new(),
        };
        assert!(
            full.accept(&json!({"type":"response.output_audio.delta","delta":"AAAAAA=="}))
                .is_err()
        );
        let mut event: Value = serde_json::from_str(DONE).unwrap();
        event["response"]["output"] = json!([{"type":"function_call","name":"shell"}]);
        assert!(
            Collector::default()
                .accept(&event)
                .unwrap()
                .unwrap()
                .text
                .contains("not executed")
        );
    }
    #[test]
    fn websocket_provider_error_and_timeout_do_not_retry() {
        for mode in ["error", "timeout", "malformed"] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let server = thread::spawn(move || {
                let (tcp, _) = listener.accept().unwrap();
                tcp.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut ws = tungstenite::accept(tcp).unwrap();
                ws.send(Message::Text(
                    json!({"type":"session.created"}).to_string().into(),
                ))
                .unwrap();
                let _ = ws.read().unwrap();
                ws.send(Message::Text(
                    json!({"type":"session.updated"}).to_string().into(),
                ))
                .unwrap();
                let _ = ws.read().unwrap();
                match mode {
                    "timeout" => thread::sleep(Duration::from_millis(250)),
                    "malformed" => {
                        let _ = ws.send(Message::Text("not json".into()));
                    }
                    _ => {
                        let _=ws.send(Message::Text(json!({"type":"error","error":{"code":"rate_limit_exceeded","message":"private message"}}).to_string().into()));
                    }
                }
            });
            let tcp = TcpStream::connect(address).unwrap();
            tcp.set_read_timeout(Some(Duration::from_millis(30)))
                .unwrap();
            let (mut ws, _) = tungstenite::client(format!("ws://{address}"), tcp).unwrap();
            let error = run(
                &mut ws,
                request("sage", 128, &History::default(), "fixture").unwrap(),
                generation(),
                Duration::from_millis(100),
            )
            .err()
            .unwrap();
            assert!(!error.contains("private message"));
            assert!(match mode {
                "timeout" => error.contains("timed out"),
                "malformed" => error.contains("Malformed"),
                _ => error.contains("rate_limit_exceeded"),
            });
            server.join().unwrap();
        }
    }
    #[test]
    fn real_websocket_client_against_loopback_fixture() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(tcp).unwrap();
            ws.send(Message::Text(
                json!({"type":"session.created"}).to_string().into(),
            ))
            .unwrap();
            let setup: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert!(setup["session"]["audio"]["input"]["turn_detection"].is_null());
            ws.send(Message::Text(
                json!({"type":"session.updated"}).to_string().into(),
            ))
            .unwrap();
            let request: Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(request["response"]["max_output_tokens"], 128);
            ws.send(Message::Text(
                json!({"type":"response.output_audio.delta","delta":"AAAAAA=="})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            ws.send(Message::Text(DONE.into())).unwrap();
        });
        let tcp = TcpStream::connect(address).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let (mut ws, _) = tungstenite::client(format!("ws://{address}"), tcp).unwrap();
        let answer = run(
            &mut ws,
            request("coral", 128, &History::default(), "synthetic").unwrap(),
            generation(),
            Duration::from_secs(3),
        )
        .unwrap();
        assert!(answer.completed);
        assert!(answer.wav.is_some());
        server.join().unwrap();
    }
}
