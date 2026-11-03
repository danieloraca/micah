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

## Optional OpenAI implementation — current follow-up

OpenAI text conversation is now implemented in Rust, disabled at startup, with a user-entered session-only key, editable `gpt-5.4-nano` default, output cap 512 (32–4096 configurable), 3-pair/12,000-byte history bound, explicit input transmission disclosure and API-reported token usage. No key was retrieved/entered/configured by the agent and no paid request was made. The initial no-network implementation above describes the previous milestone; the current optional network adapter is documented in README and [API-TESTING.md](API-TESTING.md).

Final checks for this follow-up:

- Formatting, strict Clippy, all **11 Rust tests**, release build and bundle signature verification passed.
- All **18 native AppKit synthetic checks** passed, including usage/cost rendering and answer-only speech text.
- Loopback HTTP tests initially failed in the restricted sandbox because it forbids local listening. They passed when run with local listening authorized; this was not a provider error or a paid request.
- Actual 460 × 650 UI/screenshot inspected: AI off by default; a manually submitted `Why is the sky blue?` displayed AI off / no API request / nothing sent.
- AI settings dialog inspected: secure empty key field, model `gpt-5.4-nano`, cap `512`, text/history transmission and separate billing disclosure. Canceled without entering a credential or enabling a session.
- Actual `Time.` submission still returned the current local date/time and explicitly showed no API usage.
- No live API or final microphone test was performed. Fixture usage values are synthetic; real model/account access, paid usage and response quality remain unverified by design.

The user-created Git repository and README's existing final `# mica` line were preserved. No Git commit, push, remote change or publication was performed. No launch agent or persistent credential was installed. Unrelated projects remain untouched.

## User-controlled Keychain persistence follow-up

The app now supports saving/replacing this specific OpenAI key in macOS Keychain, persistent non-secret model/cap/startup preferences, explicit saved-key use, and exact-item removal. Save settings leaves current AI off; Enable AI now is separate. Enable-at-launch is off by default and must be explicitly saved with a saved-key preference. Manual Send, device-only recognition and local speech output remain unchanged.

- Formatting, strict Clippy, **15 Rust tests**, release build and signature verification passed.
- **18 native AppKit checks plus 6 Keychain query-policy checks** passed. The latter inspect constructed query dictionaries, not Keychain items.
- Fake-store tests cover credential-free startup, saved startup opt-in and suppression, explicit save/replacement without reading the old key, exact removal/idempotent missing-key removal, denied/locked storage, preference write failures, invalid cap/startup settings and serialization containing no key.
- A temporary-directory settings test verifies real non-secret file roundtrip, mode 0600 and invalid-file rejection. No production credential is involved.
- Reopened with `--no-keychain-restore`, which blocks startup key reads regardless of any saved preference. Actual UI showed AI off and settings loaded without reading a key.
- Inspected the real settings dialog and screenshot: secure input; Save settings / Enable AI now / Remove saved key / Cancel; model `gpt-5.4-nano`, cap `512`; Save/replace and enable-at-launch both unchecked. Canceled without typing a key, invoking saved-key use/removal, or sending a request. A stale-UI guard stopped an attempted non-secret Save click before it executed; refreshed state still showed the unchanged dialog, then it was canceled.

**No real Keychain item was added, updated, read or deleted, and no paid API request was sent.** The production Security adapter is compiled and its query policy checked, but a real save/relaunch/use/replacement/removal roundtrip remains for Dan using his own key. The ad-hoc signed app may encounter signing/access-group or locked-Keychain errors; those display OSStatus and keep AI off without a plaintext fallback. No signing or Keychain access policy was changed.

Setup: enter the key in AI settings, select Save/replace key, and Save settings. Later leave it blank and choose Enable AI now; or explicitly save Enable AI at app launch if desired. Remove saved key has a confirmation and targets only service `local.dan.desktop-companion.openai`, account `default`. Non-secret preferences live at `~/Library/Application Support/Mica/settings.json`. The current verification instance suppresses restoration; quit and open normally to honor a future saved startup preference.

## AI-off-after-voice investigation

The user reported `Submitted: “How are you”` / `Source: AI off · no action` after enabling AI. Read-only process inspection found two independent Mica GUI processes: an app-bundle launch and `target/release/desktop-companion`. The inspected app instance was off; no secret or process memory was read to determine the other instance's credential state. Two processes can hold different in-memory AI state. The investigation did not establish that speech itself disabled an enabled session.

The fix adds a private per-user instance lock shared by both launch paths. A duplicate exits before credential restoration and asks the existing process to show its window. Lock failures are distinguished from an occupied lock. Failed Enable actions now show a result dialog, and the safe error reason remains visible on Send instead of being replaced with generic hints.

Formatting, Clippy, **16 Rust tests, 25 native lifecycle/instance checks and 6 Keychain policy checks**, release build and signature verification passed. Synthetic-session tests establish that Stop capture and Stop voice preserve the AI-enabled state without Keychain or API access. Error-state tests preserve a fake OSStatus reason and clear it on successful synthetic setup.

The two verified old task processes were stopped and the app and existing development executable updated. Actual second-launch testing returned immediately and left exactly one Mica process. The updated window was inspected with AI off under `--no-keychain-restore`. No existing key was retrieved, no Keychain item was changed and no paid request was sent. User must enable AI again in this single window to verify a real answer; any saved-key access/signing error will now be explicit.

## Concrete enable failure: OSStatus -34018

The next user attempt exposed the exact error in the real UI: `signing entitlement/access-group unavailable (OSStatus -34018)`. This confirms that the data-protection Keychain backend was incompatible with the current ad-hoc signing setup. The earlier duplicate-process observation was real but did not resolve this separate storage failure.

The current backend deliberately targets macOS's encrypted default file-based Keychain (normally login), using SecItem APIs scoped to one Keychain and the exact Mica service/account. It omits data-protection/synchronization attributes and access-group entitlements; system default ACLs trust the caller without a broadened app list. This is an explicit local-build compatibility choice, not plaintext fallback. macOS can show a Keychain access/unlock prompt, which Dan must handle himself. Old data-protection items are not read or migrated.

Enabling with a valid newly entered key is now independent of optional saving. Simulated Keychain or preference-write failures leave that session enabled with a clear not-saved warning. Missing/unreadable saved keys still fail explicitly. Manual setup and startup Keychain work run on background queues so permission prompts do not block the app's main thread. Result dialogs distinguish enabled, enabled-but-not-saved, and not-enabled states.

All **18 Rust tests** pass, including typed-key enable under storage failure and missing-saved-key failure. Strict lint/build/signature checks pass. Native lifecycle tests and revised Keychain policy checks use no real key or Keychain operation. Real Keychain save/retrieval and paid OpenAI requests remain untested by the agent; verification launches suppress key restoration.

