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

    /// Transcribes a recorded file by *streaming* its buffers into a
    /// SFSpeechAudioBufferRecognitionRequest rather than handing the whole
    /// file to SFSpeechURLRecognitionRequest in one shot.
    ///
    /// The URL-based batch request does a single holistic pass and its
    /// internal endpointing can misfire on a long pause mid-recording —
    /// observed as words before/after the pause being dropped or merged,
    /// with isFinal=true and an empty or truncated transcription and no
    /// error at all. Buffer streaming is the API's live-dictation path, so
    /// it segments speech around silence the way it's actually designed to,
    /// the same as it would for a continuously-spoken live recording.
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

            guard let audioFile = try? AVAudioFile(forReading: url) else {
                NSLog("SpeechRecognizer: failed to open recording for streaming")
                completion(nil)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            // Must be true here: with partials off, a long pause mid-stream
            // can make the recognizer finalize early on just the segment
            // spoken before the pause (isFinal=true), and the guard-once
            // completion then discards everything spoken after — only the
            // last thing said survived, the start was silently thrown away.
            // Track the latest result instead and only commit it once the
            // task actually finishes (isFinal, or the append loop below
            // calls endAudio and the task settles).
            request.shouldReportPartialResults = true
            if self.recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            var finished = false
            var latestText: String?
            let finish: (String?) -> Void = { text in
                guard !finished else { return }
                finished = true
                completion(text ?? latestText)
            }

            self.recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    NSLog("SpeechRecognizer: error — \(error)")
                    finish(latestText)
                    return
                }
                guard let result = result else { return }
                latestText = result.bestTranscription.formattedString
                if result.isFinal {
                    finish(latestText)
                }
            }

            // Feed the whole file in as a sequence of buffers, then signal
            // end-of-audio — this is what makes it a streaming request
            // instead of a single-shot batch one.
            let frameCount: AVAudioFrameCount = 4096
            let format = audioFile.processingFormat
            while true {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
                do {
                    try audioFile.read(into: buffer, frameCount: frameCount)
                } catch {
                    NSLog("SpeechRecognizer: buffer read error — \(error)")
                    break
                }
                guard buffer.frameLength > 0 else { break }
                request.append(buffer)
            }
            request.endAudio()
        }
    }
}