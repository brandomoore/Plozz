#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// Resolves presentation names without changing destination or provider identity.
@MainActor
public struct NavigationTitles: DynamicProperty {
    @Environment(NavigationStyleSettingsModel.self) private var navigation: NavigationStyleSettingsModel?
    @Environment(HomeLibraryVisibilityModel.self) private var homeVisibility: HomeLibraryVisibilityModel?

    public init() {}

    public func callAsFunction(_ key: String, default title: Text) -> Text {
        let layout = navigation?.libraryLayout ?? .default
        return layout.customName(for: key, homeVisibility: homeVisibility?.visibility ?? .default)
            .map { Text(verbatim: $0) } ?? title
    }
}
#endif
