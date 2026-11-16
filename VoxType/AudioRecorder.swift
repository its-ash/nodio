import AVFoundation
import Foundation

/// Captures microphone input via `AVAudioEngine` from the chosen device and
/// reports real-time power levels for the HUD waveform.
///
/// The engine can be primed on hotkey down, before a session exists. Audio
/// captured while primed is held and handed to the session when `start`
/// attaches, so the first word isn't lost to the hold threshold and to
/// engine start-up.
final class AudioRecorder {
    /// Covers the hotkey hold threshold (0.5 s) plus permission/start-up delay.
    private static let maxPrerollSeconds = 2.0
    /// A prime that no session claims (a tap, a chord, a failed start) is dropped after this.
    private static let primeTimeout: TimeInterval = 3

    private var engine: AVAudioEngine?
    private var powerTimer: Timer?
    private var powerHandler: ((Float) -> Void)?
    private var primeExpiry: DispatchWorkItem?

    // Guarded by `lock` (audio thread + main). RMS is computed on the audio
    // thread, where the buffer is valid, and only a Float crosses to the
    // main-thread timer.
    private let lock = NSLock()
    private var latestLevel: Float = 0
    private var attached = false
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollSeconds = 0.0

    private(set) var isRecording = false

    // MARK: - Public

    /// Opens the microphone ahead of a session. No-op if the engine already runs.
    func prime(deviceUID: String) {
        guard engine == nil, startEngine(deviceUID: deviceUID) else { return }
        let expiry = DispatchWorkItem { [weak self] in self?.cancelPrime() }
        primeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.primeTimeout, execute: expiry)
    }

    /// Closes a primed microphone that no session claimed. No-op while recording.
    func cancelPrime() {
        guard !isRecording else { return }
        teardown()
    }

    /// `deviceUID` empty means the system default input. Returns false if capture failed.
    /// If the engine was primed, the held audio goes to `bufferHandler` first.
    @discardableResult
    func start(
        deviceUID: String,
        powerHandler: @escaping (Float) -> Void,
        bufferHandler: ((AVAudioPCMBuffer) -> Void)? = nil
    ) -> Bool {
        guard !isRecording else { return true }
        primeExpiry?.cancel()
        primeExpiry = nil
        if engine == nil, !startEngine(deviceUID: deviceUID) { return false }

        // Under the lock so the tap can't deliver a newer buffer before the backlog.
        lock.lock()
        let backlog = preroll
        preroll.removeAll()
        prerollSeconds = 0
        self.bufferHandler = bufferHandler
        attached = true
        if let bufferHandler { backlog.forEach(bufferHandler) }
        lock.unlock()

        self.powerHandler = powerHandler
        isRecording = true
        startPowerMetering()
        return true
    }

    /// Also closes a primed engine whose session never attached.
    func stop(completion: @escaping () -> Void) {
        if isRecording {
            isRecording = false
            stopPowerMetering()
        }
        teardown()
        completion()
    }

    // MARK: - Engine

    private func startEngine(deviceUID: String) -> Bool {
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

        lock.lock()
        attached = false
        bufferHandler = nil
        preroll.removeAll()
        prerollSeconds = 0
        lock.unlock()

        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        do {
            try e.start()
            engine = e
            return true
        } catch {
            NSLog("AudioRecorder: engine start failed — \(error)")
            e.stop()
            e.inputNode.removeTap(onBus: 0)
            return false
        }
    }

    private func teardown() {
        primeExpiry?.cancel()
        primeExpiry = nil

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
        lock.lock()
        latestLevel = 0
        attached = false
        bufferHandler = nil
        preroll.removeAll()
        prerollSeconds = 0
        lock.unlock()
    }

    /// Audio thread.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        let level = AudioDevices.level(buffer)
        lock.lock()
        defer { lock.unlock() }
        latestLevel = level
        if attached {
            bufferHandler?(buffer)
            return
        }
        // Primed: the tap may reuse its buffer, so keep a copy.
        guard let copy = Self.copy(buffer) else { return }
        preroll.append(copy)
        prerollSeconds += Double(copy.frameLength) / copy.format.sampleRate
        while prerollSeconds > Self.maxPrerollSeconds, !preroll.isEmpty {
            let first = preroll.removeFirst()
            prerollSeconds -= Double(first.frameLength) / first.format.sampleRate
        }
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard b.frameLength > 0,
              let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        // Set the length first: it sizes each destination buffer's mDataByteSize.
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return c
    }

    // MARK: - Power Metering

    private func startPowerMetering() {
        powerTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let level = self.latestLevel
            self.lock.unlock()
            self.powerHandler?(level)
        }
    }

    private func stopPowerMetering() {
        powerTimer?.invalidate()
        powerTimer = nil
    }
}
