#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore

/// A full-grid root for Plozz's universal Watchlist.
///
/// It shares Home's retained model, so opening this destination never creates a
/// second provider fetch or a second interpretation of cross-provider membership.
public struct WatchlistBrowseView: View {
    private let viewModel: HomeViewModel
    private let visibility: HomeLibraryVisibility
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    @State private var watchlistIntentRevision = 0
    @Environment(\.mediaItemActionHandler) private var mediaItemActionHandler
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset

    public init(
        viewModel: HomeViewModel,
        visibility: HomeLibraryVisibility,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.viewModel = viewModel
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }

    public var body: some View {
        @Bindable var browse = viewModel.watchlistBrowse
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                HStack {
                    Text("Watchlist")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("watchlist-title")
                    Spacer(minLength: PlozzTheme.Spacing.large)
                    WatchlistBrowseControls(preferences: $browse.preferences)
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, HomeLayout.horizontalPadding)
                .focusSection()

                ContentStateView(
                    state: viewModel.state,
                    emptyMessage: "Your Watchlist is empty.",
                    onRetry: { Task { await viewModel.load() } },
                    loadingContent: {
                        watchlistContent(
                            [],
                            loadingPlaceholderCount: max(metrics.posterColumns.count * 2, 6)
                        )
                    }
                ) { content in
                    watchlistContent(
                        content.watchlist,
                        loadingPlaceholderCount: viewModel.watchlistLoadingPlaceholderCount
                    )
                }
            }
            .padding(.top, PlozzTheme.Spacing.large)
        }
        .scrollClipDisabled()
        .scrollsTopNavigation()
        .environment(\.plozzCardCaptionView, .watchlist)
        .task(id: visibility) {
            await viewModel.loadIfNeeded(for: visibility)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistDidChange
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistCacheDidLoad
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistLoadingProgressDidChange
            )
        ) { _ in
            viewModel.refreshWatchlistLoadingProgress()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .watchlistIntentDidChange
            )
        ) { _ in
            watchlistIntentRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaItemDidMutate)
        ) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
        .onMoveCommand { _ in
            viewModel.noteHomeNavigationInteraction()
        }
    }

    @ViewBuilder
    private func watchlistContent(
        _ items: [MediaItem],
        loadingPlaceholderCount: Int
    ) -> some View {
        let filteredItems = viewModel.watchlistBrowse.preferences.items(from: items)
        if filteredItems.isEmpty, loadingPlaceholderCount == 0 {
            WatchlistEmptyStateView(isFiltered: !items.isEmpty) {
                viewModel.watchlistBrowse.preferences.filter = .all
            }
        } else {
            LazyVGrid(columns: metrics.posterColumns, spacing: metrics.gridSpacing) {
                ForEach(MediaRowView.presentationElements(
                    items: filteredItems,
                    loadingPlaceholderCount: loadingPlaceholderCount
                )) { element in
                    switch element {
                    case .item(let item):
                        PosterCardView(
                            item: item,
                            style: .poster,
                            spoilerSettings: spoilerSettings,
                            isPendingRemoval: isPendingRemoval(item)
                        ) {
                            onSelect(item)
                        }
                        .navigationEntryFocus(.content)
                    case .loadingPlaceholder:
                        SkeletonCardView(style: .poster)
                    }
                }
            }
            .padding(.leading, contentLeadingPadding)
            .padding(.trailing, HomeLayout.horizontalPadding)
            .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
            .focusSection()
            .accessibilityIdentifier("watchlist-grid")
        }
    }

    private var contentLeadingPadding: CGFloat {
        HomeLayout.horizontalPadding
            + navigationContentInset
            + (navigationContentInset > 0 ? 16 : 0)
    }

    private func isPendingRemoval(_ item: MediaItem) -> Bool {
        _ = watchlistIntentRevision
        guard let mediaItemActionHandler else { return false }
        return mediaItemActionHandler
            .isActivelyRemovingFromWatchlist(item)
    }
}

#endif
