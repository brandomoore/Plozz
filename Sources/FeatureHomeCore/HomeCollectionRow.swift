import CoreModels

public struct HomeCollectionRow: Equatable, Sendable {
    static func plannedDefinitions(
        accounts: [ResolvedAccount], visibility: HomeLibraryVisibility
    ) -> [CollectionSection] {
        visibility.collectionSections.filter {
            visibility.isHomeRowVisible(HomeRowChoice(collectionSection: $0))
                && !$0.availableSources(accounts: accounts, visibility: visibility).isEmpty
        }
    }

    public var definition: CollectionSection
    public var items: [MediaItem]
    public var isLoading: Bool
    public var failure: AppError?
    public var hasMore: Bool
    public var sourceItems: [HomeContentSource: [MediaItem]] = [:]
    public var sourceFailures: [HomeContentSource.ID: AppError] = [:]
    public var continuingSources: Set<HomeContentSource.ID> = []

    public init(
        definition: CollectionSection, items: [MediaItem] = [],
        isLoading: Bool = false, failure: AppError? = nil, hasMore: Bool = false
    ) {
        self.definition = definition
        self.items = items
        self.isLoading = isLoading
        self.failure = failure
        self.hasMore = hasMore
    }

    func resolving(
        home: [HomeGlobalRow: [MediaItem]], visibility: HomeLibraryVisibility, limit: Int = 20,
        force: Bool = false, serverInfo: [String: SourceServerInfo] = [:],
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) -> Self {
        guard !sourceItems.isEmpty, force || definition.sources.contains(where: { $0.home != nil }) else { return self }
        var row = self
        let groups = definition.sources.map { source -> [MediaItem] in
            guard source.libraryKey.map(visibility.isEnabled) != false else { return [] }
            if let kind = source.home, let items = home[kind] {
                return Array(items.prefix(limit + 1))
            }
            return sourceItems[source] ?? []
        }
        let interleaved = HomeAggregator.interleave(groups)
        let merged = definition.sources.count == 1 ? interleaved
            : MediaItemMerger.merge(interleaved, serverInfo: { serverInfo[$0] }, identitySources: identitySources)
        row.items = Array(merged.prefix(limit))
        row.hasMore = !continuingSources.isEmpty || merged.count > limit
        return row
    }

    public var row: HomeLibrarySectionGroup.Row {
        .init(
            section: LibrarySection(
                id: definition.rowID.presentationID, title: definition.title,
                style: definition.cardStyle == .poster ? .poster : .landscape, items: items, hasMore: hasMore
            ),
            isLoading: isLoading, failure: failure, browseItem: definition.collectionItem,
            collectionCardStyle: definition.cardStyle
        )
    }
}
