# Micah

A small macOS desktop companion with a Rust core and native AppKit interface. Character artwork is still a placeholder.

- Local commands: `time`, `mac status`, `pi status`, `help`.
- On-device English speech recognition and spoken replies.
- Optional OpenAI conversations and voices using your API key.
- Conversation mode: pause to send, then listen again after the reply.
- Token tracking and cost estimates through [LLM Usage](https://github.com/geckolabs-experiments/llm-usage).

## Run

Requires macOS 13+, Rust and Apple's Command Line Tools. Tested on Apple Silicon.

```sh
cd ~/Daniel/desktop-companion
cargo fetch --locked  # first build only
./scripts/build-app.sh
open dist/Micah.app
```

Quit the running copy before opening a rebuilt app. Hide/close keeps Micah in the menu bar; **Quit** exits it.

## Use AI and voice

Open **AI settings**, enter your key and choose **Enable AI now**. Select **Save/replace key in macOS Keychain** to remember it. AI starts off unless you explicitly save startup enablement.

Click **Click to talk**, review the transcript and **Send**. For hands-free turns, enable **Conversation: pause to send**, then click to talk once. **Stop voice** ends the session. Sessions stop after 3 minutes or 10 turns.

**Mac voice** is local; OpenAI voices incur API charges. API billing is separate from ChatGPT, and the output-token cap is not a spending limit. Enabled AI sends submitted text and bounded conversation history to OpenAI. Microphone input stays on-device; local commands stay local. Usage logs contain token metadata, not prompts, replies or keys.

## Development

```sh
./scripts/check.sh
./target/release/desktop-companion --native-self-test
```

See the [user guide](docs/USAGE.md), [architecture](docs/TECHNOLOGY.md), [API tests](docs/API-TESTING.md) and [validation notes](docs/VALIDATION.md) for details.
