# Mica — Desktop Companion

A small companion for Dan's Mac with offline local commands and optional OpenAI text answers. **Mica is the provisional display name**; the project directory and executable remain `desktop-companion`. Rust owns command routing, API requests, conversation bounds and usage reporting; Objective-C provides the AppKit panel and Apple audio APIs. The diamond is deliberately a placeholder. Character and female voice design are deferred.

**AI starts off by default.** It can restore AI only if you explicitly save the enable-at-launch preference. Building/opening the app makes no OpenAI request and installs no service. Local commands work without credentials. You can save this app’s key in macOS Keychain; conversation history remains in memory only. Existing projects and the Token Grove sync worker are not modified.

## Start and stop

Requires macOS 13+, an existing Rust toolchain with Cargo, and Apple's Command Line Tools (`xcrun`, `clang`, `ar`, and `codesign`). Optional launch-agent preview also uses Python 3. The AI adapter adds reqwest/rustls, serde/serde_json and zeroize, pinned in Cargo.lock. Builds/tests use offline mode with cached dependencies; on a fresh machine run `cargo fetch --locked` first to download crates (not an API call). Current validation is on Apple Silicon; other Macs have not been tested.

```sh
cd ~/Daniel/desktop-companion
./scripts/build-app.sh
open "dist/Mica.app"
```

The built app is locally ad-hoc signed, not notarized or published. Open the bundle for a stable macOS privacy identity. Rebuilding can cause macOS to ask for voice permissions again. `cargo run --offline --locked` also opens the panel, but use the bundle for voice input.

The 460 × 650 floating panel accepts typed text; Return or Send submits reviewed input. Drag the title bar to move it; turn off “Float above windows” if desired. Close or Hide keeps the app available from the **◇ menu-bar icon**. Quit in the panel or that menu fully exits and stops audio. It uses no Dock icon. It starts only when opened, not at login.

Only one GUI instance runs per user, including app-bundle and Cargo/development launches. A second launch raises the existing window and exits before loading credentials. `~/Library/Application Support/Mica/instance.lock` contains only a PID; the operating-system lock is released automatically when the process exits. This prevents separate windows from having contradictory AI on/off state. Setup failures are displayed in a dialog and retained in an AI-off reply, including safe OSStatus diagnostics. Stopping voice input does not disable AI.

## What works

| Input | Result |
| --- | --- |
| `help`, `hi`, `hello` | Introduction and command hints |
| `mac status`, `how is my Mac?` | Current uptime, battery/power source, macOS version |
| `pi status`, `pi sync`, `sync status` | Read-only local launchd status for `com.tokengrove.sync` |
| `time`, `what time is it?` | Current Mac date/time and timezone |
| `capabilities`, `voice`, `what can you do?` | Honest feature and privacy limits |
| Anything else | AI off: no request. AI enabled: one OpenAI text request on manual Send |

Matching ignores case, surrounding speech punctuation/quotes, and repeated or Unicode whitespace. The exact observed transcription `Max status` is an alias for `mac status`; there is no fuzzy matching in the local dispatcher. Every result shows **Submitted** text, **Matched** route, source and usage. Local command text and results are never added to AI history or sent to OpenAI. The Rust local core runs only fixed read-only commands; each child has a three-second timeout. All status checks and AI requests run off the UI thread. AI text is displayed, never executed.

## Optional OpenAI conversation

This implementation is prepared for Dan's own API key, but **no real paid request has been made or verified**. API use is billed separately from ChatGPT subscriptions. No prices are hardcoded and no account model access is assumed.

Open **AI settings…** and enter the key yourself in the secure field. To avoid re-entering it later, select **Save/replace key in macOS Keychain** and click **Save settings**. This saves the key without enabling AI or sending a request. On later launches, leave the key blank and click **Enable AI now** to load only Mica’s saved item. To replace it, enter the new key and explicitly select Save/replace again. Never paste a key into chat, source, Git, terminal arguments or logs. Mica does not import credentials from environment variables, other apps or files. Runtime key owners are zeroized on drop; UI/framework/HTTP copies can remain in process memory until released.

