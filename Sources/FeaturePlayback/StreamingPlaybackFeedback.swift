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

#if os(iOS)
struct MobilePlaybackFailureView: View {
    let message: LocalizedStringResource
    let code: String? // l10n:content — allowlisted diagnostic domain and numeric code
    let retryMessage: LocalizedStringResource?
    let negotiatedCodec: DirectPlayVideoCodec?
    let onChangeQuality: (() -> Void)?
    let onChangeVersion: (() -> Void)?
    let onPlaySDRVersion: (() -> Void)?
    let onPlayOriginal: (() -> Void)?
    let onRetry: (() -> Void)?
    let onShowDiagnostics: () -> Void
    let onDismiss: () -> Void
    @State private var confirmsOriginal = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.yellow)
                    Text("Can’t play this right now").font(.title2.bold())
                    Text(message).font(.body).foregroundStyle(.white.opacity(0.8))
                    if let retryMessage {
                        Text(retryMessage)
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                    if let negotiatedCodec {
                        Text("Negotiated codec: \(PlaybackDiagnostics.friendlyCodecName(negotiatedCodec.rawValue) ?? negotiatedCodec.rawValue)")
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                    if let code {
                        Text(verbatim: code).font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if let onPlaySDRVersion {
                        Button("Play an SDR version", systemImage: "rectangle.stack", action: onPlaySDRVersion)
                            .buttonStyle(.borderedProminent)
                    } else if onPlayOriginal != nil {
                        Text("No SDR version found on this server.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if onPlayOriginal != nil {
                        Button("Play original quality") { confirmsOriginal = true }
                            .buttonStyle(.bordered)
                    }
                    if let onChangeVersion {
                        Menu {
                            Button("Version", systemImage: "rectangle.stack", action: onChangeVersion)
                            if let onChangeQuality {
                                Button("Quality", systemImage: "slider.horizontal.3", action: onChangeQuality)
                            }
                        } label: {
                            Label("Playback options", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderedProminent)
                    } else if let onChangeQuality {
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
        .confirmationDialog("Play original quality?", isPresented: $confirmsOriginal, titleVisibility: .visible) {
            if let onPlayOriginal {
                Button("Play original quality", action: onPlayOriginal)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This keeps your selected version but removes the streaming quality limit. It may use substantially more data, especially on cellular.")
        }
    }
}
#endif
#endif
