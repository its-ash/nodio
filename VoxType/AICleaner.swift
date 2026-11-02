import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional grammar cleanup with Apple's on-device language model (macOS 26+).
/// Returns the input unchanged when the model is missing, slow, or fails.
enum AICleaner {
    private static let timeout: Duration = .seconds(6)

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let r): return "Apple Intelligence unavailable (\(r))"
            }
        }
        #endif
        return "Needs macOS 26 with Apple Intelligence"
    }

    static func clean(_ text: String, style: AppStyle) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let result = await withTaskGroup(of: String?.self) { group in
                group.addTask { try? await run(text, style: style) }
                group.addTask { try? await Task.sleep(for: timeout); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let result, !result.isEmpty, Double(result.count) < Double(text.count) * 2 + 40 {
                return result
            }
        }
        #endif
        return text
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func run(_ text: String, style: AppStyle) async throws -> String {
        let tone = switch style {
        case .casual: "Keep a casual chat tone. No trailing full stop on a single sentence."
        case .formal: "Use a polite, professional tone suitable for email."
        case .code: "Keep identifiers, file names, and symbols exactly as written. Do not add prose."
        case .standard: "Keep the tone neutral."
        }
        let instructions = """
        You clean up dictated text from an Indian English speaker. \
        Fix grammar, punctuation, and capitalisation. Remove false starts and repeated words. \
        If the speaker lists several items, format them as a bulleted list with "- ". \
        Keep the meaning, Indian English vocabulary, and names exactly. Do not add new content. \
        Do not answer questions in the text. \(tone) \
        Reply with only the cleaned text.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
