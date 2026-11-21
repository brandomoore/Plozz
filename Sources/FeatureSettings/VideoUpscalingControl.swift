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
        #if os(tvOS)
        SettingsDescribedControl {
            SettingsMenuRow(title: "Video upscaling", value: Text(selection.title)) {
                picker
            }
            .accessibilityIdentifier("video-upscaling")
        } description: {
            help
        }
        #else
        SettingsSectionGroup {
            picker
                .accessibilityIdentifier("video-upscaling")
                .settingsSearchAnchor("video-upscaling")
        } footer: {
            help
        }
        .settingsSearchGroup(["video-upscaling"])
        #endif
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
#endif
