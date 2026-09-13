import AVFoundation
import Foundation

/// Enhances recorded audio for better speech recognition accuracy.
/// Applies a noise gate to suppress background noise and peak normalization
/// to maximize the signal level feeding into SFSpeechRecognizer.
final class AudioEnhancer {

    /// Processes the audio file at `url` and writes an enhanced version to a
    /// new temporary file. Returns the URL of the enhanced file.
    static func enhance(fileAt url: URL) -> URL? {
        guard let inputFile = try? AVAudioFile(forReading: url) else { return nil }
        let inputFormat = inputFile.processingFormat
        let inputFrameCount = inputFile.length

        // AVAudioPCMBuffer(frameCapacity: 0) trips a fatal AVFoundation
        // assertion on read (buffer.frameCapacity != 0), crashing the process
        // rather than throwing — guard against empty/near-empty recordings
        // (e.g. the hotkey was tapped too briefly) before allocating.
        guard inputFrameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputFrameCount)) else {
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

        // Step 1: Local (windowed) noise gate — a single global threshold pulls
        // the floor down during long pauses, which under-amplifies and can gate
        // out quieter speech (soft consonants, breath onsets) right after a gap,
        // dropping/mangling words. Instead, gate per-window using a local floor,
        // and use an envelope-following soft gate (not a hard zero) so we don't
        // introduce clicks at segment boundaries that confuse the recognizer.
        let windowSeconds: Float = 2.0
        let windowSize = max(1, Int(windowSeconds * sampleRate))

        for ch in 0..<channels {
            let data = channelData[ch]
            var windowStart = 0
            while windowStart < frameLength {
                let windowEnd = min(windowStart + windowSize, frameLength)
                var windowSamples: [Float] = []
                windowSamples.reserveCapacity(windowEnd - windowStart)
                for i in windowStart..<windowEnd {
                    windowSamples.append(abs(data[i]))
                }
                let sortedWindow = windowSamples.sorted()
                let floorIdx = max(0, sortedWindow.count / 10 - 1)
                let localFloor = sortedWindow[floorIdx]
                let gateThreshold = max(localFloor * 3.0, 0.001)

                // Soft knee: ramp gain from 0 to 1 over [threshold*0.5, threshold]
                // instead of a hard zero, avoiding discontinuities.
                let kneeStart = gateThreshold * 0.5
                for i in windowStart..<windowEnd {
                    let mag = abs(data[i])
                    if mag < kneeStart {
                        data[i] = 0
                    } else if mag < gateThreshold {
                        let t = (mag - kneeStart) / (gateThreshold - kneeStart)
                        data[i] *= t
                    }
                }
                windowStart = windowEnd
            }
        }

        // Step 2: Find peak amplitude after gating
        var peak: Float = 0
        for ch in 0..<channels {
            let data = channelData[ch]
            for i in 0..<frameLength {
                let v = abs(data[i])
                if v > peak { peak = v }
            }
        }

        // Step 3: Peak normalize to 0.95 (leave small headroom)
        guard peak > 0 else { return url }
        let targetPeak: Float = 0.95
        let gain = targetPeak / peak

        // Clamp gain to avoid over-boosting very quiet (mostly noise) recordings
        let clampedGain = min(gain, 20.0)

        for ch in 0..<channels {
            let data = channelData[ch]
            for i in 0..<frameLength {
                data[i] *= clampedGain
            }
        }

        // Step 5: Write enhanced audio to a new temp file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodio_enhanced_\(UUID().uuidString).caf")

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        )!

        guard let outputFile = try? AVAudioFile(forWriting: outputURL, settings: outputFormat.settings) else {
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
}