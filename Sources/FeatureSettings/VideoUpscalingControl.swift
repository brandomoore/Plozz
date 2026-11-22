#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct VideoUpscalingControl: View {
    @Binding private var selection: VideoUpscaling

    public init(selection: Binding<VideoUpscaling>) {
        _selection = selection
    }

    public var body: some View {
        SettingsDescribedControl {
            #if os(tvOS)
            SettingsMenuRow(title: "Video upscaling", value: Text(selection.title)) {
                picker
            }
            .accessibilityIdentifier("video-upscaling")
            #else
            picker
                .accessibilityIdentifier("video-upscaling")
                .settingsSearchAnchor("video-upscaling")
            #endif
        } description: {
            help
        }
    }

    @ViewBuilder private var help: some View {
        if selection == .automatic {
            Text("Uses Animation for titles marked as animated, and Standard otherwise.")
        }
    }

    private var picker: some View {
        Picker("Video upscaling", selection: $selection) {
            ForEach(VideoUpscaling.allCases, id: \.self) {
                Text($0.title).tag($0)
            }
        }
    }
}

public struct DolbyVisionFELConversionControl: View {
    @Binding private var isOn: Bool

    public init(isOn: Binding<Bool>) { _isOn = isOn }

    public var body: some View {
        SettingsDescribedControl {
            Toggle("P7 FEL → P8.1 conversion", isOn: $isOn)
        } description: {
            Text("Approximates enhancement-layer brightness without full FEL reconstruction. Turn off to use HDR10.")
        }
    }
}
#endif
