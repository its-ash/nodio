import SwiftUI
import AppKit
import Speech
import AVFoundation
import Combine
import ServiceManagement

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

    private static let localeDefaultsKey = "com.nodio.app.recognitionLocale"

    /// English accent options for on-device recognition. "Indian English"
    /// defaults on first launch since that's the primary user's accent —
    /// SFSpeechRecognizer ships a distinct en-IN model that materially
    /// improves accuracy over en-US for Indian English speakers.
    private static let supportedLocales: [(title: String, identifier: String)] = [
        ("Indian English", "en-IN"),
        ("US English", "en-US"),
        ("British English", "en-GB"),
        ("Australian English", "en-AU"),
    ]

    private var currentLocaleIdentifier: String {
        get { UserDefaults.standard.string(forKey: Self.localeDefaultsKey) ?? "en-IN" }
        set { UserDefaults.standard.set(newValue, forKey: Self.localeDefaultsKey) }
    }

    // MARK: - Sound Feedback

    private static let soundFeedbackDefaultsKey = "com.nodio.app.soundFeedback"

    private var soundFeedbackEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.soundFeedbackDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.soundFeedbackDefaultsKey) }
    }

    // MARK: - Auto-Formatting

    private static let autoFormatDefaultsKey = "com.nodio.app.autoFormat"

    private var autoFormatEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoFormatDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoFormatDefaultsKey) }
    }

    private enum FeedbackEvent {
        case start, stop
    }

    private func playFeedback(_ event: FeedbackEvent) {
        guard soundFeedbackEnabled else { return }
        switch event {
        case .start: NSSound(named: "Tink")?.play()
        case .stop: NSSound(named: "Pop")?.play()
        }
    }

    // MARK: - Launch at Login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("AppDelegate: failed to \(enabled ? "register" : "unregister") launch-at-login — \(error)")
        }
    }

    @objc private func toggleSoundFeedback(_ sender: NSMenuItem) {
        soundFeedbackEnabled.toggle()
        sender.state = soundFeedbackEnabled ? .on : .off
    }

    @objc private func toggleAutoFormat(_ sender: NSMenuItem) {
        autoFormatEnabled.toggle()
        sender.state = autoFormatEnabled ? .on : .off
    }

    @objc private func resetInjectionProfiles() {
        InjectionProfileStore.shared.reset()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = !launchAtLoginEnabled
        setLaunchAtLogin(newValue)
        sender.state = launchAtLoginEnabled ? .on : .off
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        audioRecorder = AudioRecorder()
        speechRecognizer = SpeechRecognizer(localeIdentifier: currentLocaleIdentifier)
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
            if let icon = loadMenuBarIcon() {
                button.image = icon
            } else {
                button.image = NSImage(
                    systemSymbolName: "mic.circle.fill",
                    accessibilityDescription: "Nodio"
                )
            }
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
        menu.addItem(withTitle: "Language", action: nil, keyEquivalent: "").submenu = buildLanguageMenu()

        let soundItem = menu.addItem(withTitle: "Sound Feedback", action: #selector(toggleSoundFeedback(_:)), keyEquivalent: "")
        soundItem.state = soundFeedbackEnabled ? .on : .off

        let formatItem = menu.addItem(withTitle: "Auto-Format Text", action: #selector(toggleAutoFormat(_:)), keyEquivalent: "")
        formatItem.state = autoFormatEnabled ? .on : .off

        let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.state = launchAtLoginEnabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset App Injection Profiles", action: #selector(resetInjectionProfiles), keyEquivalent: "")
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

    private func buildLanguageMenu() -> NSMenu {
        let submenu = NSMenu()
        for (title, identifier) in Self.supportedLocales {
            let item = submenu.addItem(
                withTitle: title,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = identifier
            item.state = (identifier == currentLocaleIdentifier) ? .on : .off
        }
        return submenu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              identifier != currentLocaleIdentifier else { return }
        currentLocaleIdentifier = identifier
        speechRecognizer = SpeechRecognizer(localeIdentifier: identifier)
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String == identifier) ? .on : .off }
    }

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

    // MARK: - Icon

    private func loadMenuBarIcon() -> NSImage? {
        // Load mic.svg from bundle resources; NSImage supports SVG on macOS 14+
        if let url = Bundle.main.url(forResource: "mic", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

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
            self.playFeedback(.start)
            self.audioRecorder.start { power in
                DispatchQueue.main.async { self.hudController.updateAudioLevel(power) }
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        debugLog("stopRecording called")
        playFeedback(.stop)

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

    private func finishTranscription(_ rawResult: String) {
        let result = autoFormatEnabled ? TranscriptFormatter.format(rawResult) : rawResult
        debugLog("finishTranscription: \(result)")
        transcriptionStore.lastTranscription = result

        // Hide HUD immediately so it can't steal focus from the target app
        hudController.hide(after: 0)

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