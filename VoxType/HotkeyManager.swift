import AppKit
import ApplicationServices
import CoreGraphics

/// Manages a global Quartz Event Tap that listens for the `fn` (Globe) modifier
/// flag changes. Fires `onPress` when the key goes down and `onRelease` when it
/// goes up — press-and-hold to talk behaviour.
final class HotkeyManager {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    deinit { stop() }

    // MARK: - Public

    func checkAccessibilityAndStart() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        HotkeyManager.debugLog("checkAccessibilityAndStart: trusted=\(trusted)")
        if trusted {
            start()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.checkAccessibilityAndStart()
            }
        }
    }

    static func debugLog(_ message: String) {
        let line = "\(Date()): [Hotkey] \(message)\n"
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

    // MARK: - Private

    private func start() {
        guard eventTap == nil else { return }

        let mask: CGEventTapLocation = .cgSessionEventTap
        let eventsOfInterest: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: mask,
            place: CGEventTapPlacement.headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            HotkeyManager.debugLog("tapCreate FAILED, retrying in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.start()
            }
            return
        }

        HotkeyManager.debugLog("tapCreate succeeded, tap installed")
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    // MARK: - C Callback

    private let callback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        return manager.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let flags = event.flags

        // kCGEventFlagSymbolic fn key — set when the fn/Globe key is held down.
        let fnPressed = flags.contains(.maskSecondaryFn)
        if fnPressed && !fnDown {
            fnDown = true
            HotkeyManager.debugLog("fn pressed -> onPress")
            onPress()
        } else if !fnPressed && fnDown {
            fnDown = false
            HotkeyManager.debugLog("fn released -> onRelease")
            onRelease()
        }

        return Unmanaged.passUnretained(event)
    }
}