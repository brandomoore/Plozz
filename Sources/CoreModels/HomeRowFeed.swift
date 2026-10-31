import Foundation

public enum HomeRowFeed: Sendable {
    case latest(libraryIDs: [String]?)
    case nextUp(libraryID: String)
    case recommendation(libraryID: String, kind: MediaItemKind, browseID: String, anchorIDs: [String] = [])
    case server(ServerHomeSection, excludedLibraryIDs: Set<String>, anchorIDs: [String])
}

public struct HomeRowPage: Sendable {
    public let items: [MediaItem]
    public let nextOffset: Int?

    public init(items: [MediaItem], nextOffset: Int?) {
        self.items = items
        self.nextOffset = nextOffset
    }

    public init(_ page: MediaPage) throws {
        guard page.startIndex >= 0, page.totalCount >= page.endIndex,
              !page.items.isEmpty || page.startIndex >= page.totalCount else {
            throw AppError.invalidResponse
        }
        items = page.items
        nextOffset = page.endIndex < page.totalCount ? page.endIndex : nil
    }

    /// Limit-only feeds are extended on demand; a fixed server shelf ends when
    /// it returns no lookahead item. Never substitute a different library query.
    public static func prefix(_ items: [MediaItem], startIndex: Int, limit: Int) -> Self {
        let end = startIndex + limit
        return Self(
            items: Array(items.dropFirst(startIndex).prefix(limit)),
            nextOffset: items.count > end ? end : nil
        )
    }
}

public extension MediaProvider {
    func homeRowPage(_ feed: HomeRowFeed, startIndex: Int, limit: Int) async throws -> HomeRowPage {
        try await homeRowPrefixPage(feed, startIndex: startIndex, limit: limit)
    }

    func homeRowPrefixPage(_ feed: HomeRowFeed, startIndex: Int, limit: Int) async throws -> HomeRowPage {
        guard startIndex >= 0, limit > 0, limit <= PageRequest.defaultLimit,
              startIndex < Int.max - limit else { throw AppError.invalidResponse }
        let count = startIndex + limit + 1
        let items: [MediaItem]
        switch feed {
        case let .latest(libraries):
            items = try await latest(limit: count, inLibraries: libraries)
        case let .nextUp(library):
            items = try await homeNextUp(libraryID: library, limit: count)
        case let .recommendation(library, kind, browseID, anchors):
            let shelves = try await homeHubs(
                libraryID: library, kind: kind, limit: count, includeUnpromoted: true
            )
            guard let shelf = shelves.first(where: {
                $0.browseID == browseID && Set(anchors).isSubset(of: Set($0.items.map(\.id)))
            }) else {
                throw AppError.notFound
            }
            items = shelf.items
        case let .server(section, excluded, _):
            items = try await serverHomeItems(section: section, limit: count, excludingLibraryIDs: excluded)
        }
        try Task.checkCancellation()
        return .prefix(items, startIndex: startIndex, limit: limit)
    }
}
