import Foundation

enum TranscriptRepair {
    private struct Term { let text: String; let norm: String; let words: Int }

    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’.\\-][\\p{L}\\p{N}]+)*")

    static func key(_ w: some StringProtocol) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func collapseRepeats(_ words: [String]) -> [String] {
        guard words.count >= 3 else { return words }
        let keys = words.map(key)
        var out: [String] = []
        out.reserveCapacity(words.count)
        var i = 0
        while i < words.count {
            var keep = i..<(i + 1)
            for n in 1...8 where i + 3 * n <= words.count {
                let gram = keys[i..<(i + n)]
                guard gram.contains(where: { !$0.isEmpty }) else { continue }
                var reps = 1
                while i + (reps + 1) * n <= keys.count,
                      keys[(i + reps * n)..<(i + (reps + 1) * n)].elementsEqual(gram) { reps += 1 }
                if reps >= (n == 1 ? 5 : 3) {
                    keep = (i + (reps - 1) * n)..<(i + reps * n)
                    break
                }
            }
            out.append(contentsOf: words[keep])
            i = keep.upperBound
        }
        return out
    }

    static func agreedPrefix(_ a: [String], _ b: [String]) -> Int {
        zip(a, b).prefix(while: { key($0.0) == key($0.1) }).count
    }

    static func applyVocabulary(_ text: String, terms: [String], fuzzy: Bool, isWord: (String) -> Bool) -> String {
        let vocab = terms.compactMap { raw -> Term? in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = norm(t)
            return n.count >= 2 ? Term(text: t, norm: n, words: t.split(whereSeparator: \.isWhitespace).count) : nil
        }
        guard !vocab.isEmpty, !text.isEmpty else { return text }
        let ns = text as NSString
        let tokens = tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !tokens.isEmpty else { return text }

        let byNorm = Dictionary(vocab.map { ($0.norm, $0) }, uniquingKeysWith: { a, _ in a })
        let maxSpan = min(6, max(3, vocab.map(\.words).max() ?? 1))
        let fuzzyTerms = fuzzy ? byNorm.values.filter { $0.words == 1 && $0.norm.count >= 5 } : []

        func joinable(_ a: NSRange, _ b: NSRange) -> Bool {
            let gap = ns.substring(with: NSRange(location: NSMaxRange(a), length: b.location - NSMaxRange(a)))
            return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "-" }
        }

        func exact(at i: Int) -> (span: Int, text: String)? {
            var reach = 1
            while reach < min(maxSpan, tokens.count - i), joinable(tokens[i + reach - 1], tokens[i + reach]) { reach += 1 }
            for k in stride(from: reach, through: 1, by: -1) {
                let parts = (i..<(i + k)).map { ns.substring(with: tokens[$0]) }
                let (stem, suffix) = splitPossessive(parts[k - 1])
                guard let term = byNorm[parts.dropLast().map(norm).joined() + norm(stem)] else { continue }
                if k == 1, stem == term.text || isWord(stem.lowercased()) { continue }
                if k > 1, term.words == 1, term.norm.count < 5 { continue }
                return (k, term.text + suffix)
            }
            return nil
        }

        func nearest(at i: Int) -> String? {
            let (stem, suffix) = splitPossessive(ns.substring(with: tokens[i]))
            let n = norm(stem)
            guard n.count >= 4, byNorm[n] == nil else { return nil }
            let scored = fuzzyTerms.compactMap { t -> (term: Term, d: Int)? in
                guard t.norm.first == n.first, abs(t.norm.count - n.count) <= 2 else { return nil }
                let d = editDistance(n, t.norm)
                return d <= (t.norm.count >= 8 ? 2 : 1) ? (t, d) : nil
            }
            guard let best = scored.min(by: { $0.d < $1.d }),
                  scored.lazy.filter({ $0.d == best.d }).count == 1,
                  !isWord(stem.lowercased()) else { return nil }
            return best.term.text + suffix
        }

        var out = ""
        var cursor = 0
        var i = 0
        while i < tokens.count {
            guard let hit = exact(at: i) ?? (fuzzyTerms.isEmpty ? nil : nearest(at: i).map { (span: 1, text: $0) }) else {
                i += 1
                continue
            }
            out += ns.substring(with: NSRange(location: cursor, length: tokens[i].location - cursor))
            out += hit.text
            cursor = NSMaxRange(tokens[i + hit.span - 1])
            i += hit.span
        }
        return out + ns.substring(from: cursor)
    }

    private static func norm(_ s: some StringProtocol) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func splitPossessive(_ w: String) -> (String, String) {
        guard w.count > 3, let last = w.last, last == "s" || last == "S",
              let ap = w.dropLast().last, ap == "'" || ap == "’" else { return (w, "") }
        return (String(w.dropLast(2)), String(w.suffix(2)))
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var pp = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = pp
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, pp[j - 2] + 1) }
                cur[j] = v
            }
            (pp, prev, cur) = (prev, cur, pp)
        }
        return prev[b.count]
    }
}
