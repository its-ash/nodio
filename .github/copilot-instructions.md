# VoxType

A native macOS menu bar voice-to-text app built with Swift, SwiftUI, AVFoundation, whisper.cpp, and the Accessibility API.

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
- `AppSettings.swift` — UserDefaults settings, `ModelFile` list, `AppStyle`, `HotkeyChoice`, `Snippet`.
- `HotkeyManager.swift` — Quartz Event Tap: hold to talk, double-tap hands-free, chord detection.
- `AudioRecorder.swift` — AVAudioEngine capture from the chosen device + RMS power metering.
- `AudioDevices.swift` — CoreAudio input list, device select, `MicTester`.
- `SpeechRecognizer.swift` — whisper.cpp (XCFramework binary target), Indian English only, live re-decode, VAD, prompt hints.
- `WhisperModelStore.swift` — One ggml file in Application Support: download, SHA-256, delete.
- `ModelCenter.swift` — Keeps the chosen model loaded and the VAD file present.
- `TextPostProcessor.swift` — Voice commands, “delete that” / “undo”, snippets.
- `TranscriptFormatter.swift` — Fillers, casing, per-app style.
- `AICleaner.swift` — Optional Apple FoundationModels cleanup (macOS 26+).
- `HistoryStore.swift` — History + stats JSON.
- `UpdateChecker.swift` — GitHub Releases check.
- `SettingsView.swift` — SwiftUI Settings window.
- `OnboardingView.swift` — First-launch setup guide (mic, accessibility, model progress), `ReadyNotifier`.
- `HUDWindowController.swift` — Borderless, non-activating, always-on-top NSPanel.
- `FloatingHUDView.swift` — SwiftUI glowing capsule with live waveform bars.
- `TextInjector.swift` — AX-focused-element injection, paste synthesis, clipboard fallback.

## Permissions required

Accessibility, Microphone. Use menu bar → Check Permissions…

## Conventions

- SwiftPM package (`Package.swift`), no Xcode project needed.
- `LSUIElement = true` (menu bar accessory, no Dock icon).
- On-device recognition only (whisper.cpp). Language is fixed to Indian English.
- `make build` embeds `whisper.framework` in `Contents/Frameworks`.
- Default delivery is one insert on release (commands, snippets, styles, AI cleanup). Live typing streams words and skips those steps.