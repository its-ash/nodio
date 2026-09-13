import AVFoundation
import Foundation

/// Captures microphone input via `AVAudioEngine`, writes to a temporary `.caf`
/// file, and reports real-time power levels for the HUD waveform.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var powerTimer: Timer?
    private var powerHandler: ((Float) -> Void)?

    // AVAudioPCMBuffer is reference-counted around a raw C buffer that
    // AVAudioEngine recycles between tap callbacks on its own realtime
    // thread. Sharing the buffer object itself with the main-thread power
    // timer let it read freed/rewritten memory mid-iteration — a data race
    // that surfaced as a SIGSEGV on longer recordings (more tap callbacks =
    // higher chance of colliding with the timer read). Instead, compute the
    // RMS level on the audio thread (where the buffer is guaranteed valid)
    // and hand off only a plain Float, guarded by a lock.
    private let levelLock = NSLock()
    private var latestLevel: Float = 0

    private(set) var isRecording = false

    // MARK: - Public

    func start(powerHandler: @escaping (Float) -> Void) {
        guard !isRecording else { return }
        self.powerHandler = powerHandler

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        let tempDir = FileManager.default.temporaryDirectory
        fileURL = tempDir.appendingPathComponent("voxtype_\(UUID().uuidString).caf")

        guard let url = fileURL else { return }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!

        do {
            file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
        } catch {
            NSLog("AudioRecorder: failed to create file — \(error)")
            return
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            self.updateLevel(from: buffer)
            do { try file.write(from: buffer) } catch { NSLog("AudioRecorder write: \(error)") }
        }

        do {
            try engine.start()
            isRecording = true
            startPowerMetering()
        } catch {
            NSLog("AudioRecorder: engine start failed — \(error)")
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording else { completion(nil); return }
        isRecording = false
        stopPowerMetering()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        powerHandler = nil
        levelLock.lock()
        latestLevel = 0
        levelLock.unlock()

        completion(fileURL)
        fileURL = nil
    }

    // MARK: - Power Metering

    private func startPowerMetering() {
        powerTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.measurePower()
        }
    }

    private func stopPowerMetering() {
        powerTimer?.invalidate()
        powerTimer = nil
    }

    private func measurePower() {
        levelLock.lock()
        let normalized = latestLevel
        levelLock.unlock()
        powerHandler?(normalized)
    }

    // MARK: - Level Calculation (runs on the audio render thread)

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        let samples = channelData[0]
        for i in 0..<frameLength {
            sum += samples[i] * samples[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(rms + 1e-8) // avoid log(0)
        let normalized = max(0, min(1, (db + 50) / 50)) // -50dB..0dB → 0..1

        levelLock.lock()
        latestLevel = normalized
        levelLock.unlock()
    }
}