import CoreModels
import CoreUI
import SwiftUI

/// Feed state and controls are shared; each shell supplies its existing media rail.
public struct DiscoverBrowseView<RowContent: View, PageActions: View>: View {
    @State private var model: DiscoverBrowseModel
    @State private var libraryRevision = 0
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    private let isActive: Bool
    private let pageActions: PageActions
    private var navigationTitles = NavigationTitles()
    private let rowContent: (DiscoverFeed, [MediaItem], Bool, (@MainActor () async -> Void)?) -> RowContent

    public init(
        model: DiscoverBrowseModel,
        isActive: Bool = true,
        @ViewBuilder pageActions: () -> PageActions = { EmptyView() },
        @ViewBuilder rowContent: @escaping (DiscoverFeed, [MediaItem], Bool, (@MainActor () async -> Void)?) -> RowContent
    ) {
        _model = State(initialValue: model)
        self.isActive = isActive
        self.pageActions = pageActions()
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
                #elseif os(iOS)
                PlozziOSPageHeader(navigationTitles(NavigationLibraryLayout.discoverKey, default: Text("Discover"))) {
                    DiscoverFilterMenu(filters: $browse.filters)
                    pageActions
                }
                .padding(.horizontal, 16)
                #endif
                ForEach(model.visibleRows) { row in
                    let items = row.items.filter(model.filters.includes)
                    let showsPlaceholders = row.isLoading
                        || (items.isEmpty && row.nextPage != nil && row.error == nil)
                    VStack(alignment: .leading, spacing: 12) {
                        if items.isEmpty && !showsPlaceholders {
                            MediaRowHeader(title: Text(row.feed.title), leadingInset: horizontalInset)
                        } else {
                            rowContent(
                                row.feed, items, showsPlaceholders,
                                paginationAction(for: row)
                            )
                            .id(model.filters)
                        }
                        DiscoverRowFooter(
                            row: row, isEmpty: items.isEmpty,
                            isFiltered: model.filters.activeCount > 0,
                            isActive: isActive,
                            onClearFilters: { model.filters = .init() },
                            onLoadMore: { await model.loadMore(row.feed) }
                        )
                        .padding(.leading, horizontalInset + navigationInset)
                        .padding(.trailing, horizontalInset)
                    }
                    .accessibilityIdentifier("discover-row-\(row.feed.rawValue)")
                }
            }
            .padding(.top, topPadding)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
        .scrollsTopNavigation()
        #if os(iOS)
        .navigationTitle(Text(verbatim: ""))
        .toolbarTitleDisplayMode(.inline)
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
            else if isActive { Task { await model.load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) { model.applyWatchedState(mutation) }
        }
        .accessibilityIdentifier("discover-page")
    }

    private func paginationAction(for row: DiscoverRow) -> (@MainActor () async -> Void)? {
        guard row.items.contains(where: model.filters.includes) else { return nil }
        return {
            if isActive { await model.loadMoreVisibleItems(row.feed) }
        }
    }

    private var horizontalInset: CGFloat {
        #if os(tvOS)
        PlozzTheme.Metrics.screenPadding
        #else
        20
        #endif
    }

    private var topPadding: CGFloat {
        #if os(iOS)
        8
        #else
        24
        #endif
    }
}

private struct DiscoverRowFooter: View {
    let row: DiscoverRow
    let isEmpty: Bool
    let isFiltered: Bool
    let isActive: Bool
    let onClearFilters: () -> Void
    let onLoadMore: () async -> Void
    @State private var request = 0
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = row.error {
                Text(error.userMessage).foregroundStyle(.secondary)
                Button("Try Again") { request &+= 1 }
                    .plozzPageActionButton(role: .secondary)
            } else if !row.isLoading, row.nextPage == nil {
                if isEmpty {
                    if isFiltered {
                        Text("No titles match these filters.").foregroundStyle(.secondary)
                        Button("Clear Filters", action: onClearFilters)
                            .plozzPageActionButton(role: .secondary)
                    } else {
                        Text("No titles yet.").foregroundStyle(.secondary)
                    }
                }
            } else if isEmpty, row.nextPage != nil {
                Color.clear.frame(height: 1)
            }
        }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .task(id: emptyPage) {
            if emptyPage != nil { await onLoadMore() }
        }
        .task(id: request) {
            if request > 0 {
                await onLoadMore()
                request = 0
            }
        }
    }

    private var emptyPage: Int? {
        isActive && isVisible && isEmpty && row.error == nil && row.nextPage != 1 ? row.nextPage : nil
    }
}
