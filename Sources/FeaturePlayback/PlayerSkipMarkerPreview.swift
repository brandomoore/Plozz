#if DEBUG && os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

@MainActor
public struct PlayerSkipMarkerPreview: View {
    @State private var model = Self.makeModel()
    @State private var brightPicture = false
    @State private var halfHeightPattern = true
    @State private var positionIndex = 2
    @State private var bufferIndex = 1
    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["PLOZZ_SKIP_MARKER_PREVIEW"] == "1"
    }

    static func makeModel() -> PlayerControlsModel {
        let model = PlayerControlsModel()
        model.duration = 1_440
        model.currentSeconds = 675
        model.bufferedSeconds = 700
        model.controlsVisible = true
        model.skipSegments.segments = [
            .init(id: "preview-recap", kind: .recap, start: 0, end: 32),
            .init(id: "preview-intro", kind: .intro, start: 40, end: 125),
            .init(id: "preview-commercial", kind: .commercial, start: 630, end: 720),
            .init(id: "preview-credits", kind: .credits, start: 1_320, end: 1_440)
        ]
        return model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            MarkerComparisonHeader()
            MarkerComparisonGroup(treatment: .halfCutout, model: model)
            MarkerComparisonGroup(
                treatment: halfHeightPattern ? .halfHatchedCutout : .hatchedCutout, model: model
            )
            MarkerComparisonControls(
                model: model, brightPicture: $brightPicture, halfHeightPattern: $halfHeightPattern,
                movePosition: advancePosition, moveBuffer: advanceBuffer, onClose: onClose
            )
            Text(verbatim: "The commercial section runs from 10:30 to 12:00. Menu returns to Plozz. No playback preferences are changed.")
                .font(.system(size: 21))
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { MarkerComparisonBackground(bright: brightPicture) }
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, .dark)
        .onAppear { HandoffDiagnostics.emit("player MARKER_PREVIEW presented") }
        .onExitCommand(perform: onClose)
    }

    private func advancePosition() {
        let positions: [TimeInterval] = [615, 650, 675, 710, 750]
        positionIndex = (positionIndex + 1) % positions.count
        model.currentSeconds = positions[positionIndex]
        model.bufferedSeconds = max(model.currentSeconds, model.bufferedSeconds)
    }

    private func advanceBuffer() {
        let buffers: [TimeInterval] = [675, 700, 715, 900]
        bufferIndex = (bufferIndex + 1) % buffers.count
        model.bufferedSeconds = max(model.currentSeconds, buffers[bufferIndex])
    }
}

private struct MarkerComparisonHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Compare skip markers")
                .font(.system(size: 36, weight: .bold))
                .accessibilityIdentifier("marker-preview-ready")
            Text(verbatim: "Actual player bars: Liquid Glass and the flat performance fallback. This is a visual preview, not a performance benchmark.")
                .font(.system(size: 23))
                .foregroundStyle(.white.opacity(0.72))
        }
        .foregroundStyle(.white)
    }
}

private struct MarkerComparisonGroup: View {
    let treatment: PlayerSkipMarkerTreatment
    let model: PlayerControlsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: treatment == .halfCutout
                 ? "A  ·  50% open cutout"
                 : treatment == .halfHatchedCutout
                    ? "B  ·  50% cutout + faint diagonals" : "B  ·  75% cutout + faint diagonals")
                .font(.system(size: 27, weight: .semibold))
            MarkerComparisonRow(model: model, treatment: treatment, performance: false)
            MarkerComparisonRow(model: model, treatment: treatment, performance: true)
        }
        .foregroundStyle(.white)
    }
}

private struct MarkerComparisonRow: View {
    let model: PlayerControlsModel
    let treatment: PlayerSkipMarkerTreatment
    let performance: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: performance ? "Performance · flat" : "Liquid Glass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            ScrubBar(model: model, palette: .dark, markerTreatment: treatment)
                .frame(height: 44)
            PlayerTimelineTimes(model: model)
                .frame(height: 30)
        }
        .environment(\.plozzReducePanelGlass, performance)
        .accessibilityElement(children: .combine)
    }
}

private struct MarkerComparisonControls: View {
    let model: PlayerControlsModel
    @Binding var brightPicture: Bool
    @Binding var halfHeightPattern: Bool
    let movePosition: () -> Void
    let moveBuffer: () -> Void
    let onClose: () -> Void
    @FocusState private var positionFocused: Bool

    var body: some View {
        HStack(spacing: 24) {
            Button(action: movePosition) {
                Text(verbatim: "Move playhead")
            }
            .accessibilityIdentifier("marker-preview-position")
            .accessibilityValue(Text(verbatim: PlayerControls.timeLabel(model.currentSeconds)))
            .focused($positionFocused)
            Button(action: moveBuffer) {
                Text(verbatim: "Move buffer")
            }
            .accessibilityIdentifier("marker-preview-buffer")
            .accessibilityValue(Text(verbatim: PlayerControls.timeLabel(model.bufferedSeconds)))
            Button {
                halfHeightPattern.toggle()
            } label: {
                Text(verbatim: halfHeightPattern ? "Cutout B: 50%" : "Cutout B: 75%")
            }
            .accessibilityIdentifier("marker-preview-size")
            Button {
                model.controlBarVisible.toggle()
            } label: {
                Text(verbatim: model.controlBarVisible ? "Bar: normal" : "Bar: focused")
            }
            .accessibilityIdentifier("marker-preview-focus")
            Button {
                brightPicture.toggle()
            } label: {
                Text(verbatim: brightPicture ? "Picture: bright" : "Picture: dark")
            }
            .accessibilityIdentifier("marker-preview-picture")
            Spacer(minLength: 0)
            Button("Done", action: onClose)
                .accessibilityIdentifier("marker-preview-done")
        }
        .font(.system(size: 24, weight: .medium))
        .buttonStyle(.bordered)
        .defaultFocus($positionFocused, true)
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
