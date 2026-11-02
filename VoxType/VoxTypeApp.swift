import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Sentry
import UserNotifications

@main
enum VoxTypeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Last successfully transcribed text, accessible from the menu bar.
final class TranscriptionStore: ObservableObject {
    @Published var lastTranscription: String?
}

/// Data for one dictation, captured when it starts.
private final class Session {
    let start = Date()
    let live: Bool
    let bundleID: String?
    let appName: String?
    let style: AppStyle
    var finalRaw = ""
    var liveText = ""

    init(live: Bool, app: NSRunningApplication?, overrides: [String: AppStyle]) {
        self.live = live
        bundleID = app?.bundleIdentifier
        appName = app?.localizedName
        style = AppStyle.for(bundleID: app?.bundleIdentifier, overrides: overrides)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private let audioRecorder = AudioRecorder()
    private let speechRecognizer = SpeechRecognizer()
    private let textInjector = TextInjector()
    private let hudController = HUDWindowController()
    private lazy var models = ModelCenter(recognizer: speechRecognizer)
    private lazy var settingsWindow = SettingsWindowController(models: models)
    private lazy var onboarding = OnboardingWindowController(models: models)
    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    let transcriptionStore = TranscriptionStore()

    private var isRecording = false
    private var session: Session?
    private var bag = Set<AnyCancellable>()
    private var updateTimer: Timer?

    private static let sentryDSN = "https://8896ed4a00c858351cad58867d58a0fd@o4512363371692032.ingest.us.sentry.io/4512363378769920"

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        SentrySDK.start { o in
            o.dsn = Self.sentryDSN
            #if DEBUG
            o.debug = true
            o.environment = "debug"
            #endif
            o.sendDefaultPii = false
        }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self

        setupMenuBar()
        setupHotkey()
        models.onReadyAfterDownload = { [weak self] in
            guard let self else { return }
            ReadyNotifier.post(hotkey: self.settings.hotkey.title)
        }
        models.activate()
        setupUpdateChecks()

        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !OnboardingWindowController.isDone || !micOK || !AXIsProcessTrusted() {
            onboarding.show()
        } else {
            requestMicrophonePermissionOnLaunch()
        }
    }

