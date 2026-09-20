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

    // MARK: - Live Session

    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    /// Identifies the current live session so a previous session's task —
    /// still finishing up asynchronously after endAudio() — can recognize
    /// it's stale and drop its results instead of delivering them through
    /// onUpdate into what is by then a *new* session's state. Without this,
    /// starting a new session quickly after ending the last one (e.g. two
    /// fast fn taps) let the old task's trailing partials/final keep
    /// firing into the new session, corrupting its transcript.
    private var sessionID = 0

    /// Whether the current session is still meant to be recording — set
    /// false only by `endLiveSession`. Distinct from having a *live task*:
    /// a mid-session error ends the current task (Speech framework never
    /// delivers further results on a task once its handler has seen an
    /// error), but the user may still be holding the key, so as long as
    /// this stays true, a fresh task is started transparently to keep
    /// capturing the rest of what they say instead of silently going deaf
    /// for the remainder of the hold.
    private var isSessionActive = false
    private var onUpdate: ((String) -> Void)?

    /// Starts a live recognition session fed directly from the mic tap
    /// (via `feed`), instead of transcribing a finished recording file.
    ///
    /// On-device recognition's partial results are the *entire*
    /// transcription-so-far, re-guessed from scratch each time — not a
    /// stream of new fragments — and it rarely (if ever) finalizes a
    /// mid-stream segment (`isFinal`) on its own; that only reliably fires
    /// once, when `endAudio()` is called. So `onUpdate` is called with the
    /// full current best-guess transcript on *every* result (partial or
    /// final) — it's the caller's job to reconcile that against whatever
    /// is already on screen (see `TextInjector.updateLiveStream`), which is
    /// what makes text actually appear while the user is still talking
    /// instead of only once at the end. Called on the main queue.
    func startLiveSession(onUpdate: @escaping (String) -> Void) {
        guard recognizer.isAvailable else {
            NSLog("SpeechRecognizer: not available for live session")
            return
        }
        endLiveSession()

        isSessionActive = true
        self.onUpdate = onUpdate
        startTask()
    }

    /// A single underlying recognition task within the live session.
    /// `SFSpeechRecognitionTask` never delivers another result once its
    /// handler has been called with an error — on-device recognition can
    /// throw a transient "No speech detected" early in a session before
    /// real speech has accumulated, which used to just kill transcription
    /// silently for the rest of the hold even though `feed` kept appending
    /// buffers to the now-dead request. Restarting the task (same session,
    /// same onUpdate, buffers routed to the new request from here on) is
    /// what actually keeps the rest of the utterance from being lost.
    private func startTask() {
        sessionID += 1
        let thisSessionID = sessionID
        fedBufferCount = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        liveRequest = request

        liveTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error = error {
                Self.debugLog("live session error — \(error)")
                DispatchQueue.main.async {
                    guard let self, self.sessionID == thisSessionID, self.isSessionActive else { return }
                    Self.debugLog("restarting task after error, session still active")
                    self.startTask()
                }
                return
            }
            guard let result = result else { return }
            let text = result.bestTranscription.formattedString
            Self.debugLog("recognitionTask result isFinal=\(result.isFinal) text=\(text)")
            DispatchQueue.main.async {
                guard let self, self.sessionID == thisSessionID else { return }
                self.onUpdate?(text)
            }
        }
    }

    /// Feeds one live-captured buffer into the running session. Safe to call
    /// from the audio render thread — `SFSpeechAudioBufferRecognitionRequest`
    /// is documented as safe to append to from any thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        liveRequest?.append(buffer)
        fedBufferCount += 1
        if fedBufferCount % 50 == 0 {
            Self.debugLog("fed \(fedBufferCount) buffers so far")
        }
    }

    private var fedBufferCount = 0

    private static func debugLog(_ message: String) {
        let line = "\(Date()): [Speech] \(message)\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("voxtype_debug.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: path)
        }
    }

    /// Ends the live session. `endAudio()` triggers one last result
    /// (usually `isFinal`) asynchronously, which still arrives through the
    /// same `onUpdate` callback passed to `startLiveSession` — so the
    /// caller keeps reconciling exactly as it did for every partial before
    /// this. `onSettled` fires after a short grace window once that last
    /// result has had time to land, so the caller can wrap up (e.g. settle
    /// the HUD) instead of guessing when the task is really done.
    func endLiveSession(onSettled: (() -> Void)? = nil) {
        isSessionActive = false

        guard let request = liveRequest else {
            onUpdate = nil
            onSettled?()
            return
        }
        request.endAudio()
        liveRequest = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.liveTask?.cancel()
            self?.liveTask = nil
            self?.onUpdate = nil
            onSettled?()
        }
    }
}