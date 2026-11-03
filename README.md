# Mica — Desktop Companion

A small offline companion for Dan's Mac. **Mica is the provisional display name**; the project directory and executable remain `desktop-companion`. The command engine is Rust; a thin Objective-C AppKit bridge provides the floating panel, menu-bar control, and Apple audio APIs. The diamond is deliberately a placeholder. Character and female voice design are deferred.

This is a useful local control, **not an AI conversation model**. It has no API keys, subscriptions, network client, telemetry, or saved conversations. Building it installs no service. Existing projects and the Token Grove sync worker are not modified.

## Start and stop

Requires macOS 13+, an existing Rust toolchain with Cargo, and Apple's Command Line Tools (`xcrun`, `clang`, `ar`, and `codesign`). Optional launch-agent preview also uses Python 3. The project has **zero Cargo dependencies**; builds and tests work offline. Current validation is on Apple Silicon; other Macs have not been tested.

```sh
cd ~/Daniel/desktop-companion
./scripts/build-app.sh
open "dist/Mica.app"
```

The built app is locally ad-hoc signed, not notarized or published. Open the bundle for a stable macOS privacy identity. Rebuilding can cause macOS to ask for voice permissions again. `cargo run --offline --locked` also opens the panel, but use the bundle for voice input.

The 460 × 550 floating panel accepts typed text; Return or Send runs a command. Drag the title bar to move it; turn off “Float above windows” if desired. Close or Hide keeps the app available from the **◇ menu-bar icon**. Quit in the panel or that menu fully exits and stops audio. It uses no Dock icon. It starts only when opened, not at login.

## What works

| Input | Result |
| --- | --- |
| `help`, `hi`, `hello` | Introduction and command hints |
| `mac status`, `how is my Mac?` | Current uptime, battery/power source, macOS version |
| `pi status`, `pi sync`, `sync status` | Read-only local launchd status for `com.tokengrove.sync` |
| `time`, `what time is it?` | Current Mac date/time and timezone |
| `capabilities`, `voice`, `what can you do?` | Honest feature and privacy limits |
| Anything else | Explicit unsupported response; no action |

Matching ignores case, surrounding speech punctuation/quotes, and repeated or Unicode whitespace. The exact observed transcription `Max status` is an alias for `mac status`; there is no fuzzy matching or natural-language understanding beyond the allowlist. Every result shows the **Submitted** text and **Matched** command, so a misrecognition is visible. Input never becomes shell code, command arguments, an AI prompt, or a remote request. The Rust core runs only fixed read-only commands; each child has a three-second timeout. Status checks run off the UI thread. Quick buttons are available too.

**Pi status is deliberately local:** it reads the already-existing Mac sync agent's state, runs, and last exit code via `launchctl print`. A waiting agent can be healthy between scheduled runs; exit code zero does not establish a recent transfer or Pi health. This MVP does not read private SSH configuration, contact the Pi, trigger sync, query remote systemd, or restart anything. The Mac status action is independently useful without the Pi.

## Voice, without a paid service

**Speak reply** uses an installed English macOS system voice through `AVSpeechSynthesizer`, only on click. There is no voice cloning. The exact voice of the assistant in the conversation is **not included or verified as reusable**. No API or model is configured. There is no free-form spoken AI conversation yet.

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

`--voice-check` inspects support and the CLI process's authorization enum without requesting permissions or recording. Use the app's **Voice info** button for its own permission state. Six Rust tests verify speech variants, arbitrary-input rejection, status scope, unavailable commands, timeout cleanup, and honest capability disclosures. The native self-test exercises sixteen checks against real AppKit editing and transcript lifecycle methods using synthetic strings, without microphone capture or permission requests. Native code builds with warnings treated as errors. See [docs/VALIDATION.md](docs/VALIDATION.md) for actual run results and remaining manual checks.

## Optional launch at login — prepared only

```sh
./scripts/launch-agent-preview.sh > /tmp/desktop-companion-preview.plist
plutil -lint /tmp/desktop-companion-preview.plist
```

This only emits a plist for review, with this checkout's absolute app path. It does **not** write into `~/Library/LaunchAgents`, call `launchctl`, or enable persistent startup. It has no KeepAlive loop. The app must remain at that path for this proposed agent to work. Installation and activation require a separate explicit go-ahead. No installer is run as part of the build.

## Structure and next steps

- `src/lib.rs`: allowlisted Rust parser and read-only checks; no external crates.
- `src/main.rs`: CLI and owned-string C ABI to the native bridge.
- `native/companion.m`: native panel, tray lifecycle, worker dispatch, system TTS, device-only speech adapter.
- `native/Info.plist`: accessory-app identity and permission explanations.
- `scripts/`: offline build/check and a print-only launch-agent preview.
- [docs/TECHNOLOGY.md](docs/TECHNOLOGY.md): UI and voice choices, Apple references, and alternatives.

Next useful additions would be a user-approved Pi health endpoint, better conversation via a separately selected local model, and then character design. Each needs its own scope: this project does not silently add model downloads, remote services, paid APIs, credentials, or automatic startup.

# mica
