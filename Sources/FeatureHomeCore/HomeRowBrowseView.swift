import CoreModels
import CoreUI
import SwiftUI

/// Both shells supply their normal cards and navigation; membership and controls
/// are shared so a Home shelf means the same thing on either platform.
public struct HomeRowBrowseView<Card: View>: View {
    @Bindable private var model: HomeRowBrowseModel
    private let columns: [GridItem]
    private let card: (MediaItem) -> Card
    @Environment(\.locale) private var locale
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @State private var moreRequest = 0
    private struct LoadKey: Equatable {
        let query: HomeRowBrowseQuery
        let snapshot: [MediaItem]?
    }

    public init(
        model: HomeRowBrowseModel, columns: [GridItem],
        @ViewBuilder card: @escaping (MediaItem) -> Card
    ) {
        self.model = model
        self.columns = columns
        self.card = card
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                #if os(tvOS)
                HStack {
                    heading
                        .layoutPriority(1)
                    Spacer(minLength: PlozzTheme.Spacing.large)
                    BrowseQueryControls {
                        filterControl
                        sortControl.fixedSize(horizontal: true, vertical: false)
                    }
                }
                .lineLimit(1)
                .focusSection()
                #else
                heading
                #endif
                if model.query == model.appliedQuery {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                        ForEach(model.items, id: \.stablePresentationID) { item in
                            card(item)
                                .onAppear {
                                    if item.stablePresentationID == model.items.last?.stablePresentationID,
                                       model.hasMore, !model.isLoading, model.error == nil {
                                        moreRequest += 1
                                    }
                                }
                        }
                    }
                }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error.userMessage)
                        Button("Retry") { moreRequest += 1 }
                    }
                } else if model.isLoading || model.query != model.appliedQuery {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if model.hasMore {
                    Button("Load more") { moreRequest += 1 }
                        .onAppear { moreRequest += 1 }
                } else if model.items.isEmpty {
                    Text("No titles to show")
                        .plozzForeground(.secondary)
                }
            }
            .padding(.leading, horizontalPadding + navigationInset)
            .padding(.trailing, horizontalPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("home-row-browser")
        .task(id: LoadKey(query: model.query, snapshot: model.liveSnapshot)) { await model.load() }
        .task(id: moreRequest) {
            guard moreRequest > 0, !model.isLoading else { return }
            await model.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) {
            if let mutation = MediaItemMutation.from($0) { model.applyMutation(mutation) }
        }
        .onChange(of: model.scopeIsCurrent) { _, current in if !current { model.invalidate() } }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortControl.labelStyle(.iconOnly)
                filterControl.labelStyle(.iconOnly)
            }
        }
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        PlozzTheme.Metrics.screenPadding
        #else
        20
        #endif
    }

    private var title: Text {
        if let localized = model.localizedTitle {
            if let suffix = model.titleSuffix { return Text(localized) + Text(verbatim: suffix) }
            return Text(localized)
        }
        return Text(verbatim: model.title)
    }

    private var heading: some View {
        title.font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home-row-browser-title")
    }

    private var sortControl: some View {
        BrowseSortMenu(
            sort: model.query.sort ?? .default,
            fields: [.name, .dateAdded, .releaseDate, .runtime],
            isDefault: model.query.sort == nil,
            onReset: { model.query.sort = nil },
            onChange: { model.query.sort = $0 }
        )
        .accessibilityIdentifier("home-row-sort-menu")
    }

    private var filterControl: some View {
        BrowseFilterMenu(
            activeCount: model.query.filters.activeCount + (model.query.media == .all ? 0 : 1),
            summary: filterSummary
        ) {
            Picker("Filter", selection: $model.query.media) {
                ForEach(WatchlistMediaFilter.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Filter", selection: $model.query.filters.filter) {
                Text("All").tag(LibraryFilter.all)
                Text("Unwatched").tag(LibraryFilter.unwatched)
                Text("In Progress").tag(LibraryFilter.inProgress)
            }
        }
        .accessibilityIdentifier("home-row-filter-menu")
    }

    private var filterSummary: String {
        var labels = [model.query.filters.summary(in: locale)].filter { !$0.isEmpty }
        if model.query.media != .all {
            var title = model.query.media.displayName
            title.locale = locale
            labels.insert(String(localized: title), at: 0) // l10n:content — existing localized filter choice
        }
        return labels.joined(separator: " · ")
    }
}
