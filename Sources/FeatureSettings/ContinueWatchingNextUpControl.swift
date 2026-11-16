#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ContinueWatchingNextUpControl: View {
    public let visibility: HomeLibraryVisibilityModel

    public init(visibility: HomeLibraryVisibilityModel) {
        self.visibility = visibility
    }

    public var body: some View {
        SettingsDescribedControl {
            Toggle("Include Next Up", isOn: Binding(
                get: { visibility.visibility.mergeNextUpIntoContinueWatching },
                set: { visibility.setMergeNextUpIntoContinueWatching($0) }
            ))
            .accessibilityIdentifier("home-merge-next-up")
        } description: {
            if visibility.isGlobalRowEnabled(.continueWatching) {
                Text("Combines Next Up rows here.")
            } else {
                Text("Add Continue Watching to Home to include Next Up.")
            }
        }
        .toggleStyle(SettingsSwitchToggleStyle())
        .disabled(!visibility.isGlobalRowEnabled(.continueWatching))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
