import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let text: String
    let app: String?
    let seconds: Double
}

/// On-device dictation history and usage stats, stored as JSON in Application Support.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    private static let maxEntries = 1000
    private static let typingWPM = 40.0

    @Published private(set) var entries: [HistoryEntry] = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nodio/history.json")
    }()
    private let io = DispatchQueue(label: "com.nodio.history", qos: .utility)

    private init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
    }

    // MARK: - Mutations (main thread)

    func add(_ text: String, app: String?, seconds: Double) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.insert(HistoryEntry(date: Date(), text: t, app: app, seconds: seconds), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        persist()
    }

    func delete(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        let snapshot = entries, url = url
        io.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: - Export

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Nodio History.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let data: Data?
        if dest.pathExtension.lowercased() == "json" {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            data = try? enc.encode(entries)
        } else {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            data = entries.map { "## \(fmt.string(from: $0.date))\($0.app.map { " · \($0)" } ?? "")\n\n\($0.text)\n" }
                .joined(separator: "\n").data(using: .utf8)
        }
        do {
            try data?.write(to: dest, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Stats

    struct DayCount: Identifiable {
        let day: Date
        let words: Int
        var id: Date { day }
    }

    struct Stats {
        let totalWords: Int
        let sessions: Int
        let todayWords: Int
        let minutesSaved: Double
        let daily: [DayCount]
    }

    var stats: Stats {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var total = 0, todayWords = 0, spoken = 0.0
        var perDay: [Date: Int] = [:]
        for e in entries {
            let n = Self.wordCount(e.text)
            total += n
            spoken += e.seconds
            let day = cal.startOfDay(for: e.date)
            perDay[day, default: 0] += n
            if day == today { todayWords += n }
        }
        let typingMinutes = Double(total) / Self.typingWPM
        let daily = (0..<14).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .map { DayCount(day: $0, words: perDay[$0] ?? 0) }
        return Stats(
            totalWords: total, sessions: entries.count, todayWords: todayWords,
            minutesSaved: max(0, typingMinutes - spoken / 60), daily: daily
        )
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}
