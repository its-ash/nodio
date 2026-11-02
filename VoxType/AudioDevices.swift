import AVFoundation
import Combine
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// All devices with at least one input channel.
    static func inputs() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> InputDevice? {
        uid.isEmpty ? nil : inputs().first { $0.uid == uid }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// Points an engine's input node at a device. Call before reading formats or starting.
    @discardableResult
    static func select(_ device: InputDevice?, on engine: AVAudioEngine) -> Bool {
        guard let device, let unit = engine.inputNode.audioUnit else { return device == nil }
        var id = device.id
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    /// RMS level of a buffer mapped from -50…0 dB to 0…1.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[0][i] * ch[0][i] }
        let db = 20 * log10(sqrt(sum / Float(n)) + 1e-8)
        return max(0, min(1, (db + 50) / 50))
    }
}

/// Live input level for the Settings window mic test.
final class MicTester: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private var engine: AVAudioEngine?

    func start(uid: String) {
        stop()
        let e = AVAudioEngine()
        AudioDevices.select(AudioDevices.device(uid: uid), on: e)
        let fmt = e.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { error = "No input available"; return }
        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            let l = AudioDevices.level(buf)
            DispatchQueue.main.async { self?.level = l }
        }
        do {
            try e.start()
            engine = e
            running = true
            error = nil
        } catch {
            e.inputNode.removeTap(onBus: 0)
            self.error = error.localizedDescription
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        level = 0
    }

    deinit { stop() }
}
