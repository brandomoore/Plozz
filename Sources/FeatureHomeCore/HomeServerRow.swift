import CoreModels

public struct HomeServerRow: Equatable, Sendable {
    public var definition: HomeServerRowDefinition
    public var items: [MediaItem]
    public var isLoading: Bool
    public var failure: AppError?
    public var hasMore: Bool
    public var browseID: String?

    public init(
        definition: HomeServerRowDefinition, items: [MediaItem] = [],
        isLoading: Bool = false, failure: AppError? = nil, hasMore: Bool = false, browseID: String? = nil
    ) {
        self.definition = definition
        self.items = items
        self.isLoading = isLoading
        self.failure = failure
        self.hasMore = hasMore
        self.browseID = browseID
    }

    public var row: HomeLibrarySectionGroup.Row {
        .init(
            section: LibrarySection(
                id: definition.id.presentationID,
                title: definition.section.title ?? definition.section.kind.rawValue,
                localizedTitle: definition.section.title == nil ? definition.section.kind.title : nil,
                style: definition.section.kind == .nextUp ? .landscape : .poster,
                items: items, browseID: browseID, hasMore: hasMore
            ),
            isLoading: isLoading, failure: failure
        )
    }
}
