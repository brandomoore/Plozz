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

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text(phase.message(provider: provider, transcoding: transcoding, usingH264Fallback: h264Fallback))
                .font(.headline)
            Text(options.quality.title).font(.subheadline)
            if transcoding {
                Text("Converted as you watch. Playback starts when enough video is buffered; the whole movie doesn’t need to finish converting.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
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

#if os(iOS)
struct MobilePlaybackFailureView: View {
    let message: LocalizedStringResource
    let code: String? // l10n:content — allowlisted diagnostic domain and numeric code
    let usedH264Fallback: Bool
    let onChangeQuality: (() -> Void)?
    let onRetry: (() -> Void)?
    let onShowDiagnostics: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.yellow)
                    Text("Can’t play this right now").font(.title2.bold())
                    Text(message).font(.body).foregroundStyle(.white.opacity(0.8))
                    if usedH264Fallback {
                        Text("The H.264 fallback was also tried at the same quality limit.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                    if let code {
                        Text(verbatim: code).font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if let onChangeQuality {
                        Button("Change quality", systemImage: "slider.horizontal.3", action: onChangeQuality)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("player-failed-streaming-quality")
                    }
                    if let onRetry { Button("Try again", action: onRetry).buttonStyle(.bordered) }
                    Button("Playback Diagnostics", action: onShowDiagnostics).buttonStyle(.bordered)
                    Button("Back", action: onDismiss).buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
    }
}
#endif
#endif
