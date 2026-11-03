# Validation — 2026-11-03

Environment: Apple Silicon arm64, macOS 27.0.1, Rust/Cargo 1.95.0, existing Apple Command Line Tools. The final source and app live separately at `~/Daniel/desktop-companion`; staging/testing took place in the task workspace. No dependencies were downloaded.

## Automated checks

- `cargo fmt --all --check` — passed.
- `cargo clippy --offline --locked --all-targets -- -D warnings` — passed.
- `cargo test --offline --locked` — 6 tests passed, including spoken-command variants and the three-second subprocess timeout.
- `desktop-companion --native-self-test` — 16 AppKit field-editor/transcript lifecycle checks passed; zero recording or permission requests.
- `scripts/build-app.sh` — release build passed; native Objective-C compiled with `-Wall -Wextra -Werror`; Info.plist validated; app ad-hoc signed.
- Generated launch-agent preview validated with `plutil -lint`; no LaunchAgent was installed or loaded.

Tests cover command aliases/punctuation, unsupported input and shell payload rejection, explicit AI/voice limitations, local-only Pi status (excluding nested coalition states), command failures and timeout cleanup. Native permission/capture behaviors require manual device tests; they are not claimed as covered by Rust unit tests.

## Actual app checks

Opened the delivered `dist/Mica.app` and inspected its real accessibility tree and screenshot. The 460 × 550 placeholder panel shows its controls without clipping. UI checks verified:

- Mac status returned actual uptime, AC power / 100% battery, and macOS 27.0.1.
- Pi sync status reported the existing Mac agent loaded, `state = not running`, 868 runs, last exit code 0 at check time, plus the explicit remote-health limitation. No sync or remote restart occurred.
- Typed `what time is it?` and pressed Return; the UI displayed the current date/time.
- Voice info displayed `local.dan.desktop-companion`, English (US), device support yes, recognizer available yes, speech and microphone permissions not determined for the rebuilt app. No recording was started by that diagnostic.
- Dan reported that Speak reply successfully read the time/date aloud. This is confirmation of system TTS output, not the exact assistant voice from the conversation.

## Initial speech input blocker

Dan clicked Click to talk and Continue in the initial build; recording stopped immediately. Apple's `localspeechrecognition` log showed repeated `kLSRErrorDomain Code=201`, **“Siri and Dictation are disabled.”** The installed Apple Speech SDK's `SFSpeechRecognitionTask.h` documents 201 as Siri or Dictation disabled. This is a system-service refusal despite on-device capability being true, not a demonstrated missing microphone or unsupported hardware.

The first command-line probe inside the execution sandbox reported no device support and denied speech authorization. The later unsandboxed probe reported device support yes. CLI permission identity also differs from the UI bundle. The initial sandbox result is therefore not used as the explanation for Dan's failure.

The app displays native error domain/code/description, specific guidance for error 201 and missing-assets error 102, and an app-specific Voice info control. It stops audio on any recognition error and never retries against a server. Rebuilding an ad-hoc signed app may require fresh privacy authorization.

## Speech command follow-up

Dan subsequently enabled system Dictation himself and reported that spoken text appeared. He reported spoken time/Mac status producing command hints after Send. Inspecting the real app showed **`Max status`** in the input; clicking Send displayed **`You: Max status`** and the unsupported-command response. That reproduction established an exact recognition/allowlist mismatch; it did not establish that the Rust parser dispatched `time` as `help`. No full audio transcript was collected or saved.

The update adds the exact observed `max status` alias, handles boundary speech quotes/punctuation and whitespace, displays Submitted text plus Matched command, disables Send/editing during capture, freezes the last transcript on Stop, snapshots actual field-editor text on Send, and rejects late/currently-idle speech callbacks. Synthetic tests exercise actual AppKit field-editor state, user edits after Stop, blocked Send during capture and authorization, observed Max status dispatch, and previous-session callback rejection. Rust tests check Time/Time./quoted and whitespace variants, Mac/Max status, actual action responses rather than hints, and compound-command rejection.

After reopening the updated app, actual UI submission of `Time.` displayed `Submitted: “Time.”`, `Matched: time`, and the current date/time. Submitting `Max status.` by clicking Send displayed `Matched: Mac status` and real uptime/battery/OS information. These UI checks used synthetic text matching speech transcripts; they do not claim a live microphone test. An exact `time` transcript dispatching as Help was not reproduced.

The original Dictation setting change was made by Dan, not the agent. Live microphone end-to-end transcription and the 15-second cutoff under a working recognizer still need human validation on the final rebuilt app; synthetic lifecycle checks do not claim audio recognition quality.

## Preserved boundaries

No paid API, credentials, model download, cloud inference, persistent startup installation, remote Pi action, publishing or deployment. The existing Token Grove LaunchAgent was read only. No modifications were made to Trader, llm-usage, pi-usage or other projects. No microphone permission was granted or system Dictation/Siri setting changed by the agent.

