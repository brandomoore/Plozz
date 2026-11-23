#if canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI

public struct DefaultVideoZoomControl: View {
    @Bindable private var model: PlaybackSettingsModel
    private let platform: VideoZoomDefaults.Platform

    @MainActor
    public init(model: PlaybackSettingsModel, platform: VideoZoomDefaults.Platform? = nil) {
        self.model = model
        self.platform = platform ?? .current
    }

    private var mode: Binding<VideoZoomPreference.Mode> {
        Binding(
            get: { model.settings.videoZoom[platform].mode },
            set: { model.settings.videoZoom[platform].mode = $0 }
        )
    }

    private var percent: Binding<Int> {
        Binding(
            get: { model.settings.videoZoom[platform].customPercent },
            set: {
                model.settings.videoZoom[platform] = .init(
                    mode: .custom, customPercent: $0,
                    pictureFitsInsideSafeArea: model.settings.videoZoom[platform].pictureFitsInsideSafeArea
                )
            }
        )
    }

    public var body: some View {
        SettingsDescribedControl {
            #if os(tvOS)
            SettingsControlRows { controls }
            #else
            VStack(alignment: .leading) { controls }
            #endif
        } description: {
            help
        }
    }

    @ViewBuilder private var controls: some View {
        #if os(tvOS)
        SettingsMenuRow(title: "Default player zoom", value: Text(mode.wrappedValue.title)) {
            modePicker
        }
        .accessibilityIdentifier("default-video-zoom")
        .settingsSearchAnchor("default-video-zoom")
        #else
        modePicker
            .pickerStyle(.menu)
            .accessibilityIdentifier("default-video-zoom")
            .settingsSearchAnchor("default-video-zoom")
        #endif
        if mode.wrappedValue == .custom {
            #if os(tvOS)
            SettingsStepper(
                options: Array(VideoZoomPreference.customPercentRange), selection: percent,
                compact: true, label: "Zoom",
                textTitle: { Text(Double($0) / 100, format: .percent.precision(.fractionLength(0))) }
            )
            .environment(\.settingsAdjustmentRepeatSpeed, .fast)
            .accessibilityIdentifier("custom-video-zoom")
            .settingsSearchAnchor("custom-video-zoom")
            #else
            HStack {
                Text("Zoom")
                Slider(value: Binding(
                    get: { Double(percent.wrappedValue) },
                    set: { percent.wrappedValue = Int($0.rounded()) }
                ), in: 50...200, step: 1) {
                    Text("Zoom")
                }
                .accessibilityIdentifier("custom-video-zoom")
                .settingsSearchAnchor("custom-video-zoom")
                Text(Double(percent.wrappedValue) / 100, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            #endif
        }
    }

    private var modePicker: some View {
        Picker("Default player zoom", selection: mode) {
            ForEach([VideoZoomPreference.Mode.picture, .fit, .fill, .stretch, .custom], id: \.self) {
                Text($0.title).tag($0)
            }
        }
        .settingsSearchAnchor("default-video-zoom")
    }

    private var help: Text {
        Text("iPhone, iPad and Apple TV use separate defaults. Changing zoom mode saves it for that movie or TV show.")
    }
}
#endif
