# Micah — Desktop Companion

A small companion for Dan's Mac with offline local commands and optional OpenAI text answers. **Micah is the display name**; the project directory and executable remain `desktop-companion`. Rust owns command routing, API requests, conversation bounds and usage reporting; Objective-C provides the AppKit panel and Apple audio APIs. The diamond is deliberately a placeholder. Character and female voice design are deferred.

**AI starts off by default.** It can restore AI only if you explicitly save the enable-at-launch preference. Building/opening the app makes no OpenAI request and installs no service. Local commands work without credentials. You can save this app’s key in macOS Keychain; conversation history remains in memory only. Existing projects and the Token Grove sync worker are not modified.

## Start and stop

Requires macOS 13+, an existing Rust toolchain with Cargo, and Apple's Command Line Tools (`xcrun`, `clang`, `ar`, and `codesign`). Optional launch-agent preview also uses Python 3. The AI adapter adds reqwest/rustls, serde/serde_json and zeroize, pinned in Cargo.lock. Builds/tests use offline mode with cached dependencies; on a fresh machine run `cargo fetch --locked` first to download crates (not an API call). Current validation is on Apple Silicon; other Macs have not been tested.

```sh
cd ~/Daniel/desktop-companion
./scripts/build-app.sh
open "dist/Micah.app"
```

The built app is locally ad-hoc signed, not notarized or published. Open the bundle for a stable macOS privacy identity. Rebuilding can cause macOS to ask for voice permissions again. `cargo run --offline --locked` also opens the panel, but use the bundle for voice input.

The 460 × 735 floating panel accepts typed text; Return or Send submits reviewed input. Drag the title bar to move it; turn off “Float above windows” if desired. Close or Hide keeps the app available from the **◇ menu-bar icon**. Quit in the panel or that menu fully exits and stops audio. It uses no Dock icon. It starts only when opened, not at login.

Only one GUI instance runs per user, including app-bundle and Cargo/development launches. A second launch raises the existing window and exits before loading credentials. `~/Library/Application Support/Mica/instance.lock` contains only a PID; the operating-system lock is released automatically when the process exits. This prevents separate windows from having contradictory AI on/off state. Setup failures are displayed in a dialog and retained in an AI-off reply, including safe OSStatus diagnostics. Stopping voice input does not disable AI.

## What works

| Input | Result |
| --- | --- |
| `help`, `hi`, `hello` | Introduction and command hints |
| `mac status`, `how is my Mac?` | Current uptime, battery/power source, macOS version |
| `pi status`, `pi sync`, `sync status` | Read-only local launchd status for `com.tokengrove.sync` |
| `time`, `what time is it?` | Current Mac date/time and timezone |
| `capabilities`, `voice`, `what can you do?` | Honest feature and privacy limits |
| Anything else | AI off: no request. AI enabled: one OpenAI request on Send or an opted-in conversation pause |

Matching ignores case, surrounding speech punctuation/quotes, and repeated or Unicode whitespace. The exact observed transcription `Max status` is an alias for `mac status`; there is no fuzzy matching in the local dispatcher. Every result shows **Submitted** text, **Matched** route, source and usage. Local command text and results are never added to AI history or sent to OpenAI. The Rust local core runs only fixed read-only commands; each child has a three-second timeout. All status checks and AI requests run off the UI thread. AI text is displayed, never executed.

## Optional OpenAI conversation

This implementation is prepared for Dan's own API key, and Dan has reported successful live text and voice replies. The agent tests use fixtures, without accessing his key or making paid calls. API use is billed separately from ChatGPT subscriptions. No prices are hardcoded and no account model access is assumed.

Open **AI settings…** and enter the key yourself in the secure field. To avoid re-entering it later, select **Save/replace key in macOS Keychain** and click **Save settings**. This saves the key without enabling AI or sending a request. On later launches, leave the key blank and click **Enable AI now** to load only Micah’s saved item. To replace it, enter the new key and explicitly select Save/replace again. Never paste a key into chat, source, Git, terminal arguments or logs. Micah does not import credentials from environment variables, other apps or files. Runtime key owners are zeroized on drop; UI/framework/HTTP copies can remain in process memory until released.

