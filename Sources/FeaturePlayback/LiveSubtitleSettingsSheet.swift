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
    let apply: (TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    private var adjustment: PlayerAudioSyncEditor { controls.audioSyncAdjustment }
    private var offset: Double { adjustment.value ?? controls.audioDelaySeconds }

    var body: some View {
        NavigationStack {
            Form {
                if tracks.engine.capabilities.contains(.audioDelay) {
                    Section("Audio Delay") {
                        Stepper(value: Binding(
                            get: { offset },
                            set: change
                        ), in: adjustment.range,
                            step: PlayerAudioSyncAdjustment.step,
                            onEditingChanged: { editing in
                                if editing { adjustment.beginEditing() }
                                else { adjustment.endEditing(commit: apply) }
                            }
                        ) {
                            Text(offset, format: .number.precision(.fractionLength(2))) + Text(" s")
                        }
                        .accessibilityLabel("Audio Delay")
                        Text(PlayerControlsModel.audioSyncHint(for: offset)).foregroundStyle(.secondary)
                        Button("Reset") {
                            adjustment.cancel()
                            change(0)
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
        .onDisappear { adjustment.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            adjustment.cancel()
        }
        .onChange(of: controls.infoCard.sourceItemID) { _, _ in adjustment.cancel() }
        .onChange(of: controls.infoCard.sourceAccountID) { _, _ in adjustment.cancel() }
    }

    private func change(_ value: TimeInterval) {
        adjustment.change(to: value, current: controls.audioDelaySeconds, applyLive: { _ in false }, commit: apply)
    }
}
#endif
