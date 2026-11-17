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
                if controls.subtitleStyleAdjustable {
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
    @State private var adjustment = PlayerAudioSyncAdjustment()
    private var offset: Double { adjustment.value ?? controls.audioDelaySeconds }

    var body: some View {
        NavigationStack {
            Form {
                if tracks.engine.capabilities.contains(.audioDelay) {
                    Section("Audio Delay") {
                        Stepper(value: Binding(
                            get: { offset },
                            set: { adjustment.set($0) }
                        ), in: PlayerControlsModel.audioDelayRange,
                            step: PlayerAudioSyncAdjustment.step,
                            onEditingChanged: { editing in
                                if !editing, let value = adjustment.finish() { apply(value) }
                            }
                        ) {
                            Text(offset, format: .number.precision(.fractionLength(2))) + Text(" s")
                        }
                        .accessibilityLabel("Audio Delay")
                        Text(PlayerControlsModel.audioSyncHint(for: offset)).foregroundStyle(.secondary)
                        Button("Reset") {
                            _ = adjustment.finish(cancelled: true)
                            apply(0)
                        }.disabled(offset == 0)
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
        .onDisappear { _ = adjustment.finish(cancelled: true) }
    }

    private func apply(_ value: TimeInterval) {
        guard tracks.engine.capabilities.contains(.audioDelay) else { return }
        tracks.engine.setAudioDelay(value)
        controls.audioDelaySeconds = tracks.engine.audioDelaySeconds
    }
}
#endif
