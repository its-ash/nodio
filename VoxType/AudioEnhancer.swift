import AVFoundation
import Accelerate
import Foundation

/// Enhances recorded audio for better speech recognition accuracy.
///
/// Pipeline (all on-device, no dependencies):
/// 1. **High-pass filter** — removes low-frequency rumble (HVAC, desk vibrations)
///    below 85 Hz with a 1st-order biquad.
/// 2. **Peak normalization** — scales to 0.95 FS with clamped gain.
///
/// A windowed noise gate + spectral subtraction + compressor stage used to
/// run here too, but that DSP chain was the repeated root cause of dropped
/// or truncated speech at the start of a recording — particularly right
/// after the user pauses before speaking, where the first ~2s window's
/// noise floor is estimated almost entirely from silence, and the
/// compressor's envelope follower then needs time to catch up once real
/// speech starts. Given how often that regressed actual transcription
/// accuracy, this stays deliberately simple: keep the signal, just make
/// sure it's loud enough for the recognizer.
///
/// All DSP loops use vDSP (Accelerate) for SIMD-accelerated vector ops.
final class AudioEnhancer {

    // MARK: - Public

    /// Processes the audio file at `url` and writes an enhanced version to a
    /// new temporary file. Returns the URL of the enhanced file, or the
    /// original URL if enhancement failed.
    static func enhance(fileAt url: URL) -> URL? {
        guard let inputFile = try? AVAudioFile(forReading: url) else { return nil }
        let inputFormat = inputFile.processingFormat
        let inputFrameCount = inputFile.length

        guard inputFrameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                            frameCapacity: AVAudioFrameCount(inputFrameCount)) else {
            return nil
        }

        do {
            try inputFile.read(into: buffer)
        } catch {
            NSLog("AudioEnhancer: failed to read buffer — \(error)")
            return nil
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = Float(inputFormat.sampleRate)

        for ch in 0..<channels {
            let data = channelData[ch]

            // 1. High-pass filter (85 Hz, 1st-order)
            applyHighPassFilter(data: data, count: frameLength, sampleRate: sampleRate)

            // 2. Peak normalization
            normalizePeak(data: data, count: frameLength)
        }

        // Write enhanced audio
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodio_enhanced_\(UUID().uuidString).caf")

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        )!

        guard let outputFile = try? AVAudioFile(forWriting: outputURL,
                                                 settings: outputFormat.settings) else {
            return nil
        }

        do {
            try outputFile.write(from: buffer)
        } catch {
            NSLog("AudioEnhancer: failed to write enhanced file — \(error)")
            return nil
        }

        return outputURL
    }

    // MARK: - 1. High-Pass Filter (1st-order biquad)

    /// Removes low-frequency rumble below ~85 Hz.
    /// Uses a 1st-order high-pass: y[n] = a0*x[n] + a1*x[n-1] - b1*y[n-1]
    private static func applyHighPassFilter(data: UnsafeMutablePointer<Float>,
                                            count: Int, sampleRate: Float) {
        let cutoff: Float = 85.0
        let dt = 1.0 / sampleRate
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let alpha = rc / (rc + dt)

        var prevX: Float = 0
        var prevY: Float = 0

        for i in 0..<count {
            let x = data[i]
            let y = alpha * (prevY + x - prevX)
            data[i] = y
            prevX = x
            prevY = y
        }
    }

    // MARK: - 2. Peak Normalization

    /// Scales the signal so the peak amplitude reaches 0.95 FS.
    /// Gain is clamped to [1.0, 20.0] to avoid over-boosting silence.
    private static func normalizePeak(data: UnsafeMutablePointer<Float>, count: Int) {
        // Find peak using vDSP
        var peak: Float = 0
        vDSP_maxmgv(data, 1, &peak, vDSP_Length(count))

        guard peak > 0 else { return }

        let targetPeak: Float = 0.95
        var gain = targetPeak / peak
        gain = max(1.0, min(gain, 20.0))

        vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(count))
    }
}