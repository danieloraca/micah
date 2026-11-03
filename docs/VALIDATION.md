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

## Voice replies and repeated confirmation

Voice-origin submissions now render text and automatically invoke the existing local system speech output when Read voice replies is on (default). Typed/quick-button requests do not auto-play. The draft origin is captured at Send and consumed; only answer text is spoken. Hidden/minimized windows and active/pending microphone capture suppress playback. Stop voice invalidates pending playback as well as stopping current speech. The non-secret playback preference is saved in NSUserDefaults.

The former unconditional per-click Mica confirmation is now shown once and remembered only after Continue. System permission APIs are called only for undetermined statuses; existing authorized/denied/restricted results are handled without repeated requests. This does not suppress genuine macOS permission prompts after a new ad-hoc build, or grant permission automatically.

Formatting, strict Clippy, **18 Rust tests, 33 native lifecycle/permission/playback checks and 6 native Keychain policy checks**, release build and signature verification passed. Checks use synthetic transcript/origin/permission states, no microphone and no paid request. The actual updated window/screenshot showed Read voice replies checked with the new Float/control layout. Mica was reopened with key restoration suppressed; user must enable AI again to test a live spoken answer. No key was read or changed, no system permission granted, and no code committed/pushed by the agent.

## Optional OpenAI voice picker

Implemented a Voice replies picker with Mac voice as the unchanged default and explicitly confirmed paid OpenAI built-in voices. Voice-origin AI Send requests can use `gpt-realtime-2.1-mini` to generate one audio response plus its matching transcript, retaining the configured output cap and bounded text history. Typed questions and local commands bypass paid audio. Local STT remains device-only; no microphone bytes, files or tools enter the WebSocket request.

Usage comes from response.done with input/output text/audio/cached subsets shown without double-counting. No monetary estimate is calculated. Audio stays in bounded memory, replay is cached, Stop cancels pending audio work/playback, and a transcript without usable audio falls back to the Mac voice. A provider failure does not trigger an additional paid text request automatically. No live audio API call, credential read or microphone capture was performed by the agent.

Formatting, strict Clippy, **23 Rust tests**, **36 native lifecycle/audio-route checks plus 6 Keychain policy checks**, release build and signature verification passed. Real loopback WebSocket tests exercise the protocol sequence, successful audio/usage collection, rejection, malformed JSON and timeout. Parser tests cover limits, base64/WAV, missing counts and unexpected tool output. These prove fixture behavior, not production TLS/model access or real voice quality.

Automatic approval review initially rejected Quit because the running app could hold an in-memory key/conversation. Dan subsequently explicitly authorized the restart. The staged update was applied to `dist/Mica.app` and the existing release executable; the installed bundle signature verified. Mica was reopened with `--no-keychain-restore`. Actual UI and screenshot confirm the Voice replies picker, Read voice replies checkbox, enabled controls, and AI off without a key read. The existing voice preference showed OpenAI Echo (paid) and was left unchanged. During inspection the first reopened process closed without a matching crash report; reopening succeeded and the complete window was verified. No paid request or microphone capture was performed. Enable AI now remains a user action before live testing; production audio/model/account access and voice quality remain unverified.

## Pause-to-send conversation sessions

Dan requested that speaking pauses trigger an answer without Stop/Send clicks. Added an explicitly confirmed, off-at-launch Conversation checkbox and selectable 1.2/1.8/2.5-second pause (default 1.8). Local PCM energy and changed partial recognition text must both settle; a final recognizer event alone cannot submit. The capture generation is invalidated and transcript frozen before exactly one Send. Existing local commands, bounded AI history, output cap and selected voice routing are preserved.

The microphone is off during request/playback. A completed reply rearms fresh device-only capture after a generation-checked 650 ms drain delay. Stop voice, Stop listening, focus loss, hide/close/minimize, changing voice/settings or clearing chat cancels the session/rearm. Each session is limited to 3 minutes/10 turns, no recognized speech to 15 seconds and a continuous utterance to 30 seconds. Hard timeouts freeze partial drafts without sending; recognition/API/playback errors stop automatic continuation. No persistent conversation opt-in, login capture, wake word, barge-in, microphone upload, paid test or credential retrieval was added.

Formatting, strict Clippy and all **23 Rust tests** passed. Loopback transport tests initially hit the sandbox's local-listen restriction; rerunning with local listening authorized passed. **59 native lifecycle/turn tests plus 6 Keychain policy checks** passed, using synthetic PCM/transcripts and intercepted capture/network effects. New checks exercise acoustic/transcript pause gating, no-empty/no-manual/no-busy submission, selected pause, exact single submission with late/duplicate callback rejection, Stop and focus-loss rearm cancellation, delayed next turn, visibility/time/turn limits, silent/long/manual timeouts and deadline expiry. Release build and bundle signature verified. Real pause quality and hands-free microphone/playback transitions remain for Dan to validate; no live conversation API request was sent by the agent.

The complete signed update is staged at `dist/pending-conversation-update/Mica.app`, with source/docs copied into the existing project. The current live app was idle with AI enabled and three prior turns. Automatic approval review rejected Quit because this new restart would discard that in-memory chat/key without fresh explicit restart approval. The running bundle and development executable were not replaced, no process was terminated, and no workaround was attempted. Applying the bundle and inspecting the new live controls remain blocked on restart approval. No commit/push was made; `git diff --check` passed.

