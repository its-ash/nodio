import Foundation

/// Cleans up raw dictation output before it's injected: strips filler words,
/// fixes capitalization and spacing. SFSpeechRecognizer's dictation output is
/// generally free of stray whitespace but frequently lowercase-first and
/// full of verbal fillers that read poorly as written text.
enum TranscriptFormatter {

    // Only unambiguous verbal tics — never real words in normal English
    // sentences — are stripped. Phrases like "you know" or "I mean" were
    // stripped unconditionally too ("Now you know how to work" became
    // "Now how to work"), but those are common genuine grammatical content,
    // not just fillers, and can't be told apart from filler usage without
    // real context the recognizer output doesn't give us. So we no longer
    // touch them at all — better to leave an occasional true filler in than
    // to silently delete real words from what the user said.
    private static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "hmm",
    ]

    static func format(_ raw: String) -> String {
        var text = raw

        text = stripFillerWords(text)
        text = collapseWhitespace(text)
        text = capitalizeSentences(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filler Removal

    private static func stripFillerWords(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let kept = words.filter { word in
            let stripped = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return !fillerWords.contains(stripped)
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Whitespace

    private static func collapseWhitespace(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // No space before punctuation
        result = result.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Capitalization

    /// Capitalizes the first letter after sentence-ending punctuation, plus
    /// the very start of the text. Also capitalizes the standalone word "i".
    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var chars = Array(text)
        var capitalizeNext = true

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if !c.isWhitespace {
                capitalizeNext = false
            }
            if c == "." || c == "!" || c == "?" {
                capitalizeNext = true
            }
            i += 1
        }

        var result = String(chars)
        result = capitalizeStandaloneI(result)
        return result
    }

    private static func capitalizeStandaloneI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\bi\\b", with: "I", options: .regularExpression
        )
    }
}
