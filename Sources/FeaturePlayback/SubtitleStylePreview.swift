#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import CoreUI
import Observation
import SwiftUI

@MainActor
@Observable
final class SubtitlePreviewOptions {
    var showsFileFormatting = false
    var showsHDRBrightness = false
    var animatesBackground = true
    private(set) var backgroundPhase = 0
    @ObservationIgnored private var lastPaletteChange = ContinuousClock.now

    func styleDidChange(from previous: SubtitleStyle, to current: SubtitleStyle) {
        if previous.hdrLuminanceScale != current.hdrLuminanceScale {
            showsHDRBrightness = true
        }
    }

    func advanceBackground(at instant: ContinuousClock.Instant = .now) {
        guard instant - lastPaletteChange >= .seconds(8) else { return }
        backgroundPhase = (backgroundPhase + 1) % SubtitlePreviewPalettes.cycle.count
        lastPaletteChange = instant
    }
}

enum SubtitleStylePreviewMetrics {
    static let televisionCanvas = CGSize(width: 1920, height: 1080)

    static func scale(previewWidth: CGFloat, referenceWidth: CGFloat) -> CGFloat {
        guard previewWidth > 0, referenceWidth > 0 else { return 0 }
        return previewWidth / referenceWidth
    }
}

struct SubtitleStylePreview: View {
    let style: SubtitleStyle
    let secondaryVisible: Bool
    let referenceSize: CGSize
    @Bindable var options: SubtitlePreviewOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                #if os(iOS)
                Menu("Preview options", systemImage: "slider.horizontal.3") {
                    Toggle("Preview file formatting", isOn: $options.showsFileFormatting)
                    Toggle("Apply HDR subtitle dimming", isOn: $options.showsHDRBrightness)
                }
                .labelStyle(.iconOnly)
                Button {
                    options.animatesBackground.toggle()
                } label: {
                    Label(options.animatesBackground ? "Pause background" : "Animate background",
                          systemImage: options.animatesBackground ? "pause.fill" : "play.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                #endif
            }
            SubtitleStylePreviewCanvas(
                style: style, secondaryVisible: secondaryVisible,
                referenceSize: referenceSize, showsFileFormatting: options.showsFileFormatting,
                showsHDRBrightness: options.showsHDRBrightness, animate: options.animatesBackground,
                backgroundOptions: options
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Subtitle preview")
            SubtitlePreviewCaption(style: style, previewsHDR: options.showsHDRBrightness)
        }
    }
}

private struct SubtitlePreviewCaption: View {
    let style: SubtitleStyle
    let previewsHDR: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if previewsHDR {
                Text("HDR subtitle dimming preview: \(style.hdrLuminanceScale, format: .percent.precision(.fractionLength(0)))")
                if style.hdrLuminanceScale == 1 {
                    Text("100% keeps normal brightness. Lower HDR Brightness to preview dimmer subtitles.")
                } else {
                    Text("This previews subtitle dimming, not HDR video.")
                }
            } else {
                Text("Size and position match the proportions of full-screen playback.")
            }
        }
        .font(.caption)
        .plozzForeground(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SubtitleStylePreviewCanvas: View {
    let style: SubtitleStyle
    let secondaryVisible: Bool
    let referenceSize: CGSize
    var showsFileFormatting = false
    var showsHDRBrightness = false
    var animate = true
    var backgroundOptions: SubtitlePreviewOptions? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SubtitlePreviewBackground(animate: animate, options: backgroundOptions)
                SubtitleOverlayView(
                    primary: primary,
                    secondary: [.init(id: 2, start: 0, end: 60, body: .text(.init(
                        String(localized: "This is how a second subtitle appears.",
                               comment: "Sample subtitle shown in the style editor preview, not dialogue from a film.")
                    )))],
                    secondaryActive: secondaryVisible,
                    style: SystemCaptionStyle.shared.resolved(style),
                    isHDR: showsHDRBrightness
                )
            }
            .frame(width: referenceSize.width, height: referenceSize.height)
            .scaleEffect(SubtitleStylePreviewMetrics.scale(
                previewWidth: geometry.size.width, referenceWidth: referenceSize.width
            ), anchor: .topLeading)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private var primary: [SubtitleCue] {
        var cues = [SubtitleCue(id: 0, start: 0, end: 60, body: .text(.init(
            String(localized: "Keep going. We're almost there.\nThe train leaves at 9:45.",
                   comment: "Two-line sample subtitle in the style editor preview, not dialogue from a film.")
        )))]
        if showsFileFormatting {
            cues.append(.init(id: 1, start: 0, end: 60, body: .text(.init(
                runs: [.init(String(localized: "A sign placed by the subtitle file"), color: .yellow)],
                layout: SubtitleCueLayout(alignment: .topCenter)
            ))))
        }
        return cues
    }
}

enum SubtitlePreviewPalettes {
    static let dark: [Color] = [
        Color(red: 0.06, green: 0.09, blue: 0.15),
        Color(red: 0.12, green: 0.16, blue: 0.24)
    ]
    static let light: [Color] = [
        Color(red: 0.97, green: 0.96, blue: 0.93),
        Color(red: 0.88, green: 0.94, blue: 0.98)
    ]
    static let colorful: [Color] = [
        Color(red: 0.24, green: 0.36, blue: 0.66),
        Color(red: 0.50, green: 0.78, blue: 0.92)
    ]
    static let comparison: [Color] = [colorful[0], light[0], dark[0]]
    static let cycle = [colorful, light, dark]
}

private struct SubtitlePreviewBackground: View {
    let animate: Bool
    let options: SubtitlePreviewOptions?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var phase = 0

    private var isAnimating: Bool { animate && !reduceMotion && isVisible && scenePhase == .active }

    var body: some View {
        LiquidArtworkBackground(
            palette: reduceMotion ? SubtitlePreviewPalettes.comparison
                : SubtitlePreviewPalettes.cycle[options?.backgroundPhase ?? phase],
            animate: isAnimating,
            style: .dark,
            paletteCrossfade: reduceMotion ? 0 : 3,
            showsBackdrop: false
        )
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: isAnimating) {
            guard isAnimating else { return }
            do {
                while true {
                    try await Task.sleep(for: .seconds(8))
                    if let options { options.advanceBackground() }
                    else { phase = (phase + 1) % SubtitlePreviewPalettes.cycle.count }
                }
            } catch is CancellationError {
                // The page left the screen or motion was disabled.
            } catch {
                PlozzLog.app.error("Subtitle preview background animation failed.")
            }
        }
    }
}
#endif
