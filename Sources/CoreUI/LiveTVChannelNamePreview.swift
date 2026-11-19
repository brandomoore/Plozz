#if canImport(SwiftUI)
import SwiftUI

public extension EnvironmentValues {
    @Entry var liveTVChannelNamePreviewSamples: [String] = []
    @Entry var liveTVShowsActivityInHeader = false
}

public struct LiveTVPreviewActivity: Equatable {
    public let channelID: String
    public let label: LocalizedStringResource

    public init(channelID: String, label: LocalizedStringResource) {
        self.channelID = channelID
        self.label = label
    }
}

public struct LiveTVPreviewActivityKey: PreferenceKey {
    public static var defaultValue: LiveTVPreviewActivity? { nil }
    public static func reduce(value: inout LiveTVPreviewActivity?, nextValue: () -> LiveTVPreviewActivity?) {
        value = nextValue() ?? value
    }
}
#endif
