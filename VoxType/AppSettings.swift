import Combine
import CoreGraphics
import Foundation

// MARK: - Model Files

struct ModelFile: Equatable {
    let id: String
    let title: String
    let fileName: String
    let url: URL
    let sha256: String
    let byteSize: Int64

    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    static let small = ModelFile(
        id: "small", title: "Small · fastest", fileName: "ggml-small-q5_1.bin",
        url: URL(string: whisperBase + "ggml-small-q5_1.bin")!,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", byteSize: 190_085_487
    )
    static let medium = ModelFile(
        id: "medium", title: "Medium · balanced", fileName: "ggml-medium-q5_0.bin",
        url: URL(string: whisperBase + "ggml-medium-q5_0.bin")!,
        sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f", byteSize: 539_212_467
    )
    static let turbo = ModelFile(
        id: "turbo", title: "Large v3 Turbo · most accurate", fileName: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: whisperBase + "ggml-large-v3-turbo-q5_0.bin")!,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", byteSize: 574_041_195
    )
    static let vad = ModelFile(
        id: "vad", title: "Silero VAD v5.1.2", fileName: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf", byteSize: 885_098
    )

    static let speechModels = [small, medium, turbo]

    static func speech(id: String) -> ModelFile {
        speechModels.first { $0.id == id } ?? turbo
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

// MARK: - Per-App Style

enum AppStyle: String, CaseIterable, Codable, Identifiable {
    case standard, casual, formal, code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .casual: "Casual (chat)"
        case .formal: "Formal (mail)"
        case .code: "Code-safe (IDE)"
        }
    }

    private static let builtIn: [String: AppStyle] = [
        "com.tinyspeck.slackmacgap": .casual, "net.whatsapp.WhatsApp": .casual,
        "com.apple.MobileSMS": .casual, "com.hnc.Discord": .casual, "ru.keepcoder.Telegram": .casual,
        "com.apple.mail": .formal, "com.microsoft.Outlook": .formal, "com.readdle.smartemail-Mac": .formal,
        "com.apple.dt.Xcode": .code, "com.microsoft.VSCode": .code, "com.todesktop.230313mzl4w4u92": .code,
        "dev.zed.Zed": .code, "com.apple.Terminal": .code, "com.googlecode.iterm2": .code,
        "com.jetbrains.intellij": .code,
    ]

    static func `for`(bundleID: String?, overrides: [String: AppStyle]) -> AppStyle {
        guard let bundleID else { return .standard }
        return overrides[bundleID] ?? builtIn[bundleID] ?? .standard
    }
}

// MARK: - Language

enum DictationLanguage: String, CaseIterable, Identifiable {
    case english, hinglish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: "English (India)"
        case .hinglish: "Hinglish"
        }
    }
}

// MARK: - Hotkey

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: "Fn / Globe"
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .rightControl: "Right Control ⌃"
        }
    }

    /// Virtual key codes reported on flagsChanged. Fn can report 63 or 179 (Globe).
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: [63, 179]
        case .rightOption: [61]
        case .rightCommand: [54]
        case .rightControl: [62]
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        }
    }
}

// MARK: - Snippets

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
}

// MARK: - Settings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard
    private static let p = "com.nodio.app."

    @Published var soundFeedback: Bool { didSet { d.set(soundFeedback, forKey: Self.p + "soundFeedback") } }
    @Published var autoFormat: Bool { didSet { d.set(autoFormat, forKey: Self.p + "autoFormat") } }
    @Published var liveTyping: Bool { didSet { d.set(liveTyping, forKey: Self.p + "liveTyping") } }
    @Published var voiceCommands: Bool { didSet { d.set(voiceCommands, forKey: Self.p + "voiceCommands") } }
    @Published var language: DictationLanguage { didSet { d.set(language.rawValue, forKey: Self.p + "language") } }
    @Published var vad: Bool { didSet { d.set(vad, forKey: Self.p + "vad") } }
    @Published var autoUpdateCheck: Bool { didSet { d.set(autoUpdateCheck, forKey: Self.p + "autoUpdateCheck") } }
    @Published var handsFree: Bool { didSet { d.set(handsFree, forKey: Self.p + "handsFree") } }
    @Published var modelID: String { didSet { d.set(modelID, forKey: Self.p + "modelID") } }
    @Published var hotkeyRaw: String { didSet { d.set(hotkeyRaw, forKey: Self.p + "hotkey") } }
    @Published var micUID: String { didSet { d.set(micUID, forKey: Self.p + "micUID") } }
    @Published var vocabulary: String { didSet { d.set(vocabulary, forKey: Self.p + "vocabulary") } }
    @Published var snippets: [Snippet] { didSet { save(snippets, "snippets") } }
    @Published var appStyles: [String: AppStyle] { didSet { save(appStyles, "appStyles") } }

    var hotkey: HotkeyChoice { HotkeyChoice(rawValue: hotkeyRaw) ?? .fn }
    var model: ModelFile { ModelFile.speech(id: modelID) }

    /// Words from the vocabulary box, one per line or comma.
    var vocabularyTerms: [String] {
        vocabulary.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: Self.p + k) as? Bool ?? def }
        soundFeedback = bool("soundFeedback", true)
        autoFormat = bool("autoFormat", true)
        liveTyping = bool("liveTyping", false)
        voiceCommands = bool("voiceCommands", true)
        let lang = d.string(forKey: Self.p + "language")
        language = lang == "hindi" ? .hinglish
            : lang.flatMap(DictationLanguage.init(rawValue:)) ?? (bool("hinglish", false) ? .hinglish : .english)
        vad = bool("vad", true)
        autoUpdateCheck = bool("autoUpdateCheck", true)
        handsFree = bool("handsFree", true)
        modelID = d.string(forKey: Self.p + "modelID") ?? ModelFile.turbo.id
        hotkeyRaw = d.string(forKey: Self.p + "hotkey") ?? HotkeyChoice.fn.rawValue
        micUID = d.string(forKey: Self.p + "micUID") ?? ""
        vocabulary = d.string(forKey: Self.p + "vocabulary") ?? ""
        snippets = Self.load([Snippet].self, "snippets") ?? []
        appStyles = Self.load([String: AppStyle].self, "appStyles") ?? [:]
    }

    private func save<T: Encodable>(_ v: T, _ k: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: Self.p + k) }
    }

    private static func load<T: Decodable>(_ t: T.Type, _ k: String) -> T? {
        UserDefaults.standard.data(forKey: p + k).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }
}
