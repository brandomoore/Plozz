#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct CollectionCoverLayoutPicker: View {
    @Binding private var selection: CollectionCoverLayout
    private let title: LocalizedStringResource

    public init(
        selection: Binding<CollectionCoverLayout>,
        title: LocalizedStringResource = LocalizedStringResource(
            "Covers", comment: "Short label for the collection cover image layout setting."
        )
    ) {
        _selection = selection
        self.title = title
    }

    public var body: some View {
        Picker(selection: $selection) {
            ForEach(CollectionCoverLayout.allCases, id: \.self) { layout in
                Text(layout.title).tag(layout)
            }
        } label: {
            Text(title)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("collection-cover-layout")
    }
}
#endif
