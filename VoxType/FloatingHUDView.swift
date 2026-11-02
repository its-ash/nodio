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

    static func width(state: HUDState, preview: String, message: String?) -> CGFloat {
        switch state {
        case .recording: preview.isEmpty ? 120 : 360
        case .transcribing, .done: 150
        case .failed: message == nil ? 150 : 260
        }
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
        .frame(width: frameWidth, height: 36)
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                animateGradient.toggle()
            }
        }
    }

    private var frameWidth: CGFloat {
        Self.width(state: state, preview: preview, message: message)
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
                Text(preview)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.head)
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