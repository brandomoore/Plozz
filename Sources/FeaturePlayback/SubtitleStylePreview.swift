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
    var showsHDRBrightness = false {
        didSet { reconcileHDRPlayback() }
    }
    var animatesBackground = true {
        didSet { reconcileHDRPlayback() }
    }
    private(set) var fullscreenPresented = false
    @ObservationIgnored let hdrPreview = SubtitleHDRPreview()
    @ObservationIgnored private var inlineVisible = false
    @ObservationIgnored private var fullscreenVisible = false
    @ObservationIgnored private var sceneActive = true
    private(set) var backgroundPhase = 0
    @ObservationIgnored private var lastPaletteChange = ContinuousClock.now

    func styleDidChange(from previous: SubtitleStyle, to current: SubtitleStyle) {
        if previous.hdrLuminanceScale != current.hdrLuminanceScale {
            showsHDRBrightness = true
        }
    }

    func setVisible(_ visible: Bool, fullscreen: Bool, sceneActive: Bool) {
        if fullscreen { fullscreenVisible = visible }
        else { inlineVisible = visible }
        self.sceneActive = sceneActive
        reconcileHDRPlayback()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        reconcileHDRPlayback()
    }

    func beginFullscreenPresentation() {
        fullscreenPresented = true
        reconcileHDRPlayback()
    }

    func finishFullscreenPresentation() {
        // Retain playback across the presentation-completion/remount boundary.
        fullscreenPresented = false
    }

    private func reconcileHDRPlayback() {
        if showsHDRBrightness, sceneActive, inlineVisible || fullscreenVisible || fullscreenPresented {
            hdrPreview.start(animate: animatesBackground)
        } else {
            hdrPreview.stop()
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                #if os(iOS)
                Menu("Preview options", systemImage: "slider.horizontal.3") {
                    Toggle("Preview file formatting", isOn: $options.showsFileFormatting)
                    Toggle("HDR preview", isOn: $options.showsHDRBrightness)
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
                showsHDRBrightness: options.showsHDRBrightness && options.hdrPreview.state == .ready,
                animate: options.animatesBackground, backgroundOptions: options,
                hdrVideo: options.showsHDRBrightness ? options.hdrPreview : nil,
                hostsHDRVideo: !options.fullscreenPresented
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
            SubtitlePreviewCaption(style: style, options: options)
        }
        .onAppear { options.setVisible(true, fullscreen: false, sceneActive: scenePhase == .active) }
        .onDisappear { options.setVisible(false, fullscreen: false, sceneActive: scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in options.setSceneActive(phase == .active) }
    }
}

private struct SubtitlePreviewCaption: View {
    let style: SubtitleStyle
    let options: SubtitlePreviewOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if options.showsHDRBrightness {
                switch options.hdrPreview.state {
                case .idle, .loading:
                    Text("Preparing HDR preview…")
                case .ready:
                    Text("HDR10 test scene · Subtitle brightness: \(style.hdrLuminanceScale, format: .percent.precision(.fractionLength(0)))")
                    #if os(tvOS)
                    Text("For HDR output, enable Match Dynamic Range or use an HDR video format in Apple TV settings.")
                    #endif
                case .failed(let failure):
                    Text(failure.message).foregroundStyle(.red)
                    Text("Turn HDR preview off and on to retry.")
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

enum SubtitlePreviewSample: CaseIterable {
    case primary, secondary, positioned

    var resource: LocalizedStringResource {
        switch self {
        case .primary:
            LocalizedStringResource(
                "Keep going. We're almost there.\nThe train leaves at 9:45.",
                comment: "Two-line sample subtitle in the style editor preview, not dialogue from a film."
            )
        case .secondary:
            LocalizedStringResource(
                "This is how a second subtitle appears.",
                comment: "Sample subtitle shown in the style editor preview, not dialogue from a film."
            )
        case .positioned:
            LocalizedStringResource(
                "A sign placed by the subtitle file",
                comment: "Sample source-positioned subtitle in the style editor preview, not dialogue from a film."
            )
        }
    }

    func resolve(locale: Locale) -> String {
        var resource = self.resource
        resource.locale = locale
        return String(localized: resource) // l10n:content — CoreText cue boundary; app-authored preview copy resolved with the current environment locale on every update
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
    var hdrVideo: SubtitleHDRPreview? = nil
    var hostsHDRVideo = true
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let hdrVideo {
                    Color.black
                    if hostsHDRVideo { SubtitleHDRVideoSurface(preview: hdrVideo) }
                } else {
                    SubtitlePreviewBackground(animate: animate, options: backgroundOptions)
                }
                if hdrVideo == nil || hdrVideo?.state == .ready {
                    SubtitleOverlayView(
                        primary: primary,
                        secondary: [.init(id: 2, start: 0, end: 60, body: .text(.init(
                            SubtitlePreviewSample.secondary.resolve(locale: locale)
                        )))],
                        secondaryActive: secondaryVisible,
                        style: SystemCaptionStyle.shared.resolved(style),
                        isHDR: showsHDRBrightness
                    )
                    // Cue equality uses identity/timing, not text. Refresh only
                    // passive captions; keep video, background and editor alive.
                    .id(locale.identifier)
                }
                if let hdrVideo {
                    switch hdrVideo.state {
                    case .idle, .loading:
                        ProgressView("Preparing HDR preview…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    case .failed(let failure):
                        Text(failure.message).foregroundStyle(.white).padding(32)
                    case .ready:
                        EmptyView()
                    }
                }
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
            SubtitlePreviewSample.primary.resolve(locale: locale)
        )))]
        if showsFileFormatting {
            cues.append(.init(id: 1, start: 0, end: 60, body: .text(.init(
                runs: [.init(SubtitlePreviewSample.positioned.resolve(locale: locale), color: .yellow)],
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
