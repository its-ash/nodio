import AppKit
import ApplicationServices

/// Delivers transcribed text to the focused text field via the Accessibility API.
/// Falls back to the clipboard when no suitable text input element is found.
final class TextInjector {
    // MARK: - Live Streaming

    /// Words already committed to screen for the running live session,
    /// tracked by count rather than by exact text. On-device speech
    /// recognition's partial results are the *whole* transcript-so-far,
    /// re-guessed each time, and it commonly revises earlier words as more
    /// audio arrives — e.g. guessing "for" then correcting to "four" once
    /// it hears more context. Deleting and retyping on every such revision
    /// (matching by exact text) is jarring and was flagged as unwanted:
    /// once a word is on screen it should never be removed, even if the
    /// recognizer later changes its mind about it. So reconciliation is
    /// purely by *word count* — only the words beyond what's already
    /// committed are ever injected, and a revision to an already-committed
    /// word is simply ignored, not corrected. Only ever touched on
    /// `injectionQueue` so reads/writes can't race with the main-thread
    /// call that enqueues each update.
    private var committedWordCount = 0

    /// Text recognized while the target app needs paste-fallback delivery,
    /// held back instead of pasted immediately. Posting a synthetic Cmd+V
    /// key sequence on every single word during live streaming was found
    /// to corrupt the OS's own tracked modifier-key state — it was making
    /// the fn/Globe hotkey read as released mid-hold purely because of how
    /// often paste fired, confirmed by the false releases disappearing
    /// entirely once injection was disabled for a diagnostic run. AX
    /// injection doesn't post key events at all, so it stays fully live;
    /// only the paste-only path defers to a single paste at session end.
    private var pendingPasteText = ""

    /// All actual key-event posting (paste) and AX calls happen here, off
    /// the main thread, so a burst of updates never blocks the HUD/UI.
    /// Serial (not concurrent) so updates apply in the order they arrived.
    private let injectionQueue = DispatchQueue(label: "com.nodio.app.textInjector")

    func beginLiveStream() {
        injectionQueue.async {
            self.committedWordCount = 0
            self.pendingPasteText = ""
        }
    }

    /// Flushes any text that was held back for paste-only delivery, then
    /// resets session state. Safe to call even if nothing was buffered.
    func endLiveStream() {
        injectionQueue.async {
            if !self.pendingPasteText.isEmpty {
                self.debugLog("live stream ending: flushing buffered paste text")
                self.pasteNow(self.pendingPasteText)
            }
            self.committedWordCount = 0
            self.pendingPasteText = ""
        }
    }

    /// Reconciles what's on screen with `fullText` (the latest full
    /// transcript-so-far from the recognizer): if it now has more words
    /// than are already committed, injects only the excess new words —
    /// appending only, never deleting or retyping anything already on
    /// screen, even if the recognizer revised an earlier word. Called
    /// repeatedly as more partial results arrive during recording; safe to
    /// call from the main thread — the actual work is dispatched off it.
    func updateLiveStream(fullText: String) {
        injectionQueue.async {
            let words = fullText.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count > self.committedWordCount else { return }

            let newWords = words[self.committedWordCount...]
            let suffix = (self.committedWordCount > 0 ? " " : "") + newWords.joined(separator: " ")
            self.insertAtCursor(suffix)
            self.committedWordCount = words.count
        }
    }

    /// Inserts text at the current cursor position without touching
    /// anything else already on screen — AX injection when available.
    /// When the target app needs paste-fallback instead, the text is
    /// buffered rather than pasted immediately (see `pendingPasteText`)
    /// and only actually delivered once, when the session ends.
    private func insertAtCursor(_ text: String) {
        guard !text.isEmpty else { return }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let knownPasteOnly = bundleID.flatMap { InjectionProfileStore.shared.method(for: $0) } == .paste

        if !knownPasteOnly, let focusedElement = focusedTextElement(), inject(text, into: focusedElement) {
            debugLog("live stream: AX insert succeeded")
            if let bundleID { InjectionProfileStore.shared.record(.ax, for: bundleID) }
            return
        }

        debugLog("live stream: buffering for paste at session end")
        pendingPasteText += text
    }

    /// Actually performs the paste — copies to clipboard and synthesizes
    /// Cmd+V once. Only ever called once per session, from `endLiveStream`,
    /// specifically to avoid the repeated-synthetic-key-event problem that
    /// motivated buffering in the first place.
    private func pasteNow(_ text: String) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard NSWorkspace.shared.frontmostApplication != nil else {
            debugLog("pasteNow: no frontmost app, copying to clipboard only")
            copyToClipboard(text)
            return
        }
        copyToClipboard(text)
        if postPasteCommand(), let bundleID {
            InjectionProfileStore.shared.record(.paste, for: bundleID)
        }
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