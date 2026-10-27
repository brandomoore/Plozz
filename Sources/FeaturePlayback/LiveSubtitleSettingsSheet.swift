#if os(iOS)
import CoreModels
import SwiftUI

@MainActor
struct LiveSubtitleSettingsSheet: View {
    let tracks: LiveChannelPlayerModel
    let controls: PlayerControlsModel
    @Environment(\.dismiss) private var dismiss
    @State private var offset: Double

    init(tracks: LiveChannelPlayerModel, controls: PlayerControlsModel) {
        self.tracks = tracks
        self.controls = controls
        _offset = State(initialValue: tracks.subtitles.offset)
    }

    var body: some View {
        NavigationStack {
            Form {
                if tracks.subtitles.supportsPrimaryTimingOffset {
                    Section("Subtitle Delay") {
                        Slider(value: $offset, in: -2...2, step: 0.05)
                            .accessibilityLabel("Subtitle Delay")
                        Text(offset, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                }
                if controls.subtitleStyleAdjustable, controls.secondarySubtitleImagePrimaryFormat == nil {
                    Section("Appearance") {
                        NavigationLink("Style") {
                            MobileSubtitleStyleEditor(viewModel: SubtitleStyleEditingContext(
                                controls: controls,
                                style: Binding(
                                    get: { tracks.subtitles.style },
                                    set: { tracks.setSubtitleStyle($0) }
                                ),
                                secondaryPreview: .constant(false), offersDualSubtitles: false
                            ))
                        }
                    }
                }
            }
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("live-subtitle-advanced-sheet")
        .onChange(of: offset) { _, value in
            guard tracks.subtitles.supportsPrimaryTimingOffset else { return }
            tracks.subtitles.offset = value
            controls.subtitleDelaySeconds = value
            tracks.subtitles.tick(tracks.engine.subtitlePresentationTime)
        }
    }
}

@MainActor
struct LiveAudioSyncSheet: View {
    let tracks: LiveChannelPlayerModel
    let controls: PlayerControlsModel
    @Environment(\.dismiss) private var dismiss
    @State private var offset: Double

    init(tracks: LiveChannelPlayerModel, controls: PlayerControlsModel) {
        self.tracks = tracks
        self.controls = controls
        _offset = State(initialValue: controls.audioDelaySeconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                if tracks.engine.capabilities.contains(.audioDelay) {
                    Section("Audio Delay") {
                        Slider(value: $offset, in: -2...2, step: 0.05).accessibilityLabel("Audio Delay")
                        Text(offset, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                }
            }
            .navigationTitle("Audio Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: offset) { _, value in
            guard tracks.engine.capabilities.contains(.audioDelay) else { return }
            tracks.engine.setAudioDelay(value)
            controls.audioDelaySeconds = value
        }
    }
}
#endif
