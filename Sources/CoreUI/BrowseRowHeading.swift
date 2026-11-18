import SwiftUI

public extension EnvironmentValues {
    @Entry var homeRowEditAction: (() -> Void)? = nil
}

public struct BrowseRowHeading: View {
    @Environment(\.homeRowEditAction) private var editAction
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
                    .contextMenu {
                        if let editAction {
                            Button("Edit", systemImage: "pencil", action: editAction)
                        }
                    }
                    .accessibilityActions {
                        if let editAction { Button("Edit", action: editAction) }
                    }
                }
        } else if let editAction {
            label.hidden()
                .overlay {
                    label
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        .contextMenu {
                            Button("Edit", systemImage: "pencil", action: editAction)
                        }
                        .accessibilityActions { Button("Edit", action: editAction) }
                }
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }
}
