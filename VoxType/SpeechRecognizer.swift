import Speech
import AVFoundation
import Foundation

/// On-device speech transcription using `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true` for complete privacy and offline support.
final class SpeechRecognizer {
    private let recognizer: SFSpeechRecognizer

    /// `nil` falls back to `Locale.current` (the system region), then en-US.
    /// Pass a specific identifier (e.g. "en-IN") to force an accent-specific
    /// on-device model regardless of system locale.
    init(localeIdentifier: String? = nil) {
        let requested = localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current
        if let match = SFSpeechRecognizer(locale: requested), match.supportsOnDeviceRecognition {
            recognizer = match
        } else if let system = SFSpeechRecognizer(locale: Locale.current), system.supportsOnDeviceRecognition {
            NSLog("SpeechRecognizer: \(requested.identifier) has no on-device model, using system locale \(system.locale.identifier)")
            recognizer = system
        } else {
            NSLog("SpeechRecognizer: no on-device model for requested/system locale, falling back to en-US")
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()!
        }
        if recognizer.supportsOnDeviceRecognition {
            recognizer.defaultTaskHint = .dictation
        }
    }

    // MARK: - Public

    func transcribe(fileAt url: URL, completion: @escaping (String?) -> Void) {
        guard recognizer.isAvailable else {
            NSLog("SpeechRecognizer: not available")
            completion(nil)
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                NSLog("SpeechRecognizer: authorization denied (\(status.rawValue))")
                completion(nil)
                return
            }

            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if self.recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            self.recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    NSLog("SpeechRecognizer: error — \(error)")
                    completion(nil)
                    return
                }

                guard let result = result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                completion(text)
            }
        }
    }
}