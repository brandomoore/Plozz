import CoreModels

public struct HomeCollectionRow: Equatable, Sendable {
    public var definition: CollectionSection
    public var items: [MediaItem]
    public var isLoading: Bool
    public var failure: AppError?
    public var hasMore: Bool

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
