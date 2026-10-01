#if DEBUG && os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

@MainActor
public struct PlayerSkipMarkerPreview: View {
    @State private var model = Self.makeModel()
    @State private var scenario = PlayerSkipMarkerScenario.hourEpisode
    @State private var picture = MarkerPreviewPicture.dark
    @State private var pattern = PlayerSkipMarkerPattern.default
    @State private var positionIndex = 2
    @State private var bufferIndex = 1
    private let onClose: () -> Void
    private let video: PlayerSkipMarkerVideo?

    public init(onClose: @escaping () -> Void, video: PlayerSkipMarkerVideo? = nil) {
        self.onClose = onClose
        self.video = video
    }

    public static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        PlayerMarkerPreviewRequest.isRequested(environment: environment)
    }

    static func makeModel() -> PlayerControlsModel {
        let model = PlayerControlsModel()
        model.controlsVisible = true
        PlayerSkipMarkerScenario.hourEpisode.apply(to: model)
        return model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MarkerComparisonHeader()
            MarkerPatternPicker(selection: $pattern)
            pattern.previewExplanation
                .font(.system(size: 23))
                .foregroundStyle(.white.opacity(0.72))
                .frame(height: 32, alignment: .leading)
                .accessibilityIdentifier("marker-preview-explanation")
            MarkerScenarioPicker(scenario: scenario) {
                scenario = scenario.next
                positionIndex = 2
                bufferIndex = 1
                scenario.apply(to: model)
            }
            MarkerComparisonGroup(pattern: pattern, model: model)
            MarkerComparisonControls(
                model: model, picture: $picture, video: video,
                movePosition: advancePosition, moveBuffer: advanceBuffer, onClose: onClose
            )
            if let video, picture == .video {
                MarkerVideoStatus(model: video)
            }
            Text(verbatim: "Example timings at true scale, independent of the background episode. Menu returns to Plozz. No watch-history or preference changes.")
                .font(.system(size: 21))
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let video, picture == .video {
                PlayerSkipMarkerVideoBackdrop(model: video)
                    .overlay(Color.black.opacity(0.28).ignoresSafeArea())
            } else {
                MarkerComparisonBackground(bright: picture == .bright)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, .dark)
        .onAppear { HandoffDiagnostics.emit("player MARKER_PREVIEW presented") }
        .onChange(of: video.map(ObjectIdentifier.init), initial: true) { _, identity in
            if identity != nil { picture = .video }
        }
        .onExitCommand(perform: onClose)
    }

    private func advancePosition() {
        let positions = scenario.positions
        positionIndex = (positionIndex + 1) % positions.count
        model.currentSeconds = positions[positionIndex]
        model.bufferedSeconds = max(model.currentSeconds, model.bufferedSeconds)
    }

    private func advanceBuffer() {
        let buffers = scenario.buffers
        bufferIndex = (bufferIndex + 1) % buffers.count
        model.bufferedSeconds = max(model.currentSeconds, buffers[bufferIndex])
    }
}

private enum MarkerPreviewPicture {
    case video, dark, bright
}

private struct MarkerComparisonHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Compare skip markers")
                .font(.system(size: 36, weight: .bold))
                .accessibilityIdentifier("marker-preview-ready")
            Text(verbatim: "50% patterned cutouts, identical track colors, and realistic durations. Short markers are never stretched.")
                .font(.system(size: 23))
                .foregroundStyle(.white.opacity(0.72))
        }
        .foregroundStyle(.white)
    }
}

private struct MarkerComparisonGroup: View {
    let pattern: PlayerSkipMarkerPattern
    let model: PlayerControlsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            MarkerComparisonRow(model: model, pattern: pattern, performance: false)
            MarkerComparisonRow(model: model, pattern: pattern, performance: true)
        }
        .foregroundStyle(.white)
    }
}

