import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI
import UserNotifications

// MARK: - Accessibility Trust

/// Ad-hoc signed builds get a new code hash on each install, so an old
/// Accessibility entry stays in the list but no longer matches. Remove the
/// stale entry so macOS adds a fresh one on the next prompt.
enum AccessibilityTrust {
    private static let buildKey = "com.nodio.app.axBuild"
    private static var listed = false

    /// Adds a fresh entry to the Accessibility list once per launch. Only the
    /// prompt option adds the entry, so macOS shows its dialog this one time.
    /// Returns true if the dialog was shown (it has its own Open Settings button).
    @discardableResult
    static func request() -> Bool {
        guard !listed, !AXIsProcessTrusted() else { return false }
        listed = true
        reset()
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        return true
    }

    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// Once per build: if this build is not trusted, reset its entry.
    static func resetIfNewBuild() {
        let d = UserDefaults.standard
        guard d.string(forKey: buildKey) != build else { return }
        d.set(build, forKey: buildKey)
        if !AXIsProcessTrusted() { reset() }
    }

    /// Removes this app's Accessibility entry (no admin needed for own bundle ID).
    @discardableResult
    static func reset() -> Bool {
        guard let id = Bundle.main.bundleIdentifier, !AXIsProcessTrusted() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            NSLog("AccessibilityTrust: tccutil failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Window

/// First-launch setup guide: microphone, accessibility, and the model download.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let doneKey = "com.nodio.app.onboarded"

    private var window: NSWindow?
    private let models: ModelCenter

    init(models: ModelCenter) { self.models = models }

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    func show() {
        if window == nil {
            let root = OnboardingView(models: models) { [weak self] in self?.close() }
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Set Up Nodio"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }
}

// MARK: - Permission State

final class PermissionMonitor: ObservableObject {
    enum Mic { case granted, denied, unknown }

    @Published private(set) var mic: Mic = .unknown
    @Published private(set) var accessibility = false

    private var timer: Timer?

    init() {
        refresh()
        // Neither permission posts a change event, so poll while the window is open.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .denied, .restricted: mic = .denied
        default: mic = .unknown
        }
        accessibility = AXIsProcessTrusted()
    }

    func requestMic() {
        if mic == .denied {
            open("Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return refresh() }
        if !AccessibilityTrust.request() { open("Privacy_Accessibility") }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var models: ModelCenter
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var perms = PermissionMonitor()
    let onClose: () -> Void

    private var allReady: Bool {
        perms.mic == .granted && perms.accessibility && models.phase == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Nodio").font(.title2.weight(.semibold))
                    Text("Three things to set up. It takes about a minute.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                StepRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "So Nodio can hear you while you hold the key.",
                    done: perms.mic == .granted
                ) {
                    Button(perms.mic == .denied ? "Open Settings" : "Allow") { perms.requestMic() }
                }
                Divider()
                StepRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "So Nodio can see the hotkey and type into any app. Turn on Nodio in the list.",
                    done: perms.accessibility
                ) {
                    Button("Open Settings") { perms.requestAccessibility() }
                }
                Divider()
                StepRow(
                    icon: "arrow.down.circle.fill",
                    title: "Speech model",
                    detail: modelDetail,
                    done: models.phase == .ready
                ) {
                    modelAction
                }
            }
            .padding(.horizontal, 14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(allReady ? "You are ready." : "Try it when all three are done.")
                    .font(.headline)
                Text("Click in any text field, hold \(settings.hotkey.title), and speak. Release to insert the text. Double-tap the key for hands-free.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !allReady {
                    Text("You can close this window. Nodio keeps downloading and tells you when it is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(allReady ? "Start Using Nodio" : "Continue in Background", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private var modelDetail: String {
        let f = models.active.file
        switch models.phase {
        case .missing: return "\(f.title), \(f.sizeLabel). Downloads one time, then runs on this Mac."
        case .downloading(let p): return "Downloading \(f.title): \(Int(p * 100))% of \(f.sizeLabel)."
        case .verifying: return "Checking the download."
        case .loading: return "Loading the model into memory."
        case .ready: return "\(f.title) is ready. Change it in Settings, Models."
        case .failed(let r): return "Download failed: \(r)."
        }
    }

    @ViewBuilder private var modelAction: some View {
        switch models.phase {
        case .downloading(let p):
            ProgressView(value: p).frame(width: 90)
        case .verifying, .loading:
            ProgressView().controlSize(.small)
        case .failed, .missing:
            Button("Retry") { models.retry(); models.activate() }
        case .ready:
            EmptyView()
        }
    }
}

private struct StepRow<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(done ? Color.green : Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(title) done")
            } else {
                action()
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Notifications

enum ReadyNotifier {
    static func post(hotkey: String) {
        let c = UNMutableNotificationContent()
        c.title = "Nodio is ready"
        c.body = "Hold \(hotkey) in any text field and speak."
        c.sound = .default
        let req = UNNotificationRequest(identifier: "nodio.model.ready", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
