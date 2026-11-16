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
            #else
            picker
            #endif
        } description: {
            Text("Automatic selects Animation for anime or animation metadata, otherwise Standard. Standard enhances 8-bit SDR below 1080p; Animation enhances drawn SDR up to 1080p. Requires AetherEngine, supported hardware and a larger display. No HDR or 4K enhancement. Applies to new playback.")
        }
        .accessibilityIdentifier("video-upscaling")
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
