import AVFoundation
import Foundation

/// Opt-in test recordings. Each dictation is saved as a pair with the same
/// name: `.wav` (16 kHz mono, as it reached Whisper, before input
/// conditioning) and `.txt` (Whisper's raw final text). Replaying the same
/// clips makes it possible to judge a change by numbers instead of feel.
/// Files stay on this Mac; only the newest `limit` pairs are kept.
enum RecordingStore {
    static let limit = 30

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nodio/Recordings", isDirectory: true)
    }()

    private static let queue = DispatchQueue(label: "com.nodio.recordings", qos: .utility)

    // Used on `queue` only.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    static func save(samples: [Float], sampleRate: Double, text: String, language: DictationLanguage) {
        guard !samples.isEmpty else { return }
        let date = Date()
        queue.async {
            let name = "\(stamp.string(from: date))_\(language.rawValue)"
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try writeWAV(samples, sampleRate: sampleRate, to: directory.appendingPathComponent(name + ".wav"))
                try text.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
                prune()
            } catch {
                SpeechRecognizer.debugLog("recording save failed — \(error)")
            }
        }
    }

    static func deleteAll() {
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// 16-bit PCM WAV; the file type comes from the extension.
    private static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = buf.frameCapacity
        samples.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: $0.count) }
        // The file is finalised when it goes out of scope.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
    }

    /// Names start with a sortable timestamp, so newest-first is a name sort.
    private static func prune() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let wavs = items.filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for wav in wavs.dropFirst(limit) {
            try? fm.removeItem(at: wav)
            try? fm.removeItem(at: wav.deletingPathExtension().appendingPathExtension("txt"))
        }
    }
}
