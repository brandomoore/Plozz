import CoreModels
import SwiftUI

public struct DiscoverFilterMenu: View {
    @Binding private var filters: DiscoverFilters
    @Environment(\.locale) private var locale

    public init(filters: Binding<DiscoverFilters>) {
        _filters = filters
    }

    public var body: some View {
        BrowseFilterMenu(activeCount: filters.activeCount, summary: summary) {
            Toggle("Available now", isOn: $filters.availableNow)
            Toggle("Hide watched", isOn: $filters.hideWatched)
            if filters.activeCount > 0 {
                Button("Clear Filters") { filters = .init() }
            }
        }
        .accessibilityIdentifier("discover-filter-menu")
    }

    private var summary: String {
        var labels: [String] = []
        if filters.availableNow { labels.append(String(localized: "Available now", locale: locale)) }
        if filters.hideWatched { labels.append(String(localized: "Hide watched", locale: locale)) }
        return labels.formatted(.list(type: .and))
    }
}
