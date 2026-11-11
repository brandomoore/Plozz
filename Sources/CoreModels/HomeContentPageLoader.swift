import Foundation

@MainActor
public protocol HomeContentSnapshotProviding: Sendable {
    func contentSnapshot(for kind: HomeGlobalRow, visibility: HomeLibraryVisibility) throws -> [MediaItem]
}

public enum HomeContentPageLoader {
    public typealias HomeSnapshot = @Sendable (HomeGlobalRow) async throws -> [MediaItem]

    /// Pins snapshot feeds and recommendation identity for one preview/browse
    /// traversal. A later Home refresh creates a new session.
    public actor Session {
        private let accounts: [ResolvedAccount]
        private let visibility: HomeLibraryVisibility
        private let homeSnapshot: HomeSnapshot
        private var snapshots: [HomeGlobalRow: [MediaItem]] = [:]
        private var recommendations: [HomeContentSource.ID: LibrarySection] = [:]
        private struct RecommendationKey: Hashable {
            let accountID: String
            let libraryID: String
            let kind: MediaItemKind
        }
        private struct RecommendationCatalog {
            let gate = ConcurrencyLimiter(limit: 1)
            var shelves: [LibrarySection]?
        }
        private var recommendationCatalogs: [RecommendationKey: RecommendationCatalog] = [:]
        private struct PageKey: Hashable { let source: HomeContentSource.ID; let start: Int; let limit: Int }
        private var pages: [PageKey: HomeRowPage] = [:]
        private let cachesPages: Bool

        public init(
            accounts: [ResolvedAccount], visibility: HomeLibraryVisibility, cachesPages: Bool = false,
            homeSnapshot: @escaping HomeSnapshot
        ) {
            self.accounts = accounts
            self.visibility = visibility
            self.homeSnapshot = homeSnapshot
            self.cachesPages = cachesPages
        }

        public func load(_ source: HomeContentSource, start: Int, limit: Int) async throws -> HomeRowPage {
            guard start >= 0, limit > 0, limit <= PageRequest.defaultLimit, start < Int.max - limit else {
                throw AppError.invalidResponse
            }
            guard source.isAvailable(accounts: accounts, visibility: visibility) else { throw AppError.notFound }
            try Task.checkCancellation()
            let key = PageKey(source: source.id, start: start, limit: limit)
            if let page = pages[key] { return page }
            if case let .recommendation(id, kind) = source.feed,
               id != LibraryHomeRowKind.recentlyAdded.rawValue, id != LibraryHomeRowKind.nextUp.rawValue,
               recommendations[source.id] == nil {
                guard let account = accounts.first(where: source.matches), let library = source.libraryID else {
                    throw AppError.notFound
                }
                let catalogKey = RecommendationKey(accountID: account.account.id, libraryID: library, kind: kind)
                let catalog = recommendationCatalogs[catalogKey] ?? RecommendationCatalog()
                recommendationCatalogs[catalogKey] = catalog
                let shelves = try await catalog.gate.runUnlessCancelled {
                    try await self.recommendationCatalog(catalogKey, provider: account.provider)
                }
                try Task.checkCancellation()
                guard let shelf = shelves.first(where: { $0.id == id }) else {
                    recommendationCatalogs[catalogKey]?.shelves = nil
                    throw AppError.notFound
                }
                recommendations[source.id] = shelf
            }
            let page = try await HomeContentPageLoader.load(
                source, start: start, limit: limit, accounts: accounts, visibility: visibility,
                recommendation: recommendations[source.id], homeSnapshot: { try await self.snapshot($0) }
            )
            try Task.checkCancellation()
            if cachesPages { pages[key] = page }
            return page
        }

        private func recommendationCatalog(
            _ key: RecommendationKey, provider: any MediaProvider
        ) async throws -> [LibrarySection] {
            if let shelves = recommendationCatalogs[key]?.shelves { return shelves }
            let shelves = try await provider.homeHubs(
                libraryID: key.libraryID, kind: key.kind, limit: 20, includeUnpromoted: true
            )
            try Task.checkCancellation()
            recommendationCatalogs[key]?.shelves = shelves
            return shelves
        }

        private func snapshot(_ kind: HomeGlobalRow) async throws -> [MediaItem] {
            if let items = snapshots[kind] { return items }
            let items = try await homeSnapshot(kind)
            try Task.checkCancellation()
            snapshots[kind] = items
            return items
        }
    }

