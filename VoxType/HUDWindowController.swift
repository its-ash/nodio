import AppKit
import SwiftUI

/// Manages the floating, borderless, non-activating `NSPanel` that displays the HUD.
final class HUDWindowController {
    private var panel: NSPanel?

    private var hostingView: NSHostingView<FloatingHUDView>?
    private var current: HUDState = .recording {
        didSet { updateView() }
    }
    private var audioLevel: Float = 0 {
        didSet { updateView() }
    }
    private var hideTimer: Timer?

    // MARK: - Public

    func show() {
        current = .recording
        audioLevel = 0

        if let panel = panel {
            panel.orderFrontRegardless()
            return
        }

        let view = FloatingHUDView(state: current, audioLevel: audioLevel)
        let hosting = NSHostingView(rootView: view)
        hostingView = hosting

        let panel = VoxHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 36),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide(after delay: TimeInterval = 0) {
        hideTimer?.invalidate()
        if delay <= 0 { panel?.orderOut(nil); return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.panel?.orderOut(nil)
        }
    }

    func updateAudioLevel(_ level: Float) {
        audioLevel = level
    }

    func updateState(_ state: HUDState) {
        current = state
        // Reposition after state change since frame width differs per state
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.position(panel)
        }
    }

    // MARK: - Private

    private func updateView() {
        hostingView?.rootView = FloatingHUDView(state: current, audioLevel: audioLevel)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // Use the SwiftUI view's intrinsic size for positioning
        let width: CGFloat
        switch current {
        case .recording: width = 120
        case .transcribing, .done, .failed: width = 150
        }
        let x = frame.midX - width / 2
        let y = frame.maxY - 120
        panel.setFrame(NSRect(x: x, y: y, width: width, height: panel.frame.height), display: true)
    }
}

// MARK: - VoxHUDPanel

private final class VoxHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}