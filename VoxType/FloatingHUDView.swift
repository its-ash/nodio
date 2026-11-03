import SwiftUI

// MARK: - HUD State

enum HUDState: Equatable {
    case recording
    case transcribing
    case done
    case failed
}

// MARK: - FloatingHUDView

struct FloatingHUDView: View {
    let state: HUDState
    let audioLevel: Float
    var preview: String = ""
    var message: String?

    private static let charWidth: CGFloat = 6
    private static let lineHeight: CGFloat = 14
    private static let maxLines = 4
    private static let minPreviewWidth: CGFloat = 360
    private static let maxPreviewWidth: CGFloat = 600
    /// Waveform, spacing, and side padding next to the preview text.
    private static let chrome: CGFloat = 50 + 10 + 28

    /// Grows wider as the user speaks, then taller, up to `maxLines`.
    static func size(state: HUDState, preview: String, message: String?) -> CGSize {
        switch state {
        case .recording where !preview.isEmpty:
            let textWidth = CGFloat(preview.count) * charWidth
            let w = min(maxPreviewWidth, max(minPreviewWidth, textWidth + chrome))
            let lines = min(maxLines, max(1, Int((textWidth / (w - chrome)).rounded(.up))))
            return CGSize(width: w, height: max(36, CGFloat(lines) * lineHeight + 16))
        case .recording: return CGSize(width: 120, height: 36)
        case .transcribing, .done: return CGSize(width: 150, height: 36)
        case .failed: return CGSize(width: message == nil ? 150 : 260, height: 36)
        }
    }

    /// Tail of the preview that fits the box, so the newest words stay visible.
    private var visiblePreview: String {
        let w = Self.size(state: state, preview: preview, message: message).width - Self.chrome
        let cap = max(1, Int(w / Self.charWidth) * Self.maxLines - 1)
        return preview.count > cap ? "…" + preview.suffix(cap - 1) : preview
    }

    @State private var animateGradient = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.5
                        )
                )

            HStack(spacing: 10) {
                iconView
                content
            }
            .padding(.horizontal, 14)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                animateGradient.toggle()
            }
        }
    }

    private var frameSize: CGSize {
        Self.size(state: state, preview: preview, message: message)
    }

    // MARK: - Subviews

    @ViewBuilder private var iconView: some View {
        switch state {
        case .recording:
            HStack(spacing: 2) {
                ForEach(0..<(preview.isEmpty ? 14 : 8), id: \.self) { i in
                    WaveBar(index: i, level: audioLevel)
                }
            }
            .frame(width: preview.isEmpty ? 90 : 50, height: 24)
            .animation(.easeOut(duration: 0.08), value: audioLevel)
        case .transcribing:
            ProgressView()
                .tint(.white)
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .recording:
            if !preview.isEmpty {
                Text(visiblePreview)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(Self.maxLines)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .transcribing:
            Text("Working…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        case .done:
            Text("Done")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        case .failed:
            Text(message ?? "Didn't catch that")
                .lineLimit(1)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Helpers

    private var gradientColors: [Color] {
        switch state {
        case .recording: return [.purple, .pink, .orange]
        case .transcribing: return [.blue, .cyan]
        case .done: return [.green, .teal]
        case .failed: return [.orange, .red]
        }
    }
}

// MARK: - WaveBar

private struct WaveBar: View {
    let index: Int
    let level: Float

    @State private var idleOffset: CGFloat = 0

    var body: some View {
        let base: CGFloat = 3
        let maxExtra: CGFloat = 20
        // Vary height per bar for organic look
        let variation = 0.3 + 0.7 * abs(sin(Double(index) * 0.8))
        let height = base + maxExtra * CGFloat(level) * variation
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(.white)
            .frame(width: 2, height: max(base, height))
            .animation(.easeOut(duration: 0.08), value: level)
    }
}