import SwiftUI
import AppKit
import Speech
import AVFoundation
import Combine

@main
struct VoxTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Last successfully transcribed text, accessible from the menu bar.
final class TranscriptionStore: ObservableObject {
    @Published var lastTranscription: String?
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var speechRecognizer: SpeechRecognizer!
    private var textInjector: TextInjector!
    private var hudController: HUDWindowController!
    let transcriptionStore = TranscriptionStore()

    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        audioRecorder = AudioRecorder()
        speechRecognizer = SpeechRecognizer()
        textInjector = TextInjector()
        hudController = HUDWindowController()

        setupMenuBar()
        setupHotkey()

        requestSpeechAuthorization()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.circle.fill",
                accessibilityDescription: "Nodio"
            )
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Nodio", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hold Fn to Record", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let copyItem = menu.addItem(withTitle: "Copy Last Message", action: #selector(copyLastMessage), keyEquivalent: "c")
        copyItem.target = self
        updateCopyMenuItem(copyItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Check Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nodio", action: #selector(quitApp), keyEquivalent: "q")

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        transcriptionStore.$lastTranscription
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateCopyMenuItem(copyItem) } }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateCopyMenuItem(_ item: NSMenuItem) {
        let hasLast = transcriptionStore.lastTranscription != nil
        item.isEnabled = hasLast
        if hasLast {
            let preview = (transcriptionStore.lastTranscription ?? "")
            let truncated = preview.prefix(30)
            item.title = "Copy Last Message: \(truncated)\(preview.count > 30 ? "…" : "")"
        } else {
            item.title = "Copy Last Message"
        }
    }

    @objc private func copyLastMessage() {
        guard let text = transcriptionStore.lastTranscription else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSSound.beep()
    }

    @objc private func toggleRecording() { startRecording() }

    @objc private func openPermissions() {
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            workspace.open(url)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            workspace.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(self)
    }

    // MARK: - Permissions

    private func requestSpeechAuthorization() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    private func requestMicPermission(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager = HotkeyManager(
            onPress: { [weak self] in
                DispatchQueue.main.async { self?.startRecording() }
            },
            onRelease: { [weak self] in
                DispatchQueue.main.async { self?.stopRecording() }
            }
        )
        hotkeyManager.checkAccessibilityAndStart()
    }

    // MARK: - Session

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        debugLog("startRecording called")

        requestMicPermission { [weak self] granted in
            guard let self else { return }
            self.debugLog("mic permission granted=\(granted)")
            guard granted else {
                self.openPermissions()
                self.isRecording = false
                return
            }

            self.hudController.show()
            self.audioRecorder.start { power in
                DispatchQueue.main.async { self.hudController.updateAudioLevel(power) }
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        debugLog("stopRecording called")

        audioRecorder.stop { [weak self] url in
            guard let self else { return }
            self.hudController.updateState(.transcribing)
            self.debugLog("audioRecorder.stop completion, url=\(url?.path ?? "nil")")

            guard let url else {
                self.debugLog("no recording url, aborting")
                self.hudController.hide(after: 0.5)
                return
            }

            // Enhance audio before transcription: noise gate + normalization
            let enhancedURL = AudioEnhancer.enhance(fileAt: url) ?? url
            self.debugLog("enhanced url=\(enhancedURL.path)")

            self.speechRecognizer.transcribe(fileAt: enhancedURL) { result in
                self.debugLog("transcribe completion, result=\(result ?? "nil")")
                DispatchQueue.main.async {
                    guard let result = result, !result.isEmpty else {
                        self.debugLog("empty/nil transcription result, aborting")
                        self.hudController.hide(after: 0.5)
                        return
                    }
                    self.finishTranscription(result)
                }
            }
        }
    }

    private func finishTranscription(_ result: String) {
        debugLog("finishTranscription: \(result)")
        transcriptionStore.lastTranscription = result

        textInjector.deliver(result) { copied in
            self.hudController.updateState(.done)
            self.hudController.hide(after: 1.2)
            if copied { NSSound.beep() }
        }
    }

    private func debugLog(_ message: String) {
        let line = "\(Date()): [App] \(message)\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("voxtype_debug.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: path)
        }
    }
}