private struct MarkerComparisonRow: View {
    let model: PlayerControlsModel
    let pattern: PlayerSkipMarkerPattern
    let performance: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: performance ? "Performance · flat" : "Liquid Glass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            ScrubBar(model: model, palette: .dark, markerTreatment: .halfHatchedCutout, markerPattern: pattern)
                .frame(height: 44)
            PlayerTimelineTimes(model: model)
                .frame(height: 30)
        }
        .environment(\.plozzReducePanelGlass, performance)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(performance ? "marker-preview-flat" : "marker-preview-glass")
    }
}

private struct MarkerComparisonControls: View {
    let model: PlayerControlsModel
    @Binding var picture: MarkerPreviewPicture
    let video: PlayerSkipMarkerVideo?
    let movePosition: () -> Void
    let moveBuffer: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button(action: movePosition) {
                Text(verbatim: "Move playhead")
            }
            .accessibilityIdentifier("marker-preview-position")
            .accessibilityValue(Text(verbatim: PlayerControls.timeLabel(model.currentSeconds)))
            Button(action: moveBuffer) {
                Text(verbatim: "Move buffer")
            }
            .accessibilityIdentifier("marker-preview-buffer")
            .accessibilityValue(Text(verbatim: PlayerControls.timeLabel(model.bufferedSeconds)))
            Button {
                model.controlBarVisible.toggle()
            } label: {
                Text(verbatim: model.controlBarVisible ? "Bar: normal" : "Bar: focused")
            }
            .accessibilityIdentifier("marker-preview-focus")
            Button {
                switch picture {
                case .video: picture = .dark
                case .dark: picture = .bright
                case .bright: picture = video == nil ? .dark : .video
                }
            } label: {
                Text(verbatim: picture == .video ? "Picture: episode" : picture == .bright ? "Picture: bright" : "Picture: dark")
            }
            .accessibilityIdentifier("marker-preview-picture")
            if let video, picture == .video {
                Button { video.togglePause() } label: {
                    Text(verbatim: video.isPaused ? "Play video" : "Pause video")
                }
                .disabled(video.state != .ready)
                .accessibilityIdentifier("marker-preview-video-pause")
            }
            Spacer(minLength: 0)
            Button("Done", action: onClose)
                .accessibilityIdentifier("marker-preview-done")
        }
        .font(.system(size: 24, weight: .medium))
        .buttonStyle(.bordered)
    }
}

private struct MarkerScenarioPicker: View {
    let scenario: PlayerSkipMarkerScenario
    let next: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            Button(action: next) {
                scenario.previewTitle
                    .frame(width: 325)
            }
            .font(.system(size: 24, weight: .medium))
            .buttonStyle(.bordered)
            .accessibilityIdentifier("marker-preview-scenario")
            scenario.previewDetails
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.76))
                .accessibilityIdentifier("marker-preview-scenario-details")
            Spacer(minLength: 0)
        }
    }
}

private struct MarkerVideoStatus: View {
    let model: PlayerSkipMarkerVideo

    var body: some View {
        HStack(spacing: 14) {
            switch model.state {
            case .idle, .loading:
                ProgressView().tint(.white)
                Text(verbatim: "Loading an episode from this profile's enabled libraries...")
                    .foregroundStyle(.white.opacity(0.8))
            case .ready:
                Text(verbatim: "Muted background: \(model.title)")
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8))
            case .failed(let error):
                Text(error.userMessage)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8))
                Button { model.start() } label: { Text(verbatim: "Retry video") }
            }
        }
        .font(.system(size: 20))
        .frame(height: 36)
        .accessibilityIdentifier("marker-preview-video-status")
    }
}

private extension PlayerSkipMarkerScenario {
    var previewTitle: Text {
        switch self {
        case .hourEpisode: Text(verbatim: "Example: 1h episode")
        case .shortEpisode: Text(verbatim: "Example: 24m episode")
        case .longMovie: Text(verbatim: "Example: 3h movie")
        case .recording: Text(verbatim: "Example: 90m recording")
        case .tinyRecap: Text(verbatim: "Example: 45m / tiny recap")
        }
    }

