import Foundation

/// Cleans up dictation output: strips filler words, fixes spacing and
/// capitalisation, then applies the per-app style.
enum TranscriptFormatter {

    // Only unambiguous verbal tics. Phrases like "you know" or "I mean" are
    // real content too often to strip safely.
    private static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "hmm",
    ]

    static func format(_ raw: String, style: AppStyle = .standard) -> String {
        var text = stripFillerWords(raw)
        text = collapseWhitespace(text)

        switch style {
        case .code:
            // Keep the text as spoken: no sentence casing, no trailing period.
            text = stripTrailingPeriod(text)
        case .casual:
            text = capitalizeSentences(text)
            text = stripTrailingPeriod(text)
        case .formal:
            text = capitalizeSentences(text)
            text = ensureTerminalPunctuation(text)
        case .standard:
            text = capitalizeSentences(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filler Removal

    private static func stripFillerWords(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: true)
                .filter { !fillerWords.contains($0.trimmingCharacters(in: .punctuationCharacters).lowercased()) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: - Whitespace

    /// Collapses spaces and tabs but keeps newlines from voice commands.
    private static func collapseWhitespace(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "([,;:])[ \\t]*([.!?])", with: "$2", options: .regularExpression)
        return result
    }

    // MARK: - Punctuation

    private static func stripTrailingPeriod(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix(".") && !t.hasSuffix("...") ? String(t.dropLast()) : t
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last, !".!?…\u{201D})".contains(last) else { return t }
        return t + "."
    }

    // MARK: - Capitalization

    /// Capitalizes the first letter of the text, after . ! ? followed by
    /// whitespace (so "a@b.in" stays as is), and after a newline.
    /// Also capitalizes the standalone word "i".
    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if !c.isWhitespace {
                capitalizeNext = false
            }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if c == "\n" || (".!?".contains(c) && next.isWhitespace) { capitalizeNext = true }
        }
        return String(chars).replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
    }
}
