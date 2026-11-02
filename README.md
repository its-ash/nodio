# Nodio

**Voice to text, on your Mac.**

Nodio is a native macOS menu bar app that transcribes your voice to text. Hold the **Fn / Globe key**, speak, release — your words land in whatever text field you're focused on. No cloud, no latency, no subscriptions.

Built with **Swift, SwiftUI, AVFoundation, [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and the Accessibility API**.

## Features

- **Hotkey** — Fn/Globe, Right Option, Right Command, or Right Control. Hold to record. Key chords such as ⌘C are ignored.
- **Hands-free** — double-tap the hotkey to start, tap once to stop.
- **On-device Whisper** — whisper.cpp with Metal. Pick Small, Medium, or Large v3 Turbo. Indian English only. Audio never leaves the Mac.
- **Hinglish mode** — Hindi + English, written in Latin letters.
- **Voice activity detection** — Silero VAD (built into whisper.cpp) skips silence, so fewer wrong words.
- **Custom vocabulary** — your names, places, and tech words go to Whisper as hints.
- **Voice commands** — “new line”, “new paragraph”, “full stop”, “comma”, “question mark”. Say only “delete that” or “undo” to edit.
- **Snippets** — say “my email” and Nodio types your saved text.
- **Per-app styles** — casual in chat apps, formal in mail, code-safe in IDEs and terminals. You can override per app.
- **AI cleanup** — optional grammar fix and list formatting with Apple’s on-device model (macOS 26 + Apple Intelligence).
- **Live preview or live typing** — the HUD shows words while you speak. Live typing inserts them at once (commands, snippets, styles, and AI cleanup need it off).
- **History and stats** — search, copy, delete, and export past dictations. See words per day and time saved. Stored on this Mac only.
- **Microphone picker** — choose the input and test its level in Settings.
- **Model manager** — download, delete, or redownload models. Each file is checked with SHA-256.
- **Update check** — daily check of GitHub Releases, plus *Check for Updates…*.
- **Floating HUD** — a compact, always-on-top pill with live waveform bars shows Nodio is listening. No windows, no distractions.
- **Smart text delivery** — uses the Accessibility API (`kAXFocusedUIElementAttribute`) to inject text directly at the cursor; falls back to paste synthesis (Cmd+V) for Electron apps like VS Code; copies to clipboard when no text field is focused.
- **Copy last message** — re-use your last transcription from the menu bar, one click away.
- **Menu-bar accessory** — `LSUIElement = true` keeps it out of the Dock.

## Requirements

- macOS 13.3+ (Ventura), Apple Silicon recommended
- Xcode 15+ or Swift 5.9+ toolchain
- **Permissions:** Accessibility, Microphone (granted on first launch)

## Build

```sh
make build
```

## Run

```sh
make run
```

## Deploy

```sh
make deploy
```

Builds the app, commits to `main`, and pushes. The landing page is served via GitHub Pages.

## Project Structure

```
Nodio/
├── index.html              # Landing page (Playful Geometric design)
├── style.css               # Landing page styles
├── script.js               # Landing page interactions
├── mic.svg                 # App icon
├── .nojekyll               # GitHub Pages config
├── Makefile                # run / build / deploy / clean
├── Package.swift           # SwiftPM package
└── VoxType/
    ├── Info.plist          # Bundle config, usage descriptions, LSUIElement
    ├── Nodio.entitlements  # Code signing entitlements
    ├── VoxTypeApp.swift    # App entry point, menu bar, session orchestration
    ├── HotkeyManager.swift # Quartz Event Tap for Fn/Globe key
    ├── AudioRecorder.swift # AVAudioEngine capture + RMS metering
    ├── AppSettings.swift   # Settings, model list, app styles, hotkeys, snippets
    ├── SpeechRecognizer.swift # whisper.cpp live decoding (Indian English)
    ├── WhisperModelStore.swift # One model file: download, SHA-256, delete
    ├── ModelCenter.swift   # Active model + VAD lifecycle
    ├── TextPostProcessor.swift # Voice commands + snippets
    ├── TranscriptFormatter.swift # Fillers, casing, per-app style
    ├── AICleaner.swift     # Apple FoundationModels cleanup
    ├── HistoryStore.swift  # History + stats (JSON)
    ├── AudioDevices.swift  # Input devices + mic test
    ├── UpdateChecker.swift # GitHub Releases check
    ├── SettingsView.swift  # Settings window (SwiftUI)
    ├── HUDWindowController.swift # Borderless, non-activating NSPanel
    ├── FloatingHUDView.swift   # SwiftUI capsule + waveform bars
    ├── TextInjector.swift  # AX injection / paste synthesis / clipboard fallback
    └── Resources/
        └── mic.svg         # Menu bar icon
```

## Architecture (MVVM, modular)

| Module | Responsibility |
|---|---|
| `VoxTypeApp.swift` | App entry point, menu bar accessory, session orchestration, transcription store |
| `HotkeyManager.swift` | Quartz Event Tap: hold, double-tap toggle, chord detection |
| `AudioRecorder.swift` | `AVAudioEngine` capture from the chosen device + RMS power metering |
| `SpeechRecognizer.swift` | whisper.cpp (Metal): 16 kHz resample, decode every 1.2 s, window trim at 20 s, VAD, prompt hints |
| `WhisperModelStore.swift` | One ggml file: download, SHA-256 check, delete |
| `ModelCenter.swift` | Keeps the chosen model loaded and the VAD file present |
| `TextPostProcessor.swift` | Spoken punctuation, “delete that” / “undo”, snippets |
| `AICleaner.swift` | Optional cleanup with Apple FoundationModels, 6 s timeout |
| `HistoryStore.swift` | History (last 1000) and stats in Application Support |
| `SettingsView.swift` | General, Models, Dictionary, App Styles, History, Stats tabs |
| `HUDWindowController.swift` | Borderless, non-activating, always-on-top `NSPanel` |
| `FloatingHUDView.swift` | SwiftUI capsule with animated gradient border + live waveform bars |
| `TextInjector.swift` | AX `kAXSelectedTextAttribute` injection → Cmd+V paste synthesis → clipboard fallback |

## How it works

1. **Hold Fn to record** — press and hold the Fn/Globe key; the floating pill appears with a live waveform.
2. **Speak** — Whisper decodes your audio on the device while you hold the key; the HUD shows the words.
3. **Release** — Whisper does a last full pass. Nodio applies voice commands, snippets, the app style, and (if on) AI cleanup.
4. **Text lands where you are** — the text goes in at your cursor. No field? It is pasted, and stays on your clipboard.

## Permissions

On first launch, Nodio prompts for:

1. **Accessibility** — needed for the global hotkey and text injection.
2. **Microphone** — needed for audio capture.

Grant these under **System Settings → Privacy & Security**. You can also use the menu bar item → *Check Permissions…*.

## Conventions

- SwiftPM package (`Package.swift`), no Xcode project needed.
- `LSUIElement = true` (menu bar accessory, no Dock icon).
- On-device recognition only (whisper.cpp, Indian English).
- Audio never leaves the device.

## License

MIT

## Author

[Ashvini Jangid](https://itsash.in)