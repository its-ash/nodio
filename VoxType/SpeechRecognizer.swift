import Accelerate
import AVFoundation
import Foundation
import whisper

/// On-device Indian English transcription with whisper.cpp (Metal).
/// Partial results come from re-decoding the growing audio window on a
/// fixed tick; the window is trimmed at segment boundaries so cost stays
/// bounded on long holds.
final class SpeechRecognizer {
    private static let sampleRate = 16_000.0
    private static let tickInterval: TimeInterval = 1.2
    private static let maxWindowSeconds = 20.0
    private static let minSpeechSeconds = 0.3
    private static let minDecodeSamples = Int(sampleRate * 1.1)
    private static let silenceRMS: Float = 0.004
    private static let noSpeechProb: Float = 0.6
    private static let language = strdup("en")!
    private static let basePrompt = "Dictation in Indian English, with proper punctuation and capitalisation."
    private static let hinglishPrompt = "Haan, main kal office aaunga. Theek hai, meeting 5 baje rakhte hain. Thank you so much, bhai!"

    /// Per-session options, captured when a session starts.
    struct Config: Equatable {
        var hinglish = false
        var vocabulary: [String] = []
        var vadModelPath: String?

        var prompt: String {
            let head = hinglish ? SpeechRecognizer.hinglishPrompt : SpeechRecognizer.basePrompt
            // Whisper only reads the last ~224 prompt tokens; keep the list short.
            let terms = vocabulary.prefix(60).joined(separator: ", ")
            return terms.isEmpty ? head : "\(head) Terms: \(terms)."
        }
    }
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!
    private static let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    private struct Segment { let text: String; let t0: Int64 }

    // Whisper queue only.
    private let queue = DispatchQueue(label: "com.nodio.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    private var committed = ""
    private var qSession = 0
    private var qPrompt: UnsafeMutablePointer<CChar>?
    private var qVADPath: UnsafeMutablePointer<CChar>?

    // Guarded by `lock` (audio thread + whisper queue + main).
    private let lock = NSLock()
    private var samples: [Float] = []
    private var accepting = false
    private var converter: AVAudioConverter?

    // Main thread only.
    private(set) var isReady = false
    private var sessionID = 0
    private var pending = false
    private var timer: Timer?
    private var onUpdate: ((String, Bool) -> Void)?

    init() {
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let ctx { whisper_free(ctx) }
        free(qPrompt)
        free(qVADPath)
    }

    /// Loads the ggml model off the main thread. `completion` runs on main.
    func load(modelURL: URL, completion: @escaping (Bool) -> Void) {
        isReady = false
        queue.async { [weak self] in
            guard let self else { return }
            if let old = self.ctx { whisper_free(old); self.ctx = nil }
            var cp = whisper_context_default_params()
            cp.use_gpu = true
            cp.flash_attn = true
            let c = modelURL.path.withCString { whisper_init_from_file_with_params($0, cp) }
            self.ctx = c
            DispatchQueue.main.async {
                self.isReady = c != nil
                Self.debugLog("model load \(c != nil ? "ok" : "FAILED") — \(modelURL.lastPathComponent)")
                completion(c != nil)
            }
        }
    }

    // MARK: - Live Session

    /// `onUpdate(text, isFinal)` gets the full best-guess transcript so far,
    /// on main. The last call (after `endLiveSession`) has `isFinal = true`.
    func startLiveSession(config: Config, onUpdate: @escaping (String, Bool) -> Void) {
        guard isReady else { return }
        timer?.invalidate()
        sessionID += 1
        let id = sessionID
        self.onUpdate = onUpdate
        pending = false

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        converter = nil
        accepting = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.committed = ""
            self.qSession = id
            free(self.qPrompt)
            free(self.qVADPath)
            self.qPrompt = strdup(config.prompt)
            self.qVADPath = config.vadModelPath.flatMap { strdup($0) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick(id)
        }
    }

    /// Safe to call from the audio render thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, buffer.frameLength > 0 else { return }

        let fmt = buffer.format
        if converter?.inputFormat != fmt {
            converter = AVAudioConverter(from: fmt, to: Self.targetFormat)
        }
        guard let converter else { return }

        let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / fmt.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: cap) else { return }

