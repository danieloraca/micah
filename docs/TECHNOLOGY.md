# UI and voice investigation

The MVP chooses **Rust business logic plus a narrow Objective-C AppKit bridge**. It uses frameworks already installed with macOS and compiles with Apple's Command Line Tools. No Cargo package, JavaScript runtime, package-manager installation, or model download is required. Rust owns command matching, subprocess bounds, response semantics, tests and the CLI. AppKit owns main-thread UI and platform audio state. The bridge copies Rust-owned strings and frees them via the paired Rust allocator function.

The panel uses `NSPanel`, `NSFloatingWindowLevel`, and `hidesOnDeactivate = NO`; a menu-bar `NSStatusItem` supplies Show, Hide and Quit. This is a logged-in-user desktop app, not a headless system daemon. Hiding is explicit and reversible. No accessibility permission is needed by the app.

Other suitable Rust routes include eframe/egui, for a portable Rust UI, and Tauri, for a Rust backend with a web UI. Neither UI stack was cached on this Mac. eframe would need its crate/rendering stack; Tauri would add a web frontend build and dependencies. AppKit is the smallest native MVP here. A future character renderer could be embedded without changing the Rust command boundary. Direct Rust Objective-C bindings are another possible replacement for the bridge; the extra dependency is unnecessary for this first version.

Apple's native frameworks provide:

- **Output:** `AVSpeechSynthesizer`, selecting an available `AVSpeechSynthesisVoice` for `en-US`. It uses the system's installed voice, not the voice from this chat. No voice asset licensing or access is assumed.
- **Input:** `SFSpeechRecognizer` and `SFSpeechAudioBufferRecognitionRequest` with `AVAudioEngine`. Recognition must report on-device support, the request must require on-device recognition, and availability/permission failures must keep the microphone off. Apple notes that the request's local-only flag is only honored when on-device support is true; both gates are therefore required.
- **Permissions:** the bundle declares `NSSpeechRecognitionUsageDescription` and `NSMicrophoneUsageDescription`. Speech and microphone access are requested from the user-initiated flow; asynchronous callbacks return to the main queue. A generation counter invalidates canceled permission and recognition callbacks.

Speech support depends on OS, locale and installed assets. This MVP neither fetches missing assets nor enables a cloud fallback. Built-in macOS Dictation is a separate OS feature and is not controlled by this app. A future fully local recognizer such as whisper.cpp would need an explicitly selected model, download size, CPU/memory budget, license review and integration tests. A local conversation model likewise requires a real inference backend and weights; a command dispatcher is never labeled as AI.

On this Mac, initial requests failed with `kLSRErrorDomain 201` (“Siri and Dictation are disabled”), despite `supportsOnDeviceRecognition` returning true outside the execution sandbox. This was confirmed by Apple's `localspeechrecognition` service log and the installed SDK's `SFSpeechRecognitionTask.h` error table (201: Siri or Dictation disabled; 102: missing assets). Dan subsequently enabled system Dictation himself and reported transcripts appearing. The app displays native errors and app-scoped permission diagnostics. No system setting is automatically changed. See [Apple's user guide to Dictation](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac) for its location and the system's privacy explanation; system Dictation and Mica's strict device-only requests are distinct flows.

Speech results use a generation-checked transcript adapter. The UI disables Send/editing during capture and freezes the latest text on Stop. It synchronizes the NSTextField backing value and active field editor, then snapshots actual reviewed text for submission. Six Rust tests and sixteen synthetic AppKit self-test checks cover the command aliases and lifecycle; the native tests request no audio permissions. Exact observed speech variants can be added as narrow aliases (`Max status` → `Mac status`); there is no fuzzy or arbitrary command execution. The result panel shows both submitted text and matched action.

Primary references checked on 2026-11-03:

- [Apple: floating panels](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel)
- [Apple: SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- [Apple: requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [Apple: speech authorization](https://developer.apple.com/documentation/speech/sfspeechrecognizer/requestauthorization(_:))
- [Apple: microphone access](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:))
- [eframe native window options](https://docs.rs/eframe/latest/eframe/struct.NativeOptions.html)

