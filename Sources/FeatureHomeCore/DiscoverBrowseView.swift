import CoreModels
import CoreUI
import SwiftUI

/// Feed state and controls are shared; each shell supplies its existing media rail.
public struct DiscoverBrowseView<RowContent: View>: View {
    @State private var model: DiscoverBrowseModel
    @State private var libraryRevision = 0
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    private let isActive: Bool
    private let rowContent: (DiscoverFeed, [MediaItem], Bool) -> RowContent

    public init(
        model: DiscoverBrowseModel,
        isActive: Bool = true,
        @ViewBuilder rowContent: @escaping (DiscoverFeed, [MediaItem], Bool) -> RowContent
    ) {
        _model = State(initialValue: model)
        self.isActive = isActive
        self.rowContent = rowContent
    }

    public var body: some View {
        @Bindable var browse = model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                #if os(tvOS)
                HStack {
                    Text("Discover").font(.largeTitle.bold())
                    Spacer()
                    BrowseQueryControls { DiscoverFilterMenu(filters: $browse.filters) }
                }
                .padding(.leading, PlozzTheme.Metrics.screenPadding + navigationInset)
                .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                .focusSection()
                #endif
                ForEach(model.rows) { row in
                    let items = row.items.filter(model.filters.includes)
                    VStack(alignment: .leading, spacing: 12) {
                        if items.isEmpty && !row.isLoading {
                            MediaRowHeader(title: Text(row.feed.title), leadingInset: horizontalInset)
                        } else {
                            rowContent(row.feed, items, row.isLoading && row.items.isEmpty)
                        }
                        DiscoverRowFooter(
                            row: row, isEmpty: items.isEmpty,
                            isFiltered: model.filters.activeCount > 0,
                            onClearFilters: { model.filters = .init() },
                            onLoadMore: { await model.loadMore(row.feed) }
                        )
                        .padding(.leading, horizontalInset + navigationInset)
                        .padding(.trailing, horizontalInset)
                    }
                    .accessibilityIdentifier("discover-row-\(row.feed.rawValue)")
                }
            }
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .scrollsTopNavigation()
        #if os(iOS)
        .navigationTitle("Discover")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DiscoverFilterMenu(filters: $browse.filters).labelStyle(.iconOnly)
            }
        }
        #endif
        .task(id: isActive) {
            if isActive {
                let hasLoadedItems = model.rows.contains { !$0.items.isEmpty }
                await model.load()
                if hasLoadedItems { await model.refreshLibrarySources() }
            }
        }
        .task(id: libraryRevision) {
            if isActive, libraryRevision > 0 { await model.refreshLibrarySources() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .identityIndexDidUpdate)) { _ in
            libraryRevision &+= 1
        }
        .onChange(of: model.filters.availableNow) {
            if model.filters.availableNow { libraryRevision &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) { model.applyWatchedState(mutation) }
        }
        .accessibilityIdentifier("discover-page")
    }

    private var horizontalInset: CGFloat {
        #if os(tvOS)
        PlozzTheme.Metrics.screenPadding
        #else
        20
        #endif
    }
}

private struct DiscoverRowFooter: View {
    let row: DiscoverRow
    let isEmpty: Bool
    let isFiltered: Bool
    let onClearFilters: () -> Void
    let onLoadMore: () async -> Void
    @State private var request = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = row.error {
                Text(error.userMessage).foregroundStyle(.secondary)
                Button("Try Again") { request &+= 1 }
                    .plozzPageActionButton(role: .secondary)
            } else if row.isLoading {
                if !row.items.isEmpty { ProgressView() }
            } else {
                if isEmpty {
                    if isFiltered {
                        Text("No titles match these filters.").foregroundStyle(.secondary)
                        Button("Clear Filters", action: onClearFilters)
                            .plozzPageActionButton(role: .secondary)
                    } else {
                        Text("No titles yet.").foregroundStyle(.secondary)
                    }
                }
                if row.nextPage != nil {
                    Button("Load More") { request &+= 1 }
                        .plozzPageActionButton(role: .secondary)
                }
            }
        }
        .task(id: request) {
            if request > 0 {
                await onLoadMore()
                request = 0
            }
        }
    }
}