    var previewDetails: Text {
        switch self {
        case .hourEpisode: Text(verbatim: "30s intro at 1:30 + 1m credits. Intro = 0.83% of the bar.")
        case .shortEpisode: Text(verbatim: "90s intro at 0:40 + 90s credits. Intro = 6.25% of the bar.")
        case .longMovie: Text(verbatim: "2m credits at 2:58:00. Credits = 1.11% of the bar.")
        case .recording: Text(verbatim: "Four 3m ad breaks across 90 minutes. Each break = 3.33%.")
        case .tinyRecap: Text(verbatim: "8s recap at 1:00, 1m intro and credits. Recap = 0.30%.")
        }
    }
}

private struct MarkerPatternPicker: View {
    @Binding var selection: PlayerSkipMarkerPattern
    @FocusState private var focused: PlayerSkipMarkerPattern?

    var body: some View {
        HStack(spacing: 24) {
            ForEach(PlayerSkipMarkerPattern.allCases, id: \.self) { pattern in
                Button {
                    selection = pattern
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .opacity(selection == pattern ? 1 : 0)
                        pattern.previewTitle
                    }
                    .frame(width: 235)
                }
                .accessibilityIdentifier("marker-pattern-\(pattern.rawValue)")
                .accessibilityValue(Text(verbatim: selection == pattern ? "Selected" : "Not selected"))
                .focused($focused, equals: pattern)
            }
        }
        .font(.system(size: 24, weight: .medium))
        .buttonStyle(.bordered)
        .defaultFocus($focused, .diagonal)
    }
}

private extension PlayerSkipMarkerPattern {
    var previewTitle: Text {
        switch self {
        case .diagonal: Text(verbatim: "Diagonals")
        case .denseDots: Text(verbatim: "Dense dots")
        case .mediumHatch: Text(verbatim: "Medium hatch")
        case .fineHatch: Text(verbatim: "Fine hatch")
        case .mesh: Text(verbatim: "Diamond mesh")
        }
    }

    var previewExplanation: Text {
        switch self {
        case .diagonal: Text(verbatim: "A familiar marked-off range. Clear and continuous.")
        case .denseDots: Text(verbatim: "Smaller 2pt dots in close, staggered rows. The same spacing with a finer grain.")
        case .mediumHatch: Text(verbatim: "A middle ground: thinner strokes at 12pt spacing, between the original and fine hatch.")
        case .fineHatch: Text(verbatim: "Twice as many diagonals with thinner strokes. More continuous, less stripe-like.")
        case .mesh: Text(verbatim: "A tighter 8pt diamond mesh. Smaller openings make it read as a continuous woven texture.")
        }
    }
}

private struct MarkerComparisonBackground: View {
    let bright: Bool

    var body: some View {
        LinearGradient(
            colors: bright
                ? [Color(red: 0.28, green: 0.4, blue: 0.48), Color(red: 0.1, green: 0.17, blue: 0.23)]
                : [Color(red: 0.07, green: 0.13, blue: 0.19), Color(red: 0.02, green: 0.04, blue: 0.07)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Canvas { context, size in
                var mountain = Path()
                mountain.move(to: CGPoint(x: 0, y: size.height * 0.65))
                mountain.addLine(to: CGPoint(x: size.width * 0.3, y: size.height * 0.32))
                mountain.addLine(to: CGPoint(x: size.width * 0.53, y: size.height * 0.6))
                mountain.addLine(to: CGPoint(x: size.width * 0.76, y: size.height * 0.36))
                mountain.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
                mountain.addLine(to: CGPoint(x: size.width, y: size.height))
                mountain.addLine(to: CGPoint(x: 0, y: size.height))
                mountain.closeSubpath()
                context.fill(mountain, with: .color(.black.opacity(0.16)))
            }
        }
        .ignoresSafeArea()
    }
}
#endif