    /// Show the banner even while a Nodio window has focus.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func setupUpdateChecks() {
        let check = { [weak self] in
            guard self?.settings.autoUpdateCheck == true else { return }
            UpdateChecker.checkIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: check)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in check() }
    }

    // MARK: - Feedback

    private enum FeedbackEvent { case start, stop, failed }

    private func playFeedback(_ event: FeedbackEvent) {
        guard settings.soundFeedback else { return }
        switch event {
        case .start: NSSound(named: "Tink")?.play()
        case .stop: NSSound(named: "Pop")?.play()
        case .failed: NSSound(named: "Basso")?.play()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = loadMenuBarIcon()
                ?? NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Nodio")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu(menu)

        models.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let menu = self.statusItem.menu else { return }
                self.rebuildMenu(menu)
            }
            .store(in: &bag)
        models.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatusIcon($0) }
            .store(in: &bag)
    }

    /// The menu bar icon shows when the model is not usable yet.
    private func updateStatusIcon(_ phase: ModelCenter.Phase) {
        guard let button = statusItem.button else { return }
        let symbol: String? = switch phase {
        case .downloading, .verifying, .loading: "arrow.down.circle"
        case .failed, .missing: "exclamationmark.triangle"
        case .ready: nil
        }
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: phase.hudMessage) }
            ?? loadMenuBarIcon()
            ?? NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Nodio")
        image?.isTemplate = true
        button.image = image
        button.toolTip = phase == .ready ? "Nodio: ready" : "Nodio: \(phase.hudMessage)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        func add(_ title: String, _ action: Selector?, key: String = "", on: Bool? = nil, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled && action != nil
            if let on { item.state = on ? .on : .off }
        }

        add("Nodio", nil)
        menu.addItem(.separator())
        let key = settings.hotkey.title
        add("Hold \(key) to Record", nil)
        if settings.handsFree { add("Double-Tap \(key) for Hands-Free", nil) }
        menu.addItem(.separator())

        if let last = transcriptionStore.lastTranscription {
            let preview = last.replacingOccurrences(of: "\n", with: " ")
            add("Copy Last Message: \(preview.prefix(30))\(preview.count > 30 ? "…" : "")", #selector(copyLastMessage), key: "c")
        } else {
            add("Copy Last Message", #selector(copyLastMessage), key: "c", enabled: false)
        }

        menu.addItem(.separator())
        add(models.status, models.canRetry ? #selector(retryModel) : nil)
        add("Live Typing", #selector(toggleLiveTyping), on: settings.liveTyping)
        add("Hinglish Mode", #selector(toggleHinglish), on: settings.hinglish)
        add("Sound Feedback", #selector(toggleSoundFeedback), on: settings.soundFeedback)

        menu.addItem(.separator())
        add("Setup Guide…", #selector(openOnboarding))
        add("History…", #selector(openHistory), key: "y")
        add("Settings…", #selector(openSettings), key: ",")
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Reset App Injection Profiles", #selector(resetInjectionProfiles))
        add("Check Permissions…", #selector(openPermissions))
        menu.addItem(.separator())
        add("Quit Nodio", #selector(quitApp), key: "q")
    }

    @objc private func toggleLiveTyping() { settings.liveTyping.toggle() }
    @objc private func toggleHinglish() { settings.hinglish.toggle() }
    @objc private func toggleSoundFeedback() { settings.soundFeedback.toggle() }
    @objc private func retryModel() { models.retry() }
    @objc private func openSettings() { settingsWindow.show(.general) }
    @objc private func openOnboarding() { onboarding.show() }
    @objc private func openHistory() { settingsWindow.show(.history) }
    @objc private func checkForUpdates() { UpdateChecker.check(userInitiated: true) }
    @objc private func resetInjectionProfiles() { InjectionProfileStore.shared.reset() }
    @objc private func quitApp() { NSApp.terminate(self) }

    @objc private func copyLastMessage() {
        guard let text = transcriptionStore.lastTranscription else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSSound.beep()
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "mic", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func openPermissions() {
        for pane in ["Privacy_Accessibility", "Privacy_Microphone"] {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Permissions

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

    /// Prompts on first launch; alerts when access was denied before.
    private func requestMicrophonePermissionOnLaunch() {
        let denied: Bool
        let undetermined: Bool
        if #available(macOS 14, *) {
            let s = AVAudioApplication.shared.recordPermission
            denied = s == .denied
            undetermined = s == .undetermined
        } else {
            let s = AVCaptureDevice.authorizationStatus(for: .audio)
            denied = s == .denied || s == .restricted
            undetermined = s == .notDetermined
        }
        if denied {
            alertMicPermissionDenied()
        } else if undetermined {
            requestMicPermission { [weak self] granted in
                if !granted { self?.alertMicPermissionDenied() }
            }
        }
    }

    private func alertMicPermissionDenied() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Nodio Needs Microphone Access"
        alert.informativeText = "Nodio requires microphone permission to transcribe your voice to text. Please grant access in System Settings → Privacy → Microphone."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        if alert.runModal() == .alertFirstButtonReturn { openPermissions() }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager = HotkeyManager(
            onPress: { [weak self] in self?.startRecording() },
            onRelease: { [weak self] in self?.stopRecording() },
            onToggle: { [weak self] in
                guard let self else { return }
                self.isRecording ? self.stopRecording() : self.startRecording()
            },
            isSessionActive: { [weak self] in self?.isRecording ?? false }
        )
        hotkeyManager.hotkey = settings.hotkey
        hotkeyManager.handsFreeEnabled = settings.handsFree

        settings.$hotkeyRaw.removeDuplicates()
            .sink { [weak self] raw in self?.hotkeyManager.hotkey = HotkeyChoice(rawValue: raw) ?? .fn }
            .store(in: &bag)
        settings.$handsFree.removeDuplicates()
            .sink { [weak self] on in self?.hotkeyManager.handsFreeEnabled = on }
            .store(in: &bag)

        hotkeyManager.checkAccessibilityAndStart()
    }

    // MARK: - Session

    private func startRecording() {
        guard !isRecording else { return }
        guard models.isReady else {
            debugLog("startRecording ignored — model not ready: \(models.status)")
            hudController.show()
            showFailure(models.phase.hudMessage)
            models.retry()
            if case .failed = models.phase { onboarding.show() }
            return
        }
        isRecording = true
        debugLog("startRecording called")

        requestMicPermission { [weak self] granted in
            guard let self, self.isRecording else { return }
            guard granted else {
                self.isRecording = false
                self.openPermissions()
                return
            }

            let s = Session(
                live: self.settings.liveTyping,
                app: NSWorkspace.shared.frontmostApplication,
                overrides: self.settings.appStyles
            )
            self.session = s
            if s.live { self.textInjector.beginLiveStream() }

            self.hudController.show()
            self.playFeedback(.start)

            let config = SpeechRecognizer.Config(
                hinglish: self.settings.hinglish,
                vocabulary: self.settings.vocabularyTerms,
                vadModelPath: self.models.vadPath
            )
            self.speechRecognizer.startLiveSession(config: config) { [weak self] text, isFinal in
                self?.handleTranscript(text, isFinal: isFinal, session: s)
            }

            let recognizer = self.speechRecognizer
            let started = self.audioRecorder.start(
                deviceUID: self.settings.micUID,
                powerHandler: { [weak self] level in self?.hudController.updateAudioLevel(level) },
                bufferHandler: { recognizer.feed($0) }
            )
            if !started {
                self.isRecording = false
                self.session = nil
                self.speechRecognizer.endLiveSession()
                self.showFailure("Microphone unavailable")
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        debugLog("stopRecording called")
        playFeedback(.stop)
        let s = session

        audioRecorder.stop { [weak self] in
            guard let self else { return }
            self.hudController.updateState(.transcribing)
            self.speechRecognizer.endLiveSession { [weak self] in
                guard let self, let s else { return }
                self.finish(s)
            }
        }
    }

    private func handleTranscript(_ raw: String, isFinal: Bool, session s: Session) {
        if isFinal { s.finalRaw = raw }
        if s.live {
            let text = settings.autoFormat ? TranscriptFormatter.format(raw, style: s.style) : raw
            guard !text.isEmpty else { return }
            s.liveText = text
            transcriptionStore.lastTranscription = text
            textInjector.updateLiveStream(fullText: text)
        } else if !isFinal, isRecording, session === s {
            hudController.updatePreview(raw)
        }
    }

    private func finish(_ s: Session) {
        let seconds = Date().timeIntervalSince(s.start)
        let ownsHUD = { [weak self] in self.map { !$0.isRecording } ?? false }

        if s.live {
            textInjector.endLiveStream()
            let text = s.liveText
            guard !text.isEmpty else {
                if ownsHUD() { showFailure() }
                return
            }
            history.add(text, app: s.appName, seconds: seconds)
            if ownsHUD() { showDone() }
            return
        }

        switch TextPostProcessor.process(s.finalRaw, style: s.style, settings: settings) {
        case .none:
            if ownsHUD() { showFailure() }
        case .deleteLast:
            textInjector.deleteLast { [weak self] ok in
                guard ownsHUD() else { return }
                ok ? self?.showDone() : self?.showFailure("Nothing to delete")
            }
        case .undo:
            textInjector.undo { [weak self] in if ownsHUD() { self?.showDone() } }
        case .insert(let text):
            textInjector.insert(text) { [weak self] in
                guard let self else { return }
                self.transcriptionStore.lastTranscription = text
                self.history.add(text, app: s.appName, seconds: seconds)
                if ownsHUD() { self.showDone() }
            }
        }
    }

    private func showDone() {
        hudController.updateState(.done)
        hudController.hide(after: 1.2)
    }

    private func showFailure(_ message: String? = nil) {
        hudController.updateState(.failed, message: message)
        hudController.hide(after: message == nil ? 1.2 : 2.0)
        playFeedback(.failed)
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
