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
        Toggle(isOn: Binding(
            get: { visibility.visibility.mergeNextUpIntoContinueWatching },
            set: { visibility.setMergeNextUpIntoContinueWatching($0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Include Next Up")
                if visibility.isGlobalRowEnabled(.continueWatching) {
                    Text("Combines Next Up rows here.")
                        .settingsHelperText()
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Add Continue Watching to Home to include Next Up.")
                        .settingsHelperText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(SettingsSwitchToggleStyle())
        .disabled(!visibility.isGlobalRowEnabled(.continueWatching))
        .accessibilityIdentifier("home-merge-next-up")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
