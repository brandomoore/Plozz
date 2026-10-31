import SwiftUI
import CoreModels

public struct BrowseQueryControls<Content: View>: View {
    @Environment(\.themePalette) private var palette
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        #if os(tvOS)
        HStack(spacing: PlozzTheme.Spacing.medium) { content }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { content.fixedSize() }
            VStack(alignment: .leading, spacing: 4) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.subheadline)
        .tint(palette.primaryText)
        #endif
    }
}

public struct BrowseSortMenu: View {
    private let sort: CoreModels.SortDescriptor
    private let fields: [SortField]
    private let onChange: (CoreModels.SortDescriptor) -> Void
    private let isDefault: Bool
    private let onReset: (() -> Void)?

    public init(
        sort: CoreModels.SortDescriptor,
        fields: [SortField],
        isDefault: Bool = false,
        onReset: (() -> Void)? = nil,
        onChange: @escaping (CoreModels.SortDescriptor) -> Void
    ) {
        self.sort = sort
        self.fields = fields
        self.onChange = onChange
        self.isDefault = isDefault
        self.onReset = onReset
    }

    public var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(
                get: { isDefault ? nil : Optional(sort.field) },
                set: {
                    if let field = $0 { onChange(.init(field: field, direction: field.defaultDirection)) }
                    else { onReset?() }
                }
            )) {
                if onReset != nil { Text("Default").tag(Optional<SortField>.none) }
                ForEach(fields, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            Picker("Order", selection: Binding(
                get: { sort.direction },
                set: { onChange(.init(field: sort.field, direction: $0)) }
            )) {
                ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .disabled(isDefault)
        } label: {
            Label {
                Text(sortTitle)
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #endif
        }
        .accessibilityLabel(Text("Sort: \(sortTitle)"))
    }

    private var sortTitle: LocalizedStringResource { isDefault ? "Default" : sort.field.displayName }
}

public struct BrowseFilterMenu<Content: View>: View {
    private let activeCount: Int
    private let summary: String
    private let content: Content

    public init(activeCount: Int, summary: String, @ViewBuilder content: () -> Content) {
        self.activeCount = activeCount
        self.summary = summary
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            BrowseFilterLabel(activeCount: activeCount, summary: summary)
        }
    }
}

public struct BrowseFilterLabel: View {
    @Environment(\.locale) private var locale
    private let activeCount: Int
    private let summary: String

    public init(activeCount: Int, summary: String) {
        self.activeCount = activeCount
        self.summary = summary
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            Label {
                Text(verbatim: selection)
            } icon: {
                Image(systemName: symbolName)
            }
            .fixedSize()
            if activeCount > 0 {
                Label {
                    Text(activeCount, format: .number)
                } icon: {
                    Image(systemName: symbolName)
                }
                .fixedSize()
            }
        }
        .accessibilityLabel(Text("Filter: \(selection)"))
    }

    private var symbolName: String {
        #if os(iOS)
        activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
        #else
        "line.3.horizontal.decrease"
        #endif
    }

    private var selection: String {
        if activeCount == 0 {
            return String(localized: "All", locale: locale) // l10n:content — resolves the shared unfiltered choice
        }
        return summary
    }
}