The editable default model is **`gpt-5.4-nano`**, verified in current official documentation as an economical option for simple tasks; the default output cap is **512 tokens per request**, configurable from 32 to 4096. For this default model the request uses reasoning effort `none`. Other model IDs use their own reasoning defaults and may reject unsupported parameters or require account access. See [the model reference](https://developers.openai.com/api/docs/models/gpt-5.4-nano).

The settings dialog explains the exact transmission before **Enable AI now**. Enabling itself sends nothing; it also saves the non-secret settings. **Save settings** always leaves AI off now. Once enabled, pressing Send (or pausing in an explicitly started conversation session) for non-command text sends that reviewed text, fixed companion instructions, and **up to 3 previous successful AI question/answer pairs, capped at 12,000 UTF-8 bytes**, to `https://api.openai.com/v1/responses`. Current input is limited to 2,000 UTF-8 bytes. Each retained assistant answer is limited to 4,000 characters and old whole pairs are evicted to meet the byte bound. Local status output, audio, repository files, attachments and codebases are not automatically uploaded. There are no AI tools, file APIs, code execution or automatic actions.

History exists only in the running process. **Clear AI chat** removes history. **Disable AI** clears the current session key/history but leaves the saved key and startup preference unchanged. To keep AI off across launches, uncheck **Enable AI at app launch using the saved key** and Save settings. To delete the stored credential, choose **Remove saved key** and confirm; it deletes only Micah’s exact Keychain item, clears current AI state, and disables the saved startup preference. A missing key is already removed; a denied deletion is reported, never silently claimed successful. Model/cap settings remain. Changing settings starts a new history; Quit ends the process. It is not connected to ChatGPT conversation history or subscriptions. Requests set `store: false` and send bounded messages explicitly, without server conversation IDs. This is not a promise of zero provider retention; OpenAI's applicable data policies still apply.

Every returned answer shows **API-reported input, cached-input, output, reasoning and total tokens**. Cached input is a subset of input and reasoning is a subset of output; neither is added again. Missing fields say unavailable. These counts are not a cost estimate. The UI explicitly says **Cost estimate: not calculated**; use the actual account billing and current model rates for monetary cost. The output cap includes visible text and any reasoning, so it is **not** a spending limit or a bound on input charges. A cap-limited response is labeled incomplete and is not added to history.

There are no automatic retries. HTTPS redirects are refused; connection and total timeouts are bounded (8 and 30 seconds), response bodies are limited to 256 KiB, and provider error bodies are not displayed or logged. Authentication, quota/rate-limit, invalid-model and service failures are shown without raw server details. A timeout or interrupted request may still have completed and incurred usage; missing usage is not proof of zero cost. Hiding or quitting does not promise cancellation at the provider. A future live check requires Dan's separate approval and own credential entry.

Contract: [OpenAI Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create). Billing: [OpenAI explains separate ChatGPT/API billing](https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform).

**Pi status is deliberately local:** it reads the already-existing Mac sync agent's state, runs, and last exit code via `launchctl print`. A waiting agent can be healthy between scheduled runs; exit code zero does not establish a recent transfer or Pi health. This MVP does not read private SSH configuration, contact the Pi, trigger sync, query remote systemd, or restart anything. The Mac status action is independently useful without the Pi.

## Saved settings and Keychain details

Only model ID, output cap, enable-at-launch choice, a saved-key marker and schema version are stored in `~/Library/Application Support/Mica/settings.json`. It contains no key or conversation. Writes use a private mode-0600 temporary file and atomic replacement; invalid/oversized settings fail closed with AI off. Saving these settings does not access Keychain unless you explicitly select saving a newly entered key. A saved-key marker is a preference, not a live existence probe.

The credential is a generic-password item with service `local.dan.desktop-companion.openai` and account `default`. This local ad-hoc build explicitly uses the encrypted macOS default file-based Keychain (normally login), scoped to that one Keychain and exact service/account. It does not use the entitlement-dependent data-protection/iCloud Keychain, access groups, or custom broad trusted-app lists. The system default ACL trusts the calling app; macOS may ask you to authorize access or unlock the Keychain. Only you should handle that system prompt. Keychain work runs off the UI thread. This backend uses the file-based Keychain lock/ACL model, not the iOS `WhenUnlockedThisDeviceOnly` accessibility class. No keys are stored in plaintext preferences, exported, logged or committed.

**Enable AI at app launch using the saved key** is unchecked by default. It takes effect only after an explicit Save and requires a saved key. Normal startup then loads this exact key into memory and enables routing, but never sends a request until Send or an explicitly started conversation turn. Without that preference, startup loads only non-secret settings, with no Keychain access. Removing the key disables the saved preference. Settings and Keychain writes are separate operations; partial failures are reported (for example, a successful key replacement followed by a failed settings write), not hidden or rolled back by deleting credentials.

The previous data-protection backend failed on this Mac with OSStatus -34018 (missing signing entitlements). The file-based macOS Keychain backend avoids that entitlement requirement. Actual save/reload/replacement/removal still requires Dan’s own verification and may show a Keychain authorization prompt, especially after ad-hoc rebuilds. No signing identity or Keychain permissions were changed by the agent. If optional saving fails after you type a valid key and click **Enable AI now**, AI remains enabled for that session and the result explicitly says the key/settings were not saved. There is no plaintext persistence fallback. A blank field with an unavailable saved key still leaves AI off with a specific error.

For credential-free UI verification, `open -n "dist/Micah.app" --args --no-keychain-restore` suppresses saved-key restoration even if enable-at-launch was saved. This flag changes no saved preference. The delivered verification instance was opened this way. Exit it and open normally when ready to use an explicitly saved startup preference.

Apple references: [Mac Keychain implementations (TN3137)](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains), [password encryption via SecItemAdd](https://developer.apple.com/documentation/security/secitemadd(_:_:)), [Apple DTS on default caller-only ACLs](https://developer.apple.com/forums/thread/836816), and [non-sensitive preferences guidance](https://developer.apple.com/documentation/foundation/userdefaults).

## Voice input and output

### Optional OpenAI voices (paid)

Use the **Voice replies** picker to choose **Mac voice (local)** or a built-in OpenAI voice such as **Marin, Coral or Sage**. Mac voice stays the default. Choosing an OpenAI voice shows an explicit paid-audio/transmission disclosure before saving that non-secret preference. It is an API voice, not an export or verified copy of this chat's voice.

With OpenAI selected and Read voice replies on, a voice-origin **Send** for a non-command AI question uses one `gpt-realtime-2.1-mini` response for both generated speech and its matching displayed transcript. It replaces the text-model request for that turn, rather than making a second generation to read the answer. Typed questions retain the configured text model, and local commands retain local execution/Mac speech. No microphone audio is uploaded: the request contains submitted text and the same bounded text-only history. There are no remote audio input events, server VAD, files or tools. Conversation mode detects pauses locally.

The existing output cap applies to audio/text output tokens and can truncate speech. The response shows API-reported total/input/output tokens plus text/audio/cached subsets; audio has separate rates and no monetary estimate is calculated. This is not a spending limit. New connections are created only after Send or an opted-in conversation pause, issue one out-of-band response and close afterward. The client bounds connection/response time, event size/count, transcript length and decoded PCM to 60 seconds (24 kHz mono PCM16, 2.88 MB). Audio is buffered in memory for playback, so this MVP waits for completion rather than playing chunks live. No audio file/history is written.

**Replay voice** reuses the cached audio without another API request. **Stop voice** stops playback and requests cancellation of pending audio work; usage may already have occurred. Missing/unplayable audio falls back to local speech when a transcript exists. A failed audio request does not silently incur a second paid text request: switch to Mac voice and Send again yourself if needed. Manual Speak reply for a text-only result uses the Mac voice.

This uses the current Realtime audio workflow; the older Speech API models are documented for shutdown on January 6, 2027 and are not used here. References: [Realtime conversations and voices](https://developers.openai.com/api/docs/guides/realtime-conversations), [client response.create schema](https://developers.openai.com/api/reference/resources/realtime/client-events#response.create), [response.done usage](https://developers.openai.com/api/reference/resources/realtime/server-events#response.done), [model](https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini), [Speech API migration notice](https://developers.openai.com/api/docs/guides/text-to-speech).

Live audio API access and voice quality have **not** been tested with a real key by the agent. All transport/usage/audio tests use fixtures and loopback mocks. Selecting a voice sends no preview request; trying it via Send will incur normal API usage.

### Conversation mode: pause to send

Check **Conversation: pause to send**, read the confirmation, then click **Click to talk** once. The checkbox is off on every launch and does not itself open the microphone. A quiet pause automatically submits the visible recognized transcript, receives a text/spoken reply with your existing voice selection, then resumes listening after playback plus a 650 ms audio-drain delay. You do not need to press Stop and Send for each turn. With **Read voice replies** off, listening resumes after the text reply instead.

Choose **Pause: 1.2, 1.8 (default), or 2.5 sec** before starting. Both microphone energy and recognition-text updates must have settled for that interval. This is local energy/partial-transcript detection, not a model that understands whether your thought is complete. Longer thinking pauses can submit early; background speech/noise can create a false turn or delay it. Use 2.5 seconds or manual mode when needed. The microphone is off while requests/replies are in progress; there is no interruption/barge-in or wake word.

**Stop voice**, Stop listening, hiding/closing/minimizing Micah, switching away, or turning the checkbox off ends the active session and cancels any scheduled microphone restart. A session lasts at most **3 minutes or 10 submitted turns**. No recognized speech for 15 seconds, uninterrupted speech reaching 30 seconds, recognition/API/playback failures, or session expiry stops for review. A hard timeout does not send a partial draft automatically. A final recognizer result still waits for the selected pause.

Each automatically submitted non-command turn can incur the existing OpenAI text/audio charges. The output-token cap still applies per response; neither the cap nor the session limit is a monetary budget. Local commands remain local. No microphone bytes are sent to OpenAI, no capture runs at login, and no conversation-mode preference is persisted. The transcript is frozen and its capture generation invalidated before submission, preventing late callbacks or duplicate timer ticks from sending it twice.

The implementation uses Apple's [partial recognition results](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/shouldreportpartialresults), [on-device request requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition), and in-memory [PCM buffer samples](https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer). Pause quality depends on the room, microphone and installed recognizer; live human validation is still required.

### Local recognition and speech

**Read voice replies** is on by default: submitting a reviewed voice transcript displays the answer and automatically reads its answer text with the installed macOS system voice. Typed submissions remain text-only unless you click **Speak reply**. The playback switch is saved as a non-secret macOS preference. **Stop voice** cancels current speech and pending automatic playback; hidden/minimized windows stay silent. Playback cannot overlap microphone capture or permission setup. Token metadata is not read aloud. This works for local commands and AI text answers. This local-output option has no audio API charge. OpenAI voices are a separate opt-in above. The exact voice of the assistant in the conversation is **not included or verified as reusable**. AI text requests use the optional setup above; recognition and Mac speech output remain local.

**Click to talk…** is an experimental device-only input adapter for English (US):

1. A capability guard rejects devices without `supportsOnDeviceRecognition`. No server fallback is attempted.
2. Micah's explanatory confirmation appears once, after which acceptance is remembered as a non-secret macOS preference. It checks existing Speech Recognition and Microphone authorization and requests only permissions still undetermined. Denied/restricted permissions produce an off/error state; Micah never changes privacy settings. macOS can ask again after an ad-hoc rebuild changes the app identity. All permission/capture work still starts only from a click.
3. The audio request sets `requiresOnDeviceRecognition = YES`, and checks support again before capture. No model downloads are requested by this app. If the installed recognizer is unavailable, it reports that and stays off.
4. In normal manual mode, a clearly labeled recording runs for at most 15 seconds. **Send and input editing are disabled while listening.** Stop voice, Stop listening, Hide, close, minimize, leaving the app, or Quit stops capture. Stop invalidates pending permission and recognition callbacks, so late results cannot overwrite the reviewed text and late approval cannot start a canceled session.
5. Stop freezes the latest transcript in the input field and enables **Review → Send**. Edit it if needed, then press Send yourself; normal manual mode does not submit recognized speech automatically. Manual Stop or timeout may retain a partial transcript. The active AppKit field editor and backing field stay synchronized, and Send snapshots the editor's actual reviewed text before ending editing.

Audio is passed in memory to Apple's on-device recognizer. The app writes no audio files or transcript history; the latest result and input are visible in memory until replaced or Quit. macOS manages its own permissions and speech components. There is no wake word, always-listening mode, keyboard monitoring, or screen capture. You can revoke permissions in System Settings → Privacy & Security → Microphone / Speech Recognition.

Initial transcription attempts were blocked by **`kLSRErrorDomain 201`, “Siri and Dictation are disabled.”** Dan then enabled system Dictation himself and reported speech appearing in the input. The actual UI exposed `Max status` after he said “Mac status”; that exact speech variant is now a supported alias. Micah shows native errors and instructions when the system service refuses a request. **Voice info** inspects the app's actual speech/microphone authorization without recording. A CLI probe may have a different permission identity (and sandboxed probes may falsely appear unsupported). Dan also confirmed Speak reply reads time/date successfully. No privacy setting was changed by the agent.

If Dan later chooses to review system Dictation, Apple places it at System Settings → Keyboard → Dictation. Read the system privacy explanation before enabling anything; system Dictation has its own behavior and availability. Micah will still require device-only recognition and refuse server fallback. This is a user decision, not an automatic setup step. See [Apple's Dictation guide](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac). Text and system speech output remain usable with Dictation disabled.

## Check and command-line use

```sh
./scripts/check.sh
./scripts/build-app.sh
./target/release/desktop-companion --ask 'mac status'
./target/release/desktop-companion --ask 'pi status'
./target/release/desktop-companion --ask 'capabilities'
./target/release/desktop-companion --voice-check
# Synthetic native editing / transcript lifecycle checks (Mac GUI session required):
./target/release/desktop-companion --native-self-test
```

`--ask` remains a local-only CLI. `--voice-check` inspects support and the CLI process's authorization enum without requesting permissions or recording. Use **Voice info** for app permissions. Rust tests cover local routing, speech variants, bounded AI history/request construction, API usage parsing, credential-free behavior and real HTTP-client calls against loopback fixtures (success, authentication, quota, service error, redirect, malformed JSON and timeout). The native self-test uses synthetic text to check AppKit editing, voice lifecycle and usage rendering without microphone capture or permission requests. Native code builds with warnings treated as errors. See [docs/VALIDATION.md](docs/VALIDATION.md) for actual results and limits.

## Optional launch at login — prepared only

```sh
./scripts/launch-agent-preview.sh > /tmp/desktop-companion-preview.plist
plutil -lint /tmp/desktop-companion-preview.plist
```

This only emits a plist for review, with this checkout's absolute app path. It does **not** write into `~/Library/LaunchAgents`, call `launchctl`, or enable persistent startup. It has no KeepAlive loop. The app must remain at that path for this proposed agent to work. Installation and activation require a separate explicit go-ahead. No installer is run as part of the build.

## Structure and next steps

- `src/lib.rs`: allowlisted Rust parser and read-only checks.
- `src/ai.rs`: Responses HTTPS adapter, bounded context, token parsing and fixture HTTP tests.
- `src/voice.rs`: optional text-in/audio-out Realtime adapter, bounded PCM/WAV handling, usage and mock WebSocket tests.
- `src/runtime.rs`: in-memory credentials, AI/local routing and conversation state.
- `src/persistence.rs`: validated non-secret preferences and explicit Keychain policy with fake-store tests.
- `native/keychain.m`: narrow macOS Security/LocalAuthentication adapter; no secret logging.
- `src/main.rs`: CLI and owned-string JSON C ABI to the native bridge.
- `native/companion.m`: native panel, tray lifecycle, worker dispatch, system TTS, device-only speech adapter.
- `native/Info.plist`: accessory-app identity and permission explanations.
- `scripts/`: offline build/check and a print-only launch-agent preview.
- [docs/TECHNOLOGY.md](docs/TECHNOLOGY.md): UI and voice choices, Apple references, and alternatives.

GitHub originally reported more Objective-C because its language bar counts source bytes, not where decision-making happens: the committed UI/audio implementation was 24,931 bytes of Objective-C versus 13,531 bytes of Rust (including build.rs). The bridge owns the concrete AppKit layout, menus, field editor, permission callbacks and Apple speech lifecycle, which is more code than the original small Rust command engine. The new API/network/history/usage behavior is Rust. See [docs/TECHNOLOGY.md](docs/TECHNOLOGY.md) for the actual split and tradeoff.

Next useful additions could be a separately approved live API verification, user-approved Pi health endpoint, and then character design. No real key setup, paid request, publishing, Git commit/push, or login-startup installation is performed by this implementation task.

# Micah

## LLM Usage integration

Micah now exports content-free usage metadata to `~/Library/Application Support/Mica/usage/usage-<UTC-day-number>.jsonl`, using private directory/file permissions (0700/0600). Records contain only schema/source, locally generated event/session IDs, timestamp, configured public model ID, route/outcome/service tier, and API-reported token counters, including audio/cache subsets. They contain no key, account identifier, prompt, instructions, answer, transcript, raw provider errors or audio. Local commands, AI-off submissions and cached audio replay create no paid-usage record. No new network destination or organization/admin key is used.

In the updated **LLM Usage** app, choose **Micah**. It refreshes these records every five seconds and shows a separate **Estimated API cost · USD** subtotal. Rates were verified against [OpenAI pricing](https://developers.openai.com/api/docs/pricing) on 2026-11-03 for the current `gpt-5.4-nano` text and `gpt-realtime-2.1-mini` voice models. Estimates are standard-rate approximations, not account billing; tax, credits, negotiated rates and other tiers are excluded. Missing or inconsistent usage, unsupported model/tier and unknown mixed-modality cache splits are explicitly unpriced, never assumed free. Output reasoning/cache/audio subsets are not added twice. Responses requests explicitly select the default service tier.

Only future requests made by the updated app can be tracked. Earlier displayed counts were not persisted and cannot be reconstructed automatically. Counts are written after request completion/failure; abrupt termination may leave provider activity unrecorded. Failure to write the ledger adds a visible warning to that reply without retrying the API request. Unknown failed/cancelled/timeout attempts have no invented zero counts. Daily files are bounded to 16 MiB, never upload themselves, and remain until you remove them; clearing chat does not remove usage metadata. The tracker reads only this usage folder, never Micah's settings or Keychain. The shared synthetic schema fixture is `fixtures/mica-usage-v1.json` in both projects.

## Renamed to Micah

The app is now **Micah** and builds as `dist/Micah.app`. The existing `~/Daniel/desktop-companion` project, `desktop-companion` executable and GitHub repository are unchanged. The bundle identifier `local.dan.desktop-companion`, Keychain service/account, distributed notification, instance lock and preferences domain are unchanged. Existing settings and usage files deliberately stay under `~/Library/Application Support/Mica`; the ledger source/CLI flag stays `mica` for compatibility. LLM Usage displays **Micah** while retaining its existing saved source/folder preference. No settings or credentials are copied, migrated, reset or read by this rename. macOS may still ask for Keychain or speech permission after an ad-hoc rebuild; only the user should answer that prompt.

Quit the old app before opening `dist/Micah.app`; both bundle names share the single-instance lock. Opening the new name while the old process is running raises the existing process and does not hot-reload it. The old `dist/Mica.app` is left as a recovery copy until you choose to remove it; build and launch-preview scripts target only Micah. No launch-at-login item is installed.
