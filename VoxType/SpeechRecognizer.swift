import Speech
import AVFoundation
import Foundation

/// On-device speech transcription using `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true` for complete privacy and offline support.
final class SpeechRecognizer {
    private let recognizer: SFSpeechRecognizer

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()!
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