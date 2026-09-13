import AppKit
import ApplicationServices

/// Delivers transcribed text to the focused text field via the Accessibility API.
/// Falls back to the clipboard when no suitable text input element is found.
final class TextInjector {
    /// Delivers transcribed text to the focused text field via the Accessibility API.
    /// Falls back to paste synthesis (Cmd+V) for non-native text fields (VS Code, browsers).
    /// Falls back to clipboard when no text input is focused.
    /// `completion(true)` = copied to clipboard; `completion(false)` = injected/pasted.
    func deliver(_ text: String, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { completion(false); return }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let profile = bundleID.flatMap { InjectionProfileStore.shared.method(for: $0) }

        // Per-app profile: if we already know AX doesn't work for this app
        // (e.g. VS Code), skip straight to paste instead of re-attempting AX
        // every single time and eating the latency + log noise of a call we
        // know will fail. This is purely a speed optimization — it does NOT
        // suppress the clipboard-confirmation signal, since paste success
        // can never actually be verified from outside the target app (see
        // attemptPaste).
        if profile == .paste {
            debugLog("known profile for \(bundleID ?? "?") = paste, skipping AX")
            attemptPaste(text, bundleID: bundleID, completion: completion)
            return
        }

        // 1. Try AX injection on the focused element (native macOS text fields).
        if let focusedElement = focusedTextElement() {
            debugLog("focused text element found, role=\(roleDescription(focusedElement)), attempting AX injection")
            if inject(text, into: focusedElement) {
                debugLog("AX injection succeeded")
                if let bundleID { InjectionProfileStore.shared.record(.ax, for: bundleID) }
                completion(false)
                return
            }
            debugLog("AX injection failed, falling back to paste")
        } else {
            debugLog("no focused editable text element found")
        }

        // 2. Try paste synthesis (Cmd+V) whenever there's a frontmost app at
        //    all. We can't gate this on an AX focus check: Chromium/Electron
        //    apps (VS Code, Slack, browsers) commonly don't expose their
        //    internal accessibility tree until an assistive-technology
        //    client activates it, so kAXFocusedUIElementAttribute reliably
        //    returns kAXErrorNotImplemented there even for a genuinely
        //    focused, editable field. Requiring AX to confirm focus first
        //    meant we never even tried pasting into VS Code.
        attemptPaste(text, bundleID: bundleID, completion: completion)
    }

