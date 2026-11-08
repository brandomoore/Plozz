import SwiftUI

public struct BrowseRowHeading: View {
    private let title: Text
    private let action: (() -> Void)?

    public init(title: Text, action: (() -> Void)?) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        let label = HStack(spacing: 6) {
            title.fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.forward")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(action == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        // Keep the native hit target without making a loaded heading taller than its placeholder.
        if let action {
            label.hidden()
                .overlay {
                    Button(action: action) {
                        label
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-row-see-all")
                }
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }
}
