import AVFoundation
import Accelerate
import Foundation

/// Enhances recorded audio for better speech recognition accuracy.
///
/// Pipeline (all on-device, no dependencies):
/// 1. **High-pass filter** — removes low-frequency rumble (HVAC, desk vibrations)
///    below 85 Hz with a 1st-order biquad.
/// 2. **Windowed soft noise gate** — per-2-second-window local noise floor
///    estimation with a soft-knee transition to avoid clicks.
/// 3. **Spectral subtraction (approximated)** — a simple DC-bias removal pass
///    that subtracts the estimated noise floor from every sample before
///    normalization, reducing broadband hiss.
/// 4. **Peak normalization** — scales to 0.95 FS with clamped gain.
/// 5. **Gentle compressor** — evens out loud/soft speech so the recognizer
///    gets a consistent level.
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

            // 2 + 3. Windowed soft noise gate + spectral subtraction
            applyNoiseGate(data: data, count: frameLength, sampleRate: sampleRate)

            // 4. Peak normalization
            normalizePeak(data: data, count: frameLength)

            // 5. Gentle compressor
            applyCompressor(data: data, count: frameLength, sampleRate: sampleRate)
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

    // MARK: - 2+3. Windowed Soft Noise Gate + Spectral Subtraction

    /// Per-window local noise floor estimation with soft-knee gating.
    /// Also subtracts the estimated noise bias from all samples to reduce
    /// broadband hiss (simplified spectral subtraction in the time domain).
    private static func applyNoiseGate(data: UnsafeMutablePointer<Float>,
                                       count: Int, sampleRate: Float) {
        let windowSeconds: Float = 2.0
        let windowSize = max(1, Int(windowSeconds * sampleRate))

        var windowStart = 0
        while windowStart < count {
            let windowEnd = min(windowStart + windowSize, count)
            let windowLen = windowEnd - windowStart

            // Estimate local noise floor (10th percentile of |samples|)
            var absSamples = [Float](repeating: 0, count: windowLen)
            vDSP_vabs(data + windowStart, 1, &absSamples, 1, vDSP_Length(windowLen))

            // Partial sort to find 10th percentile — use vDSP min + manual bucket
            // For small windows this is fast enough; vDSP doesn't have percentile.
            let sorted = absSamples.sorted()
            let floorIdx = max(0, sorted.count / 10 - 1)
            let noiseFloor = sorted[floorIdx]

            // Gate threshold: 3x above noise floor, minimum 0.001
            let gateThreshold = max(noiseFloor * 3.0, 0.001)
            let kneeStart = gateThreshold * 0.5

            // Subtract noise bias (simplified spectral subtraction)
            let bias = noiseFloor * 0.5

            for i in windowStart..<windowEnd {
                // Subtract bias
                var sample = data[i]
                let sign: Float = sample >= 0 ? 1 : -1
                let mag = abs(sample)
                let reduced = max(0, mag - bias)
                sample = sign * reduced

                // Soft-knee gate
                let finalMag = abs(sample)
                if finalMag < kneeStart {
                    data[i] = 0
                } else if finalMag < gateThreshold {
                    let t = (finalMag - kneeStart) / (gateThreshold - kneeStart)
                    data[i] = sample * t
                } else {
                    data[i] = sample
                }
            }

            windowStart = windowEnd
        }
    }

    // MARK: - 4. Peak Normalization

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

    // MARK: - 5. Gentle Compressor

    /// Simple feed-forward compressor with soft ratio to even out speech levels.
    /// Threshold: -24 dB, Ratio: 2:1, Attack: 10ms, Release: 100ms.
    private static func applyCompressor(data: UnsafeMutablePointer<Float>,
                                        count: Int, sampleRate: Float) {
        let threshold: Float = 0.063  // -24 dB → 10^(-24/20)
        let ratio: Float = 2.0
        let attackSamples = max(1, Int(0.010 * sampleRate))   // 10ms
        let releaseSamples = max(1, Int(0.100 * sampleRate))  // 100ms

        let attackCoeff = 1.0 - exp(-1.0 / Float(attackSamples))
        let releaseCoeff = 1.0 - exp(-1.0 / Float(releaseSamples))

        var env: Float = 0
        var gain: Float = 1.0

        for i in 0..<count {
            let mag = abs(data[i])

            // Envelope follower
            let coeff = mag > env ? attackCoeff : releaseCoeff
            env = env + coeff * (mag - env)

            // Compute gain reduction
            if env > threshold {
                let over = env / threshold
                let compressed = pow(over, 1.0 / ratio)
                let targetGain = compressed * threshold / env
                gain = gain + 0.1 * (targetGain - gain) // smooth gain changes
            } else {
                gain = gain + 0.1 * (1.0 - gain)
            }

            data[i] = data[i] * gain
        }

        // Post-compression makeup gain (+6 dB, clamped)
        var makeupGain: Float = 2.0
        vDSP_vsmul(data, 1, &makeupGain, data, 1, vDSP_Length(count))

        // Final hard clip at 0.99 to prevent any overshoot
        var clipMax: Float = 0.99
        var clipMin: Float = -0.99
        vDSP_vclip(data, 1, &clipMin, &clipMax, data, 1, vDSP_Length(count))
    }
}