    public static func load(
        _ source: HomeContentSource, start: Int, limit: Int,
        accounts: [ResolvedAccount], visibility: HomeLibraryVisibility,
        recommendation: LibrarySection? = nil, homeSnapshot: HomeSnapshot
    ) async throws -> HomeRowPage {
        try Task.checkCancellation()
        guard start >= 0, limit > 0, limit <= PageRequest.defaultLimit, start < Int.max - limit else {
            throw AppError.invalidResponse
        }
        guard source.isAvailable(accounts: accounts, visibility: visibility) else { throw AppError.notFound }
        if let home = source.home {
            return .prefix(try await homeSnapshot(home), startIndex: start, limit: limit)
        }
        guard let account = accounts.first(where: source.matches) else { throw AppError.notFound }
        let provider = account.provider
        let request = PageRequest(startIndex: start, limit: limit)
        let page: HomeRowPage
        func checked(_ result: MediaPage) throws -> HomeRowPage {
            guard result.startIndex == start, result.items.count <= limit else { throw AppError.invalidResponse }
            return try HomeRowPage(result)
        }
        switch source.feed {
        case let .collection(id):
            page = try checked(await provider.collectionMembers(of: id, page: request))
        case let .playlist(id):
            page = try checked(await provider.videoPlaylistMembers(of: id, page: request))
        case let .library(kind):
            guard let library = source.libraryID else { throw AppError.invalidResponse }
            page = try checked(await provider.items(in: library, kind: kind, page: request))
        case let .recommendation(id, kind):
            guard let library = source.libraryID else { throw AppError.invalidResponse }
            if id == LibraryHomeRowKind.recentlyAdded.rawValue {
                let result = try await provider.items(
                    in: library, kind: kind,
                    page: .init(startIndex: start, limit: limit, sort: .init(field: .dateAdded, direction: .descending))
                )
                page = try checked(result)
            } else if id == LibraryHomeRowKind.nextUp.rawValue {
                page = try await provider.homeRowPage(.nextUp(libraryID: library), startIndex: start, limit: limit)
            } else {
                if let recommendation,
                   recommendation.browseID == nil || recommendation.items.count > start + limit {
                    page = .prefix(recommendation.items, startIndex: start, limit: limit)
                } else if let recommendation, let browseID = recommendation.browseID {
                    page = try await provider.homeRowPage(
                        .recommendation(libraryID: library, kind: kind, browseID: browseID,
                                        anchorIDs: recommendation.items.map(\.id)), startIndex: start, limit: limit
                    )
                } else {
                    let shelves = try await provider.homeHubs(
                        libraryID: library, kind: kind, limit: start + limit + 1, includeUnpromoted: true
                    )
                    guard let shelf = shelves.first(where: { $0.id == id }) else { throw AppError.notFound }
                    page = .prefix(shelf.items, startIndex: start, limit: limit)
                }
            }
        case let .server(section):
            let excluded = Set(visibility.disabledKeys.compactMap { key -> String? in
                let prefix = account.account.id + ":"
                return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
            })
            page = try await provider.homeRowPage(
                .server(section, excludedLibraryIDs: section.isAccountWideHistory ? [] : excluded, anchorIDs: []),
                startIndex: start, limit: limit
            )
        case .home:
            throw AppError.invalidResponse
        }
        try Task.checkCancellation()
        guard page.nextOffset.map({ $0 > start }) ?? true,
              page.items.allSatisfy({ !$0.id.isEmpty }) else { throw AppError.invalidResponse }
        let isRecentlyAdded: Bool
        let isHistory: Bool
        switch source.feed {
        case let .recommendation(id, _):
            isRecentlyAdded = id == LibraryHomeRowKind.recentlyAdded.rawValue
            isHistory = false
        case let .server(section):
            isRecentlyAdded = section.kind == .recentlyAdded
            isHistory = section.isAccountWideHistory
        default: isRecentlyAdded = false; isHistory = false
        }
        let candidates = isRecentlyAdded && visibility.hideWatchedRecentlyAdded
            ? try await provider.recentlyAddedWatchState(page.items) : page.items
        let items = candidates.map {
            $0.taggingSource(account.account.id).taggingLibrary($0.libraryID ?? source.libraryID)
        }.filter {
            let supported = source.collection != nil ? [.movie, .series] : [MediaItemKind.movie, .series, .season, .episode]
            return supported.contains($0.kind)
                && (isHistory || $0.isVisibleOnHome(isLibraryVisible: visibility.isEnabled))
                && (!isRecentlyAdded || !visibility.hideWatchedRecentlyAdded || !HomeRecentlyAddedPolicy.isWatched($0))
        }
        return .init(items: items, nextOffset: page.nextOffset)
    }
}
