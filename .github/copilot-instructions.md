# VoxType

A native macOS menu bar voice-to-text app built with Swift, SwiftUI, AVFoundation, Speech, and the Accessibility API.

## Build

```sh
make build
```

## Run

```sh
make run
```

## Architecture (MVVM, modular)

- `VoxTypeApp.swift` — App entry point, menu bar accessory, session orchestration.
- `HotkeyManager.swift` — Quartz Event Tap for the Fn/Globe key (toggle recording).
- `AudioRecorder.swift` — AVAudioEngine capture + RMS power metering.
- `SpeechRecognizer.swift` — On-device SFSpeechRecognizer (en-US, offline).
- `HUDWindowController.swift` — Borderless, non-activating, always-on-top NSPanel.
- `FloatingHUDView.swift` — SwiftUI glowing capsule with live waveform bars.
- `TextInjector.swift` — AX-focused-element injection, paste synthesis, clipboard fallback.

## Permissions required

Accessibility, Microphone, Speech Recognition. Use menu bar → Check Permissions…

## Conventions

- SwiftPM package (`Package.swift`), no Xcode project needed.
- `LSUIElement = true` (menu bar accessory, no Dock icon).
- On-device recognition only (`requiresOnDeviceRecognition = true`).