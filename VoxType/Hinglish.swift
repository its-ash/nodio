import Foundation

/// Devanagari → everyday Hinglish spelling ("नहीं यार, समझना" → "nahin yaar, samajhna").
/// Latin text passes through unchanged.
enum Hinglish {
    private struct Syl { var c = ""; var v = ""; var inherent = false; var tail = "" }

    private static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n",
        0x091A: "ch", 0x091B: "chh", 0x091C: "j", 0x091D: "jh", 0x091E: "n",
        0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n",
        0x0924: "t", 0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n",
        0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh", 0x092E: "m",
        0x092F: "y", 0x0930: "r", 0x0932: "l", 0x0933: "l", 0x0935: "v",
        0x0936: "sh", 0x0937: "sh", 0x0938: "s", 0x0939: "h",
        0x0958: "q", 0x0959: "kh", 0x095A: "g", 0x095B: "z", 0x095C: "r",
        0x095D: "rh", 0x095E: "f", 0x095F: "y",
    ]
    private static let nukta: [UInt32: String] = [
        0x0915: "q", 0x0916: "kh", 0x0917: "g", 0x091C: "z",
        0x0921: "r", 0x0922: "rh", 0x092B: "f", 0x092F: "y",
    ]
    private static let vowels: [UInt32: String] = [
        0x0905: "a", 0x0906: "aa", 0x0907: "i", 0x0908: "ee", 0x0909: "u", 0x090A: "oo",
        0x090B: "ri", 0x090D: "e", 0x090F: "e", 0x0910: "ai", 0x0911: "o", 0x0913: "o", 0x0914: "au",
    ]
    private static let matras: [UInt32: String] = [
        0x093E: "aa", 0x093F: "i", 0x0940: "ee", 0x0941: "u", 0x0942: "oo", 0x0943: "ri",
        0x0945: "e", 0x0947: "e", 0x0948: "ai", 0x0949: "o", 0x094B: "o", 0x094C: "au",
    ]
    private static let labials: Set<String> = ["p", "ph", "f", "b", "bh", "m"]
    private static let virama: UInt32 = 0x094D
    private static let nuktaSign: UInt32 = 0x093C
    private static let anusvara: UInt32 = 0x0902
    private static let candrabindu: UInt32 = 0x0901
    private static let visarga: UInt32 = 0x0903

    static func romanize(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) else { return s }
        var out = ""
        var word: [Unicode.Scalar] = []
        func flush() { out += romanizeWord(word); word.removeAll() }

        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x0964, 0x0965: flush(); out += "."
            case 0x0966...0x096F: flush(); out += String(ch.value - 0x0966)
            case 0x0900...0x097F: word.append(ch)
            case 0x200C, 0x200D: continue
            default: flush(); out.unicodeScalars.append(ch)
            }
        }
        flush()
        return out
    }

    private static func romanizeWord(_ u: [Unicode.Scalar]) -> String {
        var syls: [Syl] = []
        var i = 0
        while i < u.count {
            let x = u[i].value
            i += 1
            if var c = consonants[x] {
                if i < u.count, u[i].value == nuktaSign { c = nukta[x] ?? c; i += 1 }
                var s = Syl(c: c)
                if i < u.count, u[i].value == virama {
                    i += 1
                } else if i < u.count, let m = matras[u[i].value] {
                    s.v = m
                    i += 1
                } else {
                    s.v = "a"
                    s.inherent = true
                }
                syls.append(s)
            } else if let v = vowels[x] {
                syls.append(Syl(v: v))
            } else if !syls.isEmpty, [anusvara, candrabindu, visarga].contains(x) {
                syls[syls.count - 1].tail += x == visarga ? "h" : x == anusvara ? "M" : "n"
            }
        }
        guard !syls.isEmpty else { return "" }

        // Schwa deletion: drop the final inherent "a", then medial ones right to left (V C a C V).
        let last = syls.count - 1
        if last > 0, syls[last].inherent, syls[last].tail.isEmpty, !syls[last - 1].v.isEmpty {
            syls[last].v = ""
        }
        if last >= 2 {
            for k in stride(from: last - 1, through: 1, by: -1)
            where syls[k].inherent && syls[k].tail.isEmpty
                && !syls[k - 1].v.isEmpty && !syls[k + 1].c.isEmpty && !syls[k + 1].v.isEmpty {
                syls[k].v = ""
            }
        }

        // Common spelling at the word end: "kya", "nahin", "hun".
        if !syls[last].c.isEmpty {
            switch syls[last].v {
            case "aa" where syls[last].tail.isEmpty: syls[last].v = "a"
            case "ee": syls[last].v = "i"
            case "oo": syls[last].v = "u"
            default: break
            }
        }

        var out = ""
        for (k, s) in syls.enumerated() {
            let next = k < last ? syls[k + 1].c : ""
            out += s.c + s.v + s.tail.replacingOccurrences(of: "M", with: labials.contains(next) ? "m" : "n")
        }
        return out
    }
}