The editable default model is **`gpt-5.4-nano`**, verified in current official documentation as an economical option for simple tasks; the default output cap is **512 tokens per request**, configurable from 32 to 4096. For this default model the request uses reasoning effort `none`. Other model IDs use their own reasoning defaults and may reject unsupported parameters or require account access. See [the model reference](https://developers.openai.com/api/docs/models/gpt-5.4-nano).

The settings dialog explains the exact transmission before **Enable AI now**. Enabling itself sends nothing; it also saves the non-secret settings. **Save settings** always leaves AI off now. Once enabled, manually pressing Send for non-command text sends that reviewed text, fixed companion instructions, and **up to 3 previous successful AI question/answer pairs, capped at 12,000 UTF-8 bytes**, to `https://api.openai.com/v1/responses`. Current input is limited to 2,000 UTF-8 bytes. Each retained assistant answer is limited to 4,000 characters and old whole pairs are evicted to meet the byte bound. Local status output, audio, repository files, attachments and codebases are not automatically uploaded. There are no AI tools, file APIs, code execution or automatic actions.

History exists only in the running process. **Clear AI chat** removes history. **Disable AI** clears the current session key/history but leaves the saved key and startup preference unchanged. To keep AI off across launches, uncheck **Enable AI at app launch using the saved key** and Save settings. To delete the stored credential, choose **Remove saved key** and confirm; it deletes only Mica’s exact Keychain item, clears current AI state, and disables the saved startup preference. A missing key is already removed; a denied deletion is reported, never silently claimed successful. Model/cap settings remain. Changing settings starts a new history; Quit ends the process. It is not connected to ChatGPT conversation history or subscriptions. Requests set `store: false` and send bounded messages explicitly, without server conversation IDs. This is not a promise of zero provider retention; OpenAI's applicable data policies still apply.

Every returned answer shows **API-reported input, cached-input, output, reasoning and total tokens**. Cached input is a subset of input and reasoning is a subset of output; neither is added again. Missing fields say unavailable. These counts are not a cost estimate. The UI explicitly says **Cost estimate: not calculated**; use the actual account billing and current model rates for monetary cost. The output cap includes visible text and any reasoning, so it is **not** a spending limit or a bound on input charges. A cap-limited response is labeled incomplete and is not added to history.

There are no automatic retries. HTTPS redirects are refused; connection and total timeouts are bounded (8 and 30 seconds), response bodies are limited to 256 KiB, and provider error bodies are not displayed or logged. Authentication, quota/rate-limit, invalid-model and service failures are shown without raw server details. A timeout or interrupted request may still have completed and incurred usage; missing usage is not proof of zero cost. Hiding or quitting does not promise cancellation at the provider. A future live check requires Dan's separate approval and own credential entry.

Contract: [OpenAI Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create). Billing: [OpenAI explains separate ChatGPT/API billing](https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform).

**Pi status is deliberately local:** it reads the already-existing Mac sync agent's state, runs, and last exit code via `launchctl print`. A waiting agent can be healthy between scheduled runs; exit code zero does not establish a recent transfer or Pi health. This MVP does not read private SSH configuration, contact the Pi, trigger sync, query remote systemd, or restart anything. The Mac status action is independently useful without the Pi.

## Saved settings and Keychain details

Only model ID, output cap, enable-at-launch choice, a saved-key marker and schema version are stored in `~/Library/Application Support/Mica/settings.json`. It contains no key or conversation. Writes use a private mode-0600 temporary file and atomic replacement; invalid/oversized settings fail closed with AI off. Saving these settings does not access Keychain unless you explicitly select saving a newly entered key. A saved-key marker is a preference, not a live existence probe.

The credential is a generic-password item with service `local.dan.desktop-companion.openai` and account `default`. This local ad-hoc build explicitly uses the encrypted macOS default file-based Keychain (normally login), scoped to that one Keychain and exact service/account. It does not use the entitlement-dependent data-protection/iCloud Keychain, access groups, or custom broad trusted-app lists. The system default ACL trusts the calling app; macOS may ask you to authorize access or unlock the Keychain. Only you should handle that system prompt. Keychain work runs off the UI thread. This backend uses the file-based Keychain lock/ACL model, not the iOS `WhenUnlockedThisDeviceOnly` accessibility class. No keys are stored in plaintext preferences, exported, logged or committed.

**Enable AI at app launch using the saved key** is unchecked by default. It takes effect only after an explicit Save and requires a saved key. Normal startup then loads this exact key into memory and enables routing, but never sends a request until manual Send. Without that preference, startup loads only non-secret settings, with no Keychain access. Removing the key disables the saved preference. Settings and Keychain writes are separate operations; partial failures are reported (for example, a successful key replacement followed by a failed settings write), not hidden or rolled back by deleting credentials.

The previous data-protection backend failed on this Mac with OSStatus -34018 (missing signing entitlements). The file-based macOS Keychain backend avoids that entitlement requirement. Actual save/reload/replacement/removal still requires Dan’s own verification and may show a Keychain authorization prompt, especially after ad-hoc rebuilds. No signing identity or Keychain permissions were changed by the agent. If optional saving fails after you type a valid key and click **Enable AI now**, AI remains enabled for that session and the result explicitly says the key/settings were not saved. There is no plaintext persistence fallback. A blank field with an unavailable saved key still leaves AI off with a specific error.

For credential-free UI verification, `open -n "dist/Mica.app" --args --no-keychain-restore` suppresses saved-key restoration even if enable-at-launch was saved. This flag changes no saved preference. The delivered verification instance was opened this way. Exit it and open normally when ready to use an explicitly saved startup preference.

Apple references: [Mac Keychain implementations (TN3137)](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains), [password encryption via SecItemAdd](https://developer.apple.com/documentation/security/secitemadd(_:_:)), [Apple DTS on default caller-only ACLs](https://developer.apple.com/forums/thread/836816), and [non-sensitive preferences guidance](https://developer.apple.com/documentation/foundation/userdefaults).

## Voice, without a paid service

**Speak reply** uses an installed English macOS system voice through `AVSpeechSynthesizer`, only on click, for either a local reply or an AI text answer. There is no voice cloning or paid audio API. The exact voice of the assistant in the conversation is **not included or verified as reusable**. AI text requests use the optional setup above; recognition and speech output remain local.

**Click to talk…** is an experimental device-only input adapter for English (US):

1. A capability guard rejects devices without `supportsOnDeviceRecognition`. No server fallback is attempted.
2. After an explanatory confirmation, macOS may request Speech Recognition and Microphone permissions. Those are only requested from the click flow. Cancel or deny and keep using text.
3. The audio request sets `requiresOnDeviceRecognition = YES`, and checks support again before capture. No model downloads are requested by this app. If the installed recognizer is unavailable, it reports that and stays off.
4. A clearly labeled recording runs for at most 15 seconds. **Send and input editing are disabled while listening.** Stop voice, Stop listening, Hide, close, minimize, leaving the app, or Quit stops capture. Stop invalidates pending permission and recognition callbacks, so late results cannot overwrite the reviewed text and late approval cannot start a canceled session.
5. Stop freezes the latest transcript in the input field and enables **Review → Send**. Edit it if needed, then press Send yourself; recognized speech never executes a command automatically. Manual Stop or timeout may retain a partial transcript. The active AppKit field editor and backing field stay synchronized, and Send snapshots the editor's actual reviewed text before ending editing.

Audio is passed in memory to Apple's on-device recognizer. The app writes no audio files or transcript history; the latest result and input are visible in memory until replaced or Quit. macOS manages its own permissions and speech components. There is no wake word, always-listening mode, keyboard monitoring, or screen capture. You can revoke permissions in System Settings → Privacy & Security → Microphone / Speech Recognition.

Initial transcription attempts were blocked by **`kLSRErrorDomain 201`, “Siri and Dictation are disabled.”** Dan then enabled system Dictation himself and reported speech appearing in the input. The actual UI exposed `Max status` after he said “Mac status”; that exact speech variant is now a supported alias. Mica shows native errors and instructions when the system service refuses a request. **Voice info** inspects the app's actual speech/microphone authorization without recording. A CLI probe may have a different permission identity (and sandboxed probes may falsely appear unsupported). Dan also confirmed Speak reply reads time/date successfully. No privacy setting was changed by the agent.

If Dan later chooses to review system Dictation, Apple places it at System Settings → Keyboard → Dictation. Read the system privacy explanation before enabling anything; system Dictation has its own behavior and availability. Mica will still require device-only recognition and refuse server fallback. This is a user decision, not an automatic setup step. See [Apple's Dictation guide](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac). Text and system speech output remain usable with Dictation disabled.

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

# mica