Dan explicitly approved the restart ("please do"). Quit succeeded, the staged bundle and existing release executable were updated, and the installed signature verified. Reopened with `--no-keychain-restore`; actual UI showed Conversation unchecked, Pause 1.8 sec, Read voice replies checked, existing OpenAI Verse selection retained, and AI off without reading a key. The user began interacting during inspection, so a guarded disclosure-check click was not executed and no further UI changes were attempted. New controls are verified visible; live pause/capture/reply timing remains for Dan. No agent-triggered microphone capture or paid request occurred.

## Mica → LLM Usage metadata and estimated costs

Implemented the requested local usage integration. Mica serializes a strictly content-free versioned daily JSONL ledger under Application Support/Mica/usage (0700 directory/0600 files), and shows a warning if export fails. The runtime exports only attempted API turns, after completion/error. Local commands, AI-off requests and cached playback do not log paid usage. Typed Responses requests explicitly request default service tier. Prompt/reply/audio/key/error bodies cannot enter the schema; model identifiers are restricted public labels. Missing usage remains null, with unknown outcomes, not zero. Unit tests cover privacy, append permissions/failure/symlink refusal, schema and Realtime cached modality counters.

LLM Usage now has a native Mica selector and CLI `--source mica` / `--mica-home`, using the metadata folder only. It supports bounded scans, repeated refresh/appends/replacements/truncations, incomplete trailing lines, deduplication/conflict coverage, unknown schema/count warnings and exact default-model pricing. USD estimates are separated from API-reported billing in JSON and UI, use dated 2026-11-03 official standard rates, price cache/text/audio once, and report priced/unpriced/unknown coverage. Unknown models/tiers, malformed totals and ambiguous cached modality splits are unpriced. No historical backfill, actual bill reconciliation or persistent new credential is claimed.

Validation: **25 Mica Rust tests**, strict lint, release build/signature, **59 native lifecycle + 6 Keychain policy checks**; **41 llm-usage Rust unit + 13 CLI tests**, strict lint, **8 Swift tests** including three source variants, signed release build and installed signature checks. All calls use temporary files/fixtures or loopback mocks. No key retrieved, microphone capture started or paid API request made by the agent. The macOS 27 SDK lacks its SwiftUI macro plugin; tests/build passed with the installed macOS 26.5 SDK explicitly selected, without system changes. A shared fixture checks both serializers/readers. Old user modifications in llm-usage README/app/menu/UI were preserved, no commit or push made.

Both existing LLM Usage app copies were closed gracefully and updated, and exactly one installed copy reopened. Actual UI/screenshot verified Mica selected, live 5s status, zero records yet, explicit USD estimate, pricing date/coverage, audio subset labels, and no historical-data claim. Mica's signed update is staged at `dist/pending-usage-update/Mica.app`; its running bundle is unchanged. It currently holds an enabled AI session with three prior turns, so applying its update awaits explicit restart approval to clear that chat/session. Until that restart it cannot write the new ledger; the dashboard correctly remains empty. Live future-turn/provider billing verification remains unperformed.

## Display rename: Mica → Micah

Dan explicitly requested the spelling Micah. Updated native panel/header/menu/help/settings copy, local replies, AI instructions, bundle CFBundleName/CFBundleDisplayName, README/current technology documentation, build script and print-only launch-agent preview. The new bundle is `dist/Micah.app`; the local project directory, executable/package name, GitHub repository and existing old app copy are unchanged. The previously prepared usage export is included in this build. The usage dashboard's presentation label is Micah, while its `mica` enum/source/CLI values remain compatible with existing saved selections and records.

Continuity was verified statically without accessing real settings or credentials: unchanged `local.dan.desktop-companion` bundle ID, `local.dan.desktop-companion.openai` Keychain service/account, identical native Keychain adapter, existing NSUserDefaults keys/domain, Application Support/Mica paths, instance lock and distributed notification. No migration, secret copy, Keychain operation or data reset is needed. A new ad-hoc signature can still cause genuine macOS access/permission prompts; only Dan should answer them.

Formatting, strict lint, **25 companion Rust tests**, **59 native lifecycle + 6 Keychain policy checks**, **41 usage-reader unit + 13 CLI tests**, and **8 Swift tests** pass. Both release builds/signatures validate. Executing the built companion's local-only help prints “I'm Micah”; its plist reports Micah with the original bundle ID; the launch preview targets Micah.app and retains its old agent label. No launch agent is installed. The usage app builds with the installed 26.5 SDK workaround already documented.

Source changes and the new bundle are copied into the existing projects, preserving uncommitted changes. The running old companion session and active usage dashboard are not restarted or overwritten. Actual live renamed-window verification and future-request tracking still require a restart, which clears the current in-memory companion chat/key; explicit approval remains pending. The old `dist/Mica.app` and pending bundles are retained as recovery copies. No key was read, microphone capture initiated, paid request sent, repository renamed, commit created or changes pushed by the agent.
