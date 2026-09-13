# VoxType

A native macOS menu bar app that transcribes your voice to text — press the **Fn / Globe key** to start/stop recording, and VoxType intelligently inserts the transcription into the focused text field (or copies it to the clipboard).

Built with **Swift, SwiftUI, AVFoundation, Speech, and the Accessibility API**.

## Features

- **Global Fn-key hotkey** — Quartz Event Tap detects the `fn` (Globe) key system-wide; press once to start, press again to stop.
- **On-device speech recognition** — `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` for zero-latency, fully-private, offline transcription.
- **Floating HUD** — a borderless, always-on-top capsule with a glowing gradient ring and live waveform bars that react to your voice level.
- **Smart text delivery** — uses the Accessibility API (`kAXFocusedUIElementAttribute`) to inject directly at the cursor; falls back to paste synthesis, then the clipboard.
- **Menu-bar accessory** — `LSUIElement = true` keeps it out of the Dock.

## Requirements

- macOS 13.0+ (Ventura)
- Xcode 15+ or Swift 5.9+ toolchain
- **Permissions:** Accessibility, Microphone, Speech Recognition (granted on first launch)

## Project Structure

```
VoxType/
├── Info.plist
├── VoxTypeApp.swift        # App entry point & menu bar
├── HotkeyManager.swift     # Quartz Event Tap for Fn key
├── AudioRecorder.swift     # AVAudioEngine capture + metering
├── SpeechRecognizer.swift  # On-device SFSpeechRecognizer
├── HUDWindowController.swift # Borderless NSPanel
├── FloatingHUDView.swift   # SwiftUI capsule + waveform
└── TextInjector.swift      # AX injection / clipboard fallback
```

## Build

```sh
make build
```

## Run

```sh
make run
```

## Permissions

On first launch, VoxType prompts for:
1. **Accessibility** — needed for the global hotkey and text injection.
2. **Microphone** — needed for audio capture.
3. **Speech Recognition** — needed for on-device transcription.

Grant these under **System Settings → Privacy & Security**. You can also use the menu bar item → *Check Permissions…*.

## Deploy

```sh
make deploy
```

This builds, commits, and pushes to `main`.

## License

MIT