import CoreModels

/// A concrete server collection's members. A native Collections library is a
/// `MediaLibrary`, never this route, even though both use the collection kind.
public struct CollectionBrowseRoute: Hashable, Sendable {
    public let collectionID: String
    public let title: String // l10n:content — collection name from the server
    public let accountID: String?

    public init?(item: MediaItem, fallbackAccountID: String? = nil) {
        guard item.kind == .collection else { return nil }
        collectionID = item.id
        title = item.title
        accountID = item.sourceAccountID ?? fallbackAccountID
    }
}
