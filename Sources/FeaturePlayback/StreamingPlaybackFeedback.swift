#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct StreamingPlaybackLoadingView: View {
    let options: StreamingPlaybackOptions
    let provider: String // l10n:content — provider brand
    let phase: StreamingPreparationPhase
    let transcoding: Bool
    let h264Fallback: Bool
    let hevcFallback: Bool

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(phase.message(
                provider: provider, transcoding: transcoding,
                usingH264Fallback: h264Fallback, usingHEVCFallback: hevcFallback
            ))
                .font(.headline)
            Text(options.quality.title).font(.subheadline)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 460)
        .padding(20)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("streaming-preparation")
        .allowsHitTesting(false)
    }
}

struct StreamingPlaybackFailureView: View {
    let message: LocalizedStringResource
    let report: PlaybackDiagnosticReport?
    var showsForcedTranscodingHint = false
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        PlaybackFailureView(
            message: message, report: report,
            recoveryHint: showsForcedTranscodingHint
                ? "Force transcoding is on. Try turning it off in Streaming quality."
                : nil
        ) {
            if let onRetry {
                Button("Retry", action: onRetry)
                    .plozzActionButton(role: .primary)
                    .accessibilityIdentifier("playback-failure-retry")
            }
            Button("Back", action: onDismiss)
                .plozzActionButton(role: .secondary)
                .accessibilityIdentifier("player-failed-back")
        }
    }
}
#endif
