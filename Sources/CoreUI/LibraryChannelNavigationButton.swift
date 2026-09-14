#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct LibraryChannelNavigationButton: View {
    private let item: LibraryChannelItem
    private let action: (LibraryChannelItem) -> Void

    public init(item: LibraryChannelItem, action: @escaping (LibraryChannelItem) -> Void) {
        self.item = item
        self.action = action
    }

    public var body: some View {
        Button {
            action(item)
        } label: {
            Label {
                Text(item.navigationTitle)
            } icon: {
                Image(systemName: item.kind == .movie ? "film" : "tv")
            }
        }
        .accessibilityIdentifier("library-channel-open-title")
    }
}
#endif