        var consumed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if consumed { inStatus.pointee = .noDataNow; return nil }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.floatChannelData, out.frameLength > 0 else {
            if let err { Self.debugLog("convert error — \(err)") }
            return
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Runs one last full decode, delivers it through the session's
    /// `onUpdate`, then calls `onSettled` on main.
    func endLiveSession(onSettled: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil

        lock.lock()
        let wasAccepting = accepting
        accepting = false
        lock.unlock()

        let id = sessionID
        let deliver = onUpdate
        onUpdate = nil
        guard wasAccepting else { onSettled?(); return }

        queue.async { [weak self] in
            let text = self?.qSession == id ? self?.transcribe(final: true) ?? "" : ""
            DispatchQueue.main.async {
                if let self, id == self.sessionID { deliver?(text, true) }
                onSettled?()
            }
        }
    }

    // MARK: - Decoding

    private func tick(_ id: Int) {
        guard id == sessionID, !pending else { return }
        pending = true
        queue.async { [weak self] in
            guard let self else { return }
            let text = self.qSession == id ? self.transcribe(final: false) : ""
            DispatchQueue.main.async {
                guard id == self.sessionID else { return }
                self.pending = false
                if !text.isEmpty { self.onUpdate?(text, false) }
            }
        }
    }

    /// Whisper queue only.
    private func transcribe(final: Bool) -> String {
        lock.lock()
        let window = samples
        lock.unlock()

        let secs = Double(window.count) / Self.sampleRate
        var words: [String] = []
        if secs >= Self.minSpeechSeconds, vDSP.rootMeanSquare(window) >= Self.silenceRMS {
            let segs = decode(window, final: final)
            if !final, secs > Self.maxWindowSeconds, segs.count > 1, let last = segs.last, last.t0 > 0 {
                committed = Self.join(committed, segs.dropLast().map(\.text).joined(separator: " "))
                let cut = min(window.count, Int(Double(last.t0) / 100 * Self.sampleRate))
                lock.lock()
                samples.removeFirst(min(cut, samples.count))
                lock.unlock()
                words = Self.words(last.text)
            } else {
                words = Self.words(segs.map(\.text).joined(separator: " "))
            }
        }
        // The trailing word of a partial is often cut mid-utterance; hold it
        // back so the count-based injector never commits a half word.
        if !final { words = Array(words.dropLast()) }
        return Self.join(committed, words.joined(separator: " "))
    }

    private func decode(_ window: [Float], final: Bool) -> [Segment] {
        guard let ctx else { return [] }
        var pcm = window
        if pcm.count < Self.minDecodeSamples {
            pcm.append(contentsOf: repeatElement(0, count: Self.minDecodeSamples - pcm.count))
        }

        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Self.threads
        p.language = UnsafePointer(Self.language)
        p.initial_prompt = qPrompt.map { UnsafePointer($0) }
        if let qVADPath {
            p.vad = true
            p.vad_model_path = UnsafePointer(qVADPath)
        }
        p.translate = false
        p.no_context = true
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.no_speech_thold = Self.noSpeechProb
        if !final { p.temperature_inc = 0 }

        let rc = pcm.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        guard rc == 0 else {
            Self.debugLog("whisper_full failed rc=\(rc)")
            return []
        }

        return (0..<whisper_full_n_segments(ctx)).compactMap { i in
            guard whisper_full_get_segment_no_speech_prob(ctx, i) < Self.noSpeechProb,
                  let cstr = whisper_full_get_segment_text(ctx, i) else { return nil }
            let text = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isNonSpeechTag(text) else { return nil }
            return Segment(text: text, t0: whisper_full_get_segment_t0(ctx, i))
        }
    }

    // MARK: - Helpers

    /// Whisper marks noise as e.g. "[BLANK_AUDIO]", "(music)", "*cough*".
    private static func isNonSpeechTag(_ s: String) -> Bool {
        guard let f = s.first, let l = s.last else { return true }
        return ("[(*".contains(f) && "])*".contains(l)) || s.allSatisfy { $0.isPunctuation || $0.isWhitespace }
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : "\(a) \(b)"
    }

    static func debugLog(_ message: String) {
        let line = "\(Date()): [Whisper] \(message)\n"
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
}
