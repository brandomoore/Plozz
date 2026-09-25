#if canImport(SwiftUI)
import CoreModels
import Observation
import SwiftUI

/// The app supplies the shared playback editor without making Settings depend on playback.
@MainActor
@Observable
public final class SubtitleStyleSettingsDestination {
    @ObservationIgnored private let makeContent: (Binding<SubtitleStyle>, Bool) -> AnyView

    public init(content: @escaping (Binding<SubtitleStyle>, Bool) -> AnyView) {
        makeContent = content
    }

    public func content(style: Binding<SubtitleStyle>, isLiveTV: Bool) -> AnyView {
        makeContent(style, isLiveTV)
    }
}
#endif
