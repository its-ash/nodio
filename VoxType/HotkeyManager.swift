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

    /// Guards against a spurious momentary release mid-hold: the fn/Globe
    /// key's flagsChanged flag has been observed to blip off and back on
    /// for a single event during a genuine physical hold (it's shared with
    /// system features like the emoji picker/dictation/input-switching, so
    /// its debounce at the OS level isn't as clean as a normal modifier
    /// key's). Real releases are held back briefly; if fn goes back down
    /// before the delay elapses, the pending onRelease is cancelled and the
    /// recording continues as one uninterrupted session instead of being
    /// cut into fragments.
    private static let releaseDebounce: TimeInterval = 0.45
    private var pendingRelease: DispatchWorkItem?

    /// The fn key must be held for at least this long before recording
    /// starts. A quick tap (below the threshold) is ignored entirely —
    /// only a deliberate press-and-hold triggers `onPress`.
    private static let holdThreshold: TimeInterval = 0.5
    private var pendingPress: DispatchWorkItem?
    /// True once the hold threshold has elapsed and `onPress` has fired,
    /// so `onRelease` only fires for sessions that actually started.
    private var pressFired = false

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
            pressFired = false
            if pendingRelease != nil {
                // A release was about to fire but fn came back down first —
                // this was the spurious mid-hold blip, not a real release.
                HotkeyManager.debugLog("fn re-pressed within debounce window, cancelling pending release")
                pendingRelease?.cancel()
                pendingRelease = nil
            } else {
                HotkeyManager.debugLog("fn pressed, waiting for \(Self.holdThreshold)s hold threshold")
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard self.fnDown else { return }
                    self.pressFired = true
                    HotkeyManager.debugLog("fn held past threshold -> onPress")
                    self.onPress()
                }
                pendingPress = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.holdThreshold, execute: work
                )
            }
        } else if !fnPressed && fnDown {
            pendingPress?.cancel()
            pendingPress = nil
            // Cancel any release already pending from an earlier blip in
            // this same hold before scheduling a new one — otherwise a
            // second/third blip stacks up an *additional* uncancelled timer
            // instead of replacing the first, and whichever one was
            // scheduled earliest still fires on schedule regardless of
            // later re-presses, which is what let stray releases through
            // even though the debounce logic looked like it was cancelling
            // them correctly.
            pendingRelease?.cancel()
            if pressFired {
                HotkeyManager.debugLog("fn flag cleared, debouncing before onRelease")
                confirmReleaseAfterDebounce(confirmationsLeft: 2)
            } else {
                HotkeyManager.debugLog("fn released before hold threshold, ignoring tap")
                fnDown = false
                pendingRelease = nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Confirms a release across two spaced checkpoints instead of trusting
    /// a single flagsChanged event or a single delayed recheck. The fn/Globe
    /// key has been observed to read momentarily clear — long enough to
    /// beat a simple one-shot debounce — right as speech pauses, without a
    /// distinct matching press event ever following it; polling the live
    /// keyboard state (CGEventSource.flagsState, not just replaying the
    /// event that triggered this) at two points spread across the debounce
    /// window means a single transient dip doesn't survive to trigger
    /// onRelease unless the key is *still* reading up on the second check
    /// too. Recurses with a fresh DispatchWorkItem each step so a genuine
    /// re-press in between (handled by the `fnPressed && !fnDown` branch
    /// above, which cancels `pendingRelease`) still aborts the whole thing.
    private func confirmReleaseAfterDebounce(confirmationsLeft: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stillUp = !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
            guard stillUp else {
                HotkeyManager.debugLog("fn reads down on recheck, aborting release")
                self.pendingRelease = nil
                return
            }
            if confirmationsLeft > 1 {
                self.confirmReleaseAfterDebounce(confirmationsLeft: confirmationsLeft - 1)
            } else {
                self.pendingRelease = nil
                self.fnDown = false
                self.pressFired = false
                HotkeyManager.debugLog("fn released -> onRelease")
                self.onRelease()
            }
        }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.releaseDebounce / 2, execute: work
        )
    }
}