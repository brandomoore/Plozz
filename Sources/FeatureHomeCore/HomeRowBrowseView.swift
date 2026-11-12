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
    #if os(tvOS)
    @Namespace private var entryFocusScope
    @State private var hasResolvedEntryFocus = false
    #endif
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
                    .disabled(awaitsGridEntry)
                }
                .lineLimit(1)
                .focusSection()
                #endif
                if model.query == model.appliedQuery {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                        ForEach(model.items, id: \.stablePresentationID) { item in
                            card(item)
                                #if os(tvOS)
                                .disabled(!hasResolvedEntryFocus && item.stablePresentationID != model.items.first?.stablePresentationID)
                                .prefersDefaultFocus(
                                    !hasResolvedEntryFocus && item.stablePresentationID == model.items.first?.stablePresentationID,
                                    in: entryFocusScope
                                )
                                #endif
                                .onAppear {
                                    if item.stablePresentationID == model.items.last?.stablePresentationID,
                                       model.hasMore, !model.isLoading, model.error == nil {
                                        moreRequest += 1
                                    }
                                }
                        }
                    }
                    #if os(tvOS)
                    .background {
                        NativeFocusRegionObserver(isEnabled: !hasResolvedEntryFocus) { hasResolvedEntryFocus = true }
                    }
                    #endif
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
                        #if os(tvOS)
                        .disabled(awaitsGridEntry)
                        #endif
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
        #if os(tvOS)
        .focusScope(entryFocusScope)
        .background {
            NativeFocusRegionObserver(isEnabled: !hasResolvedEntryFocus && !awaitsGridEntry) {
                hasResolvedEntryFocus = true
            }
        }
        #endif
        #if os(iOS)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortControl.labelStyle(.iconOnly)
                filterControl.labelStyle(.iconOnly)
            }
        }
        #endif
    }

    #if os(tvOS)
    private var awaitsGridEntry: Bool {
        !hasResolvedEntryFocus && model.error == nil && (model.isLoading || model.hasMore || !model.items.isEmpty)
    }
    #endif

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
        Menu {
            HomeContentSortOptions(query: $model.query)
        } label: {
            Label {
                Text(model.query.sortTitle)
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #endif
        }
        .accessibilityLabel(Text("Sort: \(model.query.sortTitle)"))
        .accessibilityIdentifier("home-row-sort-menu")
    }

    private var filterControl: some View {
        BrowseFilterMenu(
            activeCount: model.query.activeFilterCount,
            summary: model.query.filterSummary(in: locale)
        ) {
            HomeContentFilterOptions(query: $model.query)
        }
        .accessibilityIdentifier("home-row-filter-menu")
    }

}
