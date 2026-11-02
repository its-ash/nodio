import AppKit
import Charts
import ServiceManagement
import SwiftUI

// MARK: - Window

final class SettingsWindowController {
    enum Tab: Hashable { case general, models, dictionary, styles, history, stats }

    private var window: NSWindow?
    private let models: ModelCenter
    private let selection = TabSelection()

    init(models: ModelCenter) { self.models = models }

    func show(_ tab: Tab = .general) {
        selection.tab = tab
        if window == nil {
            let root = SettingsView(models: models, selection: selection)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Nodio Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 680, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class TabSelection: ObservableObject {
    @Published var tab: SettingsWindowController.Tab = .general
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var models: ModelCenter
    @ObservedObject var selection: TabSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsWindowController.Tab.general)
            ModelsTab(models: models).tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsWindowController.Tab.models)
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(SettingsWindowController.Tab.dictionary)
            StylesTab().tabItem { Label("App Styles", systemImage: "textformat") }.tag(SettingsWindowController.Tab.styles)
            HistoryTab().tabItem { Label("History", systemImage: "clock") }.tag(SettingsWindowController.Tab.history)
            StatsTab().tabItem { Label("Stats", systemImage: "chart.bar") }.tag(SettingsWindowController.Tab.stats)
        }
        .padding()
        .frame(minWidth: 620, minHeight: 460)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject private var s = AppSettings.shared
    @StateObject private var mic = MicTester()
    @State private var devices = AudioDevices.inputs()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Dictation key", selection: $s.hotkeyRaw) {
                    ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Hands-free: double-tap to start, tap to stop", isOn: $s.handsFree)
            }
            Section("Recognition") {
                Toggle("Hinglish mode (Hindi + English in Latin letters)", isOn: $s.hinglish)
                Toggle("Voice activity detection (Silero)", isOn: $s.vad)
                Toggle("Live typing (insert words while you speak)", isOn: $s.liveTyping)
                if s.liveTyping {
                    Text("Voice commands, snippets, app styles, and AI cleanup apply only when live typing is off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Text") {
                Toggle("Auto-format text", isOn: $s.autoFormat)
                Toggle("Voice commands", isOn: $s.voiceCommands)
                Text("Say “new line”, “new paragraph”, “full stop”, “comma”, “question mark”. Say only “delete that” or “undo” to edit.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("AI cleanup (Apple on-device model)", isOn: $s.aiCleanup)
                    .disabled(!AICleaner.isAvailable)
                if let why = AICleaner.unavailableReason {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Microphone") {
                Picker("Input", selection: $s.micUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                HStack {
                    Button(mic.running ? "Stop Test" : "Test") {
                        mic.running ? mic.stop() : mic.start(uid: s.micUID)
                    }
                    ProgressView(value: Double(mic.level))
                        .tint(mic.level > 0.85 ? .red : .green)
                    Button("Refresh") { devices = AudioDevices.inputs() }
                }
                if let err = mic.error { Text(err).font(.caption).foregroundStyle(.red) }
            }
            Section("App") {
                Toggle("Sound feedback", isOn: $s.soundFeedback)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                HStack {
                    Toggle("Check for updates daily", isOn: $s.autoUpdateCheck)
                    Spacer()
                    Button("Check Now") { UpdateChecker.check(userInitiated: true) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.micUID) { uid in if mic.running { mic.start(uid: uid) } }
        .onDisappear { mic.stop() }
    }
}

// MARK: - Models

private struct ModelsTab: View {
    @ObservedObject var models: ModelCenter
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        Form {
            Section("Speech model") {
                ForEach(ModelFile.speechModels, id: \.id) { f in
                    ModelRow(store: models.stores[f.id]!, selected: s.modelID == f.id, loaded: models.loadedID == f.id,
                             select: { s.modelID = f.id }, delete: { models.delete(f.id) })
                }
                Text("All models are multilingual and run on this Mac with Metal. Turbo gives the best accuracy for Indian English.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice activity detection") {
                ModelRow(store: models.vad, selected: s.vad, loaded: false, select: nil, delete: { models.vad.delete() })
            }
            Section {
                Button("Show Models in Finder") {
                    try? FileManager.default.createDirectory(at: WhisperModelStore.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(WhisperModelStore.directory)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    @ObservedObject var store: WhisperModelStore
    let selected: Bool
    let loaded: Bool
    let select: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        HStack {
            if let select {
                Button(action: select) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading) {
                Text(store.file.title)
                Text("\(store.file.sizeLabel) · \(stateText)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch store.state {
            case .missing, .failed:
                Button("Download") { store.prepare() }
            case .downloading(let p):
                ProgressView(value: p).frame(width: 100)
                Button("Cancel", action: delete)
            case .verifying:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Redownload") { store.discardAndRetry() }
                Button("Delete", role: .destructive, action: delete)
            }
        }
    }

    private var stateText: String {
        switch store.state {
        case .missing: "Not downloaded"
        case .downloading(let p): "Downloading \(Int(p * 100))%"
        case .verifying: "Verifying"
        case .ready: loaded ? "Loaded" : "Downloaded"
        case .failed(let r): "Failed: \(r)"
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section("Custom vocabulary") {
                TextEditor(text: $s.vocabulary)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                Text("One term per line or comma: names, places, brands, tech words (e.g. Ashvini, Koramangala, Kubernetes). Whisper gets these as hints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Snippets") {
                ForEach($s.snippets) { $sn in
                    HStack {
                        TextField("Say", text: $sn.trigger).frame(width: 160)
                        TextField("Types", text: $sn.text)
                        Button(role: .destructive) {
                            s.snippets.removeAll { $0.id == sn.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Say (e.g. my email)", text: $trigger).frame(width: 160)
                    TextField("Types (e.g. ashvini@example.com)", text: $text)
                    Button("Add") {
                        s.snippets.append(Snippet(trigger: trigger, text: text))
                        trigger = ""
                        text = ""
                    }
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - App Styles

private struct StylesTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var pick = ""

    private struct RunningApp: Identifiable { let id: String; let name: String }

    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { RunningApp(id: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        Form {
            Section("Overrides") {
                if s.appStyles.isEmpty {
                    Text("No overrides. Built-in: chat apps are casual, mail apps are formal, IDEs and terminals are code-safe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(s.appStyles.keys.sorted(), id: \.self) { id in
                    HStack {
                        Text(name(for: id))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { s.appStyles[id] ?? .standard },
                            set: { s.appStyles[id] = $0 }
                        )) {
                            ForEach(AppStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .frame(width: 180)
                        Button(role: .destructive) { s.appStyles[id] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Add app") {
                HStack {
                    Picker("Running app", selection: $pick) {
                        Text("Choose…").tag("")
                        ForEach(runningApps) { Text($0.name).tag($0.id) }
                    }
                    Button("Add") {
                        s.appStyles[pick] = AppStyle.for(bundleID: pick, overrides: [:])
                        pick = ""
                    }
                    .disabled(pick.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func name(for id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject private var h = HistoryStore.shared
    @State private var query = ""
    @State private var sel = Set<UUID>()

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? h.entries : h.entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                Button("Copy") { copy() }.disabled(sel.isEmpty)
                Button("Delete") { h.delete(sel); sel.removeAll() }.disabled(sel.isEmpty)
                Button("Export…") { h.export() }.disabled(h.entries.isEmpty)
                Button("Clear All", role: .destructive) { h.clear(); sel.removeAll() }.disabled(h.entries.isEmpty)
            }
            List(filtered, selection: $sel) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.text).lineLimit(3).textSelection(.enabled)
                    Text("\(e.date.formatted(date: .abbreviated, time: .shortened))\(e.app.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.text, forType: .string) }
                }
            }
            Text("History stays on this Mac (\(h.entries.count) items).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy() {
        let text = filtered.filter { sel.contains($0.id) }.map(\.text).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Stats

private struct StatsTab: View {
    @ObservedObject private var h = HistoryStore.shared

    var body: some View {
        let st = h.stats
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                tile("Words today", "\(st.todayWords)")
                tile("Total words", "\(st.totalWords)")
                tile("Dictations", "\(st.sessions)")
                tile("Time saved", st.minutesSaved < 60 ? "\(Int(st.minutesSaved)) min" : String(format: "%.1f h", st.minutesSaved / 60))
            }
            Text("Words per day (last 14 days)").font(.headline)
            Chart(st.daily) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words))
                    .foregroundStyle(.blue.gradient)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .frame(minHeight: 200)
            Text("Time saved compares your words at 40 wpm typing with the time you spoke.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
