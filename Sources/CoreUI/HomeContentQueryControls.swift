import CoreModels
import SwiftUI

public struct HomeContentSortOptions: View {
    @Binding private var query: HomeContentQuery

    public init(query: Binding<HomeContentQuery>) { _query = query }

    public var body: some View {
        Picker("Sort By", selection: Binding(
            get: { query.sort?.field },
            set: { query.sort = $0.map { .init(field: $0, direction: $0.defaultDirection) } }
        )) {
            Text("Source order").tag(Optional<SortField>.none)
            ForEach(HomeContentQuery.sortFields, id: \.self) { Text($0.displayName).tag(Optional($0)) }
        }
        if let sort = query.sort {
            Picker("Order", selection: Binding(
                get: { sort.direction },
                set: { query.sort = .init(field: sort.field, direction: $0) }
            )) {
                ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
    }
}

public struct HomeContentFilterOptions: View {
    @Binding private var query: HomeContentQuery

    public init(query: Binding<HomeContentQuery>) { _query = query }

    public var body: some View {
        Picker("Media", selection: $query.media) {
            ForEach(WatchlistMediaFilter.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        Picker("Watch status", selection: $query.filters.filter) {
            Text("All").tag(LibraryFilter.all)
            Text("Unwatched").tag(LibraryFilter.unwatched)
            Text("In Progress").tag(LibraryFilter.inProgress)
        }
        if query.activeFilterCount > 0 {
            Button("Clear Filters") {
                query.media = .all
                query.filters = .all
            }
        }
    }
}
