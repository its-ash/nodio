# Nodio

**Voice to text, on your Mac.**

Nodio is a native macOS menu bar app that transcribes your voice to text. Hold the **Fn / Globe key**, speak, release — your words land in whatever text field you're focused on. No cloud, no latency, no subscriptions.

Built with **Swift, SwiftUI, AVFoundation, Speech, and the Accessibility API**.

## Features

- **Global Fn-key hotkey** — Quartz Event Tap detects the `fn` (Globe) key system-wide; hold to record, release to transcribe.
- **On-device speech recognition** — `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` for zero-latency, fully-private, offline transcription.
- **Audio enhancement** — noise gate suppresses background sound; peak normalization boosts your voice before transcription for better accuracy.
- **Floating HUD** — a compact, always-on-top pill with live waveform bars shows Nodio is listening. No windows, no distractions.
- **Smart text delivery** — uses the Accessibility API (`kAXFocusedUIElementAttribute`) to inject text directly at the cursor; falls back to paste synthesis (Cmd+V) for Electron apps like VS Code; copies to clipboard when no text field is focused.
- **Copy last message** — re-use your last transcription from the menu bar, one click away.
- **Menu-bar accessory** — `LSUIElement = true` keeps it out of the Dock.

## Requirements

- macOS 13.0+ (Ventura)
- Xcode 15+ or Swift 5.9+ toolchain
- **Permissions:** Accessibility, Microphone, Speech Recognition (granted on first launch)

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
    ├── AudioEnhancer.swift # Noise gate + peak normalization
    ├── SpeechRecognizer.swift # On-device SFSpeechRecognizer
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
| `HotkeyManager.swift` | Quartz Event Tap for the Fn/Globe key (hold to record) |
| `AudioRecorder.swift` | `AVAudioEngine` capture into temp `.caf` file + RMS power metering |
| `AudioEnhancer.swift` | Noise gate (suppresses below noise floor × 3) + peak normalization to 0.95 |
| `SpeechRecognizer.swift` | On-device `SFSpeechRecognizer` (en-US, `requiresOnDeviceRecognition = true`) |
| `HUDWindowController.swift` | Borderless, non-activating, always-on-top `NSPanel` |
| `FloatingHUDView.swift` | SwiftUI capsule with animated gradient border + live waveform bars |
| `TextInjector.swift` | AX `kAXSelectedTextAttribute` injection → Cmd+V paste synthesis → clipboard fallback |

## How it works

1. **Hold Fn to record** — press and hold the Fn/Globe key; the floating pill appears with a live waveform.
2. **Release to transcribe** — Nodio applies a noise gate and normalization, then runs on-device speech recognition on the enhanced audio.
3. **Text lands where you are** — the transcription is injected at your cursor in the focused text field. No field? It copies to your clipboard.

## Permissions

On first launch, Nodio prompts for:

1. **Accessibility** — needed for the global hotkey and text injection.
2. **Microphone** — needed for audio capture.
3. **Speech Recognition** — needed for on-device transcription.

Grant these under **System Settings → Privacy & Security**. You can also use the menu bar item → *Check Permissions…*.

## Conventions

- SwiftPM package (`Package.swift`), no Xcode project needed.
- `LSUIElement = true` (menu bar accessory, no Dock icon).
- On-device recognition only (`requiresOnDeviceRecognition = true`).
- Audio never leaves the device.

## License

MIT

## Author

[Ashvini Jangid](https://itsash.in)