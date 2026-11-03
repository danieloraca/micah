//! Content-free local usage export. No credential, prompt, transcript or audio fields.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::Path,
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Counters {
    pub input: Option<u64>,
    pub output: Option<u64>,
    pub total: Option<u64>,
    pub cached: Option<u64>,
    pub input_text: Option<u64>,
    pub input_audio: Option<u64>,
    pub input_image: Option<u64>,
    pub output_text: Option<u64>,
    pub output_audio: Option<u64>,
    pub cached_text: Option<u64>,
    pub cached_audio: Option<u64>,
    pub cached_image: Option<u64>,
}
impl Counters {
    pub fn from_response(r: &Value, realtime: bool) -> Self {
        let u = &r["usage"];
        let i = &u[if realtime {
            "input_token_details"
        } else {
            "input_tokens_details"
        }];
        let o = &u[if realtime {
            "output_token_details"
        } else {
            "output_tokens_details"
        }];
        let c = &i["cached_tokens_details"];
        Self {
            input: u["input_tokens"].as_u64(),
            output: u["output_tokens"].as_u64(),
            total: u["total_tokens"].as_u64(),
            cached: i["cached_tokens"].as_u64(),
            input_text: i["text_tokens"].as_u64(),
            input_audio: i["audio_tokens"].as_u64(),
            input_image: i["image_tokens"].as_u64(),
            output_text: o["text_tokens"].as_u64(),
            output_audio: o["audio_tokens"].as_u64(),
            cached_text: c["text_tokens"].as_u64(),
            cached_audio: c["audio_tokens"].as_u64(),
            cached_image: c["image_tokens"].as_u64(),
        }
    }
}
#[derive(Clone, Debug, Default)]
pub struct Measurement {
    pub counters: Counters,
    pub service_tier: Option<String>,
}
impl Measurement {
    pub fn from_response(r: &Value, realtime: bool) -> Self {
        let tier = if realtime {
            Some("default")
        } else {
            r["service_tier"].as_str()
        };
        Self {
            counters: Counters::from_response(r, realtime),
            service_tier: tier
                .filter(|v| matches!(*v, "default" | "flex" | "priority" | "scale" | "auto"))
                .map(str::to_owned),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub schema_version: u8,
    pub source: String,
    pub event_id: String,
    pub session_id: String,
    pub timestamp_ms: u64,
    pub model: String,
    pub route: String,
    pub outcome: String,
    pub service_tier: Option<String>,
    pub usage: Counters,
}
static SERIAL: AtomicU64 = AtomicU64::new(0);
fn epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
pub fn event(
    model: &str,
    route: &str,
    completed: Option<bool>,
    measurement: Option<&Measurement>,
) -> Event {
    static SESSION: OnceLock<String> = OnceLock::new();
    let timestamp_ms = epoch_ms();
    let session_id = SESSION
        .get_or_init(|| {
            format!(
                "{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            )
        })
        .clone();
    // Only public model identifiers, never arbitrary provider strings or errors.
    let model = if (model.starts_with("gpt-")
        || model.starts_with("o1")
        || model.starts_with("o3")
        || model.starts_with("o4"))
        && model.len() <= 128
        && model
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._:".contains(&b))
    {
        model
    } else {
        "unrecognized-model"
    };
    Event {
        schema_version: 1,
        source: "mica".into(),
        event_id: format!("{session_id}-{}", SERIAL.fetch_add(1, Ordering::Relaxed)),
        session_id,
        timestamp_ms,
        model: model.into(),
        route: if route == "realtime" {
            "realtime"
        } else {
            "responses"
        }
        .into(),
        outcome: match completed {
            Some(true) => "completed",
            Some(false) => "incomplete",
            None => "unknown",
        }
        .into(),
        service_tier: measurement.and_then(|m| m.service_tier.clone()),
        usage: measurement.map(|m| m.counters.clone()).unwrap_or_default(),
    }
}
pub fn append(directory: &Path, event: &Event) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)?;
    let meta = fs::symlink_metadata(directory)?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(io::Error::other("Usage directory must be private"));
    }
    let path = directory.join(format!("usage-{}.jsonl", event.timestamp_ms / 86_400_000));
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.nlink() != 1
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
        || meta.len() > 16 * 1024 * 1024
    {
        return Err(io::Error::other("Usage file unavailable or too large"));
    }
    let mut bytes = serde_json::to_vec(event)?;
    bytes.push(b'\n');
    file.write_all(&bytes)
}
pub fn record(
    model: &str,
    route: &str,
    completed: Option<bool>,
    measurement: Option<&Measurement>,
) -> bool {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .is_some_and(|home| {
            append(
                &home.join("Library/Application Support/Mica/usage"),
                &event(model, route, completed, measurement),
            )
            .is_ok()
        })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_schema_contract_and_realtime_cache_details() {
        let fixture = include_str!("../fixtures/mica-usage-v1.json");
        let event: Event = serde_json::from_str(fixture).unwrap();
        assert_eq!(event.usage.cached_audio, Some(10));
        let r = serde_json::json!({"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150,"input_token_details":{"text_tokens":60,"audio_tokens":40,"cached_tokens":30,"cached_tokens_details":{"text_tokens":20,"audio_tokens":10}},"output_token_details":{"text_tokens":10,"audio_tokens":40}},"transcript":"PRIVATE"});
        let measurement = Measurement::from_response(&r, true);
        assert_eq!(measurement.counters.cached_audio, Some(10));
        assert_eq!(measurement.counters.output_audio, event.usage.output_audio);
        assert_eq!(
            serde_json::to_value(&event).unwrap(),
            serde_json::from_str::<Value>(fixture).unwrap()
        );
    }
    #[test]
    fn metadata_only_missing_counts_and_private_append() {
        let r = serde_json::json!({"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120,"input_tokens_details":{"cached_tokens":30}},"service_tier":"default","input":"PRIVATE_PROMPT","output":"PRIVATE_ANSWER","key":"PRIVATE_KEY"});
        let m = Measurement::from_response(&r, false);
        let e = event("gpt-5.4-nano", "responses", Some(true), Some(&m));
        let encoded = serde_json::to_string(&e).unwrap();
        assert!(!encoded.contains("PRIVATE"));
        assert!(!encoded.contains("output_tokens_details"));
        assert_eq!(e.usage.input_audio, None);
        let dir = std::env::temp_dir().join(format!("mica-meter-{}", e.event_id));
        append(&dir, &e).unwrap();
        append(&dir, &e).unwrap();
        let path = dir.join(format!("usage-{}.jsonl", e.timestamp_ms / 86_400_000));
        assert_eq!(fs::read_to_string(&path).unwrap().lines().count(), 2);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        assert!(append(&path, &e).is_err());
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/dev/null", &path).unwrap();
        assert!(append(&dir, &e).is_err());
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
        let unknown = event("sk-example-secret", "realtime", None, None);
        assert_eq!(unknown.model, "unrecognized-model");
        assert_eq!(unknown.usage.total, None);
        assert_ne!(unknown.event_id, e.event_id);
    }
}
