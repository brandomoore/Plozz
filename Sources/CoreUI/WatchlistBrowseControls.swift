import SwiftUI
import CoreModels

public struct WatchlistBrowseControls: View {
    @Binding private var preferences: WatchlistBrowsePreferences

    public init(preferences: Binding<WatchlistBrowsePreferences>) {
        _preferences = preferences
    }

    public var body: some View {
        BrowseQueryControls {
            #if os(tvOS)
            WatchlistFilterMenu(filter: $preferences.filter)
            WatchlistSortMenu(sort: $preferences.sort)
            #else
            WatchlistSortMenu(sort: $preferences.sort)
            WatchlistFilterMenu(filter: $preferences.filter)
            #endif
        }
    }
}

public struct WatchlistSortMenu: View {
    @Binding private var sort: CoreModels.SortDescriptor

    public init(sort: Binding<CoreModels.SortDescriptor>) {
        _sort = sort
    }

    public var body: some View {
        BrowseSortMenu(sort: sort, fields: WatchlistBrowsePreferences.sortFields) {
            sort = $0
        }
        .accessibilityIdentifier("watchlist-sort-menu")
    }
}

public struct WatchlistFilterMenu: View {
    @Binding private var filter: WatchlistMediaFilter
    @Environment(\.locale) private var locale

    public init(filter: Binding<WatchlistMediaFilter>) {
        _filter = filter
    }

    public var body: some View {
        BrowseFilterMenu(activeCount: filter == .all ? 0 : 1, summary: filterSummary) {
            Picker("Filter", selection: $filter) {
                ForEach(WatchlistMediaFilter.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            if filter != .all {
                Button("Clear Filters") { filter = .all }
            }
        }
        #if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
        #endif
        .accessibilityIdentifier("watchlist-filter-menu")
    }

    private var filterSummary: String {
        var name = filter.displayName
        name.locale = locale
        return String(localized: name) // l10n:content — resolves the existing filter label
    }
}

public struct WatchlistEmptyStateView: View {
    private let isFiltered: Bool
    private let clearFilters: () -> Void

    public init(isFiltered: Bool, clearFilters: @escaping () -> Void) {
        self.isFiltered = isFiltered
        self.clearFilters = clearFilters
    }

    public var body: some View {
        ContentUnavailableView {
            Label {
                if isFiltered {
                    Text("No titles match these filters.")
                } else {
                    Text("Your Watchlist is empty")
                }
            } icon: {
                Image(systemName: "bookmark")
            }
        } description: {
            if !isFiltered {
                Text("Add a movie or show from Plozz or any connected Watchlist.")
            }
        } actions: {
            if isFiltered { Button("Clear Filters", action: clearFilters) }
        }
    }
}
