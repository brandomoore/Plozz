import SwiftUI

public struct BrowseRowHeading: View {
    private let title: Text
    private let action: () -> Void

    public init(title: Text, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                title.fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.forward")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("home-row-see-all")
    }
}
