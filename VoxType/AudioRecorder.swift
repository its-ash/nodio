import AVFoundation
import Foundation

/// Captures microphone input via `AVAudioEngine` from the chosen device and
/// reports real-time power levels for the HUD waveform.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var powerTimer: Timer?
    private var powerHandler: ((Float) -> Void)?

    // RMS is computed on the audio thread, where the buffer is valid, and
    // only a Float crosses to the main-thread timer.
    private let levelLock = NSLock()
    private var latestLevel: Float = 0

    private(set) var isRecording = false

    // MARK: - Public

    /// `deviceUID` empty means the system default input. Returns false if capture failed.
    @discardableResult
    func start(
        deviceUID: String,
        powerHandler: @escaping (Float) -> Void,
        bufferHandler: ((AVAudioPCMBuffer) -> Void)? = nil
    ) -> Bool {
        guard !isRecording else { return true }
        self.powerHandler = powerHandler

        // A fresh engine per session so a changed input device always applies.
        let e = AVAudioEngine()
        if let dev = AudioDevices.device(uid: deviceUID), !AudioDevices.select(dev, on: e) {
            NSLog("AudioRecorder: could not select \(dev.name), using default input")
        }
        let fmt = e.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            NSLog("AudioRecorder: input has no channels")
            return false
        }

        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            let level = AudioDevices.level(buffer)
            if let self {
                self.levelLock.lock()
                self.latestLevel = level
                self.levelLock.unlock()
            }
            bufferHandler?(buffer)
        }

        do {
            try e.start()
            engine = e
            isRecording = true
            startPowerMetering()
            return true
        } catch {
            NSLog("AudioRecorder: engine start failed — \(error)")
            e.stop()
            e.inputNode.removeTap(onBus: 0)
            return false
        }
    }

    func stop(completion: @escaping () -> Void) {
        guard isRecording else { completion(); return }
        isRecording = false
        stopPowerMetering()

        // Stop the engine first, then remove the tap. Removing the tap while
        // the engine is still running let the CoreAudio IO thread call into a
        // tap that was already torn down: SIGSEGV at address 0 in
        // HALC_ProxyIOContext::IOWorkLoop while the main thread was in
        // -[AVAudioEngine stop] (crash report Nodio-2026-11-10-120445.ips).
        // stop() is synchronous, so after it returns no more tap calls happen.
        if let e = engine {
            engine = nil
            e.stop()
            e.inputNode.removeTap(onBus: 0)
            e.reset()
        }
        powerHandler = nil
        levelLock.lock()
        latestLevel = 0
        levelLock.unlock()

        completion()
    }

    // MARK: - Power Metering

    private func startPowerMetering() {
        powerTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.levelLock.lock()
            let level = self.latestLevel
            self.levelLock.unlock()
            self.powerHandler?(level)
        }
    }

    private func stopPowerMetering() {
        powerTimer?.invalidate()
        powerTimer = nil
    }
}