    /// CGEvent.post has no way to report whether the target app actually
    /// consumed a synthetic paste — some apps' input security policies
    /// silently drop synthetic key events (observed with WhatsApp, a native
    /// non-Electron app). So this always reports completion(true): the text
    /// is guaranteed on the clipboard, and that's the one thing we can
    /// actually promise. The clipboard-confirmation sound/beep is the user's
    /// signal to manually Cmd+V if the automatic paste didn't land.
    private func attemptPaste(
        _ text: String, bundleID: String?, completion: @escaping (Bool) -> Void
    ) {
        guard NSWorkspace.shared.frontmostApplication != nil else {
            // No frontmost app at all — copy to clipboard.
            debugLog("no frontmost app at all, copying to clipboard only")
            copyToClipboard(text)
            completion(true)
            return
        }

        debugLog("frontmost app present, copying + pasting")
        copyToClipboard(text)
        // Delay so clipboard is ready AND the HUD panel has fully
        // dismissed — the floating panel can steal the paste target
        // if we fire Cmd+V too quickly after recording stops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            let posted = self?.postPasteCommand() ?? false
            self?.debugLog("postPasteCommand returned \(posted)")
            if posted, let bundleID {
                InjectionProfileStore.shared.record(.paste, for: bundleID)
            } else if let bundleID {
                InjectionProfileStore.shared.record(.clipboard, for: bundleID)
            }
            completion(true)
        }
    }

    private func roleDescription(_ element: AXUIElement) -> String {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return (roleRef as? String) ?? "?"
    }

    /// NSLog is unreliable to observe from this unsigned/adhoc-signed debug
    /// build via `log stream`. Write diagnostics straight to a file instead
    /// so injection failures can be root-caused during development.
    private func debugLog(_ message: String) {
        let line = "\(Date()): \(message)\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("voxtype_debug.log")
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: path)
            }
        }
    }

    // MARK: - Focus Detection

    /// Resolves the focused UI element via the frontmost app's PID
    /// (NSWorkspace.frontmostApplication → AXUIElementCreateApplication).
    /// The system-wide element's kAXFocusedApplicationAttribute query
    /// reliably returns kAXErrorNotImplemented (-25212) in this app's
    /// environment even when fully trusted — going through the app's own
    /// AX element directly (the same approach System Events/most AX tools
    /// use) is what actually works.
    private func focusedUIElement() -> AXUIElement? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("focusedUIElement: no frontmost application")
            return nil
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        debugLog("focusedUIElement: app=\(frontApp.bundleIdentifier ?? "?") AXError=\(err.rawValue)")
        guard err == .success, let focused = focusedRef else { return nil }
        return (focused as! AXUIElement)
    }

    // MARK: - AX Inspection

    private func focusedTextElement() -> AXUIElement? {
        guard let element = focusedUIElement() else { return nil }
        guard isEditableText(element) else { return nil }
        return element
    }

    private func isEditableText(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // AXStaticText is a read-only label by definition — it must never be
        // treated as an injection target. Setting kAXSelectedTextAttribute
        // on one can still return .success (a silent no-op) which previously
        // made deliver() falsely believe injection worked and text was lost
        // (observed with WhatsApp, whose message list briefly reports focus
        // on static text elements). Containers (AXGroup, AXWebArea,
        // AXOutline, AXBrowser) are likewise never themselves text-settable
        // — only a genuine descendant text field is, and that field is what
        // reports focus, not its container.
        guard role != "AXStaticText" else { return false }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""

        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        if textRoles.contains(role) || subrole == "AXTextArea" {
            return true
        }

        // If role doesn't match but the element reports AXEditable, accept it
        var editableRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRef)
        if let editable = editableRef as? Bool, editable {
            return true
        }

        // Last resort: the attribute must be reported *settable*, not merely
        // readable — a static label also has a readable AXValue (its
        // displayed text) despite never being editable.
        var selectedSettable: DarwinBoolean = false
        let selectedCheck = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &selectedSettable
        )
        if selectedCheck == .success, selectedSettable.boolValue { return true }

        var valueSettable: DarwinBoolean = false
        let valueCheck = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &valueSettable
        )
        return valueCheck == .success && valueSettable.boolValue
    }

    // MARK: - AX Injection

    private func inject(_ text: String, into element: AXUIElement) -> Bool {
        // isEditableText() now only lets genuinely-settable elements reach
        // here (role whitelist or an explicit AXUIElementIsAttributeSettable
        // check), so a .success set result is more trustworthy than it used
        // to be — but WhatsApp's composer is AXTextArea with no readable
        // kAXValueAttribute at all, so the old before/after AXValue
        // comparison always fell into "can't verify, trust it" and silently
        // accepted no-op writes. Verify against kAXValueAttribute when it's
        // readable; when it isn't, read back kAXSelectedTextAttribute
        // itself (what we just wrote) instead of blindly trusting .success.
        let beforeValue = readValue(element)

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )

        if setResult == .success {
            if let before = beforeValue {
                let after = readValue(element)
                if after == nil || after != before {
                    return true
                }
                // Value unchanged — the set silently no-op'd. Fall through.
            } else if readSelectedText(element)?.contains(text) == true {
                return true
            }
        }

        // Fallback: insert by rewriting AXValue directly at the cursor position,
        // for elements that don't support AXSelectedText writes (e.g. some
        // AXTextArea/AXWebArea implementations).
        return injectByReplacingValue(text, into: element)
    }

    private func readSelectedText(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref)
        guard result == .success else { return nil }
        return ref as? String
    }

    private func readValue(_ element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard result == .success else { return nil }
        return valueRef as? String
    }

    private func injectByReplacingValue(_ text: String, into element: AXUIElement) -> Bool {
        var rangeRef: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success

        var existing = ""
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success {
            existing = valueRef as? String ?? ""
        }

        var insertionIndex = existing.count
        if hasRange, let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                insertionIndex = max(0, min(existing.count, cfRange.location))
            }
        }

        let idx = existing.index(existing.startIndex, offsetBy: insertionIndex)
        let newValue = String(existing[..<idx]) + text + String(existing[idx...])

        let setResult = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, newValue as CFString
        )
        guard setResult == .success else { return false }

        // Move the cursor to just after the inserted text.
        var newCFRange = CFRange(location: insertionIndex + text.count, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newCFRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }

        return true
    }

    // MARK: - Paste Synthesis

    private func postPasteCommand() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source else { return false }

        let keyDownCmd = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let keyDownV = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUpV = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let keyUpCmd = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        guard let keyDownCmd, let keyDownV, let keyUpV, let keyUpCmd else { return false }

        // Set flags correctly: Cmd is held during V press and V release,
        // then released on Cmd up.
        keyDownCmd.flags = CGEventFlags.maskCommand
        keyDownV.flags = CGEventFlags.maskCommand
        keyUpV.flags = CGEventFlags.maskCommand
        keyUpCmd.flags = []

        // Post events with small delays between them — browsers filter
        // synthetic key sequences that arrive in the same event loop tick.
        keyDownCmd.post(tap: .cghidEventTap)

        usleep(15_000) // 15ms

        keyDownV.post(tap: .cghidEventTap)

        usleep(15_000)

        keyUpV.post(tap: .cghidEventTap)

        usleep(15_000)

        keyUpCmd.post(tap: .cghidEventTap)

        return true
    }

    // MARK: - Clipboard

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}