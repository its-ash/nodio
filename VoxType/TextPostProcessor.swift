import Foundation

/// Turns a final raw transcript into the text to insert, or into an editing action.
enum TextPostProcessor {
    enum Action: Equatable {
        case insert(String)
        case deleteLast
        case undo
        case none
    }

    private static let deleteCommands: Set<String> = ["delete that", "scratch that", "erase that", "remove that"]
    private static let undoCommands: Set<String> = ["undo", "undo that"]

    /// Spoken punctuation. Order matters: longer phrases first.
    private static let spoken: [(phrase: String, symbol: String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"), ("next line", "\n"),
        ("full stop", "."), ("question mark", "?"),
        ("exclamation mark", "!"), ("exclamation point", "!"),
        ("comma", ","), ("semicolon", ";"), ("colon", ":"),
        ("open bracket", "("), ("close bracket", ")"),
        ("open quote", "\u{201C}"), ("close quote", "\u{201D}"),
        ("hyphen", "-"), ("ellipsis", "…"),
    ]

    private static let spokenRegex: [(NSRegularExpression, String)] = spoken.map { item in
        let words = item.phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        // Whisper often wraps the spoken word in its own punctuation: "Hello, comma, world."
        let pattern = "[ \\t]*[,.]?[ \\t]*\\b" + words.joined(separator: "[ \\t]+") + "\\b[,.!?]?"
        return (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), item.symbol)
    }

    static func process(
        _ raw: String, style: AppStyle, settings: AppSettings
    ) -> Action {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if settings.voiceCommands {
            let key = trimmed.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if deleteCommands.contains(key) { return .deleteLast }
            if undoCommands.contains(key) { return .undo }
        }

        var text = trimmed
        if settings.voiceCommands { text = applySpokenPunctuation(text) }
        text = expandSnippets(text, settings.snippets)
        if settings.autoFormat { text = TranscriptFormatter.format(text, style: style) }
        return text.isEmpty ? .none : .insert(text)
    }

    static func applySpokenPunctuation(_ text: String) -> String {
        var out = text
        for (re, symbol) in spokenRegex {
            let tmpl = NSRegularExpression.escapedTemplate(for: symbol)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tmpl)
        }
        // "( word" → "(word", "word )" → "word)", and trim spaces around newlines.
        out = out.replacingOccurrences(of: "([(\u{201C}])[ \\t]+", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]+([)\u{201D}])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        return out
    }

    static func expandSnippets(_ text: String, _ snippets: [Snippet]) -> String {
        var out = text
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = s.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !s.text.isEmpty else { continue }
            let words = trigger.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "\\b" + words.joined(separator: "[ \\t,]+") + "\\b[.]?"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: s.text)
            )
        }
        return out
    }
}
