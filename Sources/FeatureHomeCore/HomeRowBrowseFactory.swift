import CoreModels
import Foundation

@MainActor
enum HomeRowBrowseFactory {
    static func make(
        _ row: HomePresentationRow, accounts: [ResolvedAccount], visibility: HomeLibraryVisibility,
        libraries: [AggregatedLibrary] = [],
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        snapshotProvider: (@MainActor () -> [MediaItem]?)? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> HomeRowBrowseModel {
        var loaders: [HomeRowBrowseModel.PageLoader] = []
        var snapshot: [MediaItem] = []
        var title = row.choice.title
        var localizedTitle = row.choice.localizedTitle
        var titleSuffix: String?
        var mergesSources = false
        var isRecentlyAdded = false
        var watchlistDates = false

        func append(
            accountID: String, libraryID: String? = nil, history: Bool = false,
            recentlyAdded: Bool = false,
            fetch: @escaping @Sendable (any MediaProvider, Int, Int) async throws -> HomeRowPage
        ) {
            loaders.append { start, limit in
                guard let account = accounts.first(where: { $0.account.id == accountID }) else {
                    throw AppError.notFound
                }
                let page = try await fetch(account.provider, start, limit)
                let items = recentlyAdded && visibility.hideWatchedRecentlyAdded
                    ? try await account.provider.recentlyAddedWatchState(page.items) : page.items
                return HomeRowPage(
                    items: items.map { $0.taggingSource(accountID).taggingLibrary($0.libraryID ?? libraryID) }
                        .filter { history || $0.isVisibleOnHome(isLibraryVisible: visibility.isEnabled) },
                    nextOffset: page.nextOffset
                )
            }
        }

        switch row.source {
        case .home(let home):
            snapshot = home.items
            watchlistDates = home.kind == .watchlist
            if home.kind == .recentlyAdded {
                mergesSources = true
                isRecentlyAdded = true
                for account in accounts {
                    let hasDisabledLibraries = visibility.disabledKeys.contains { $0.hasPrefix(account.account.id + ":") }
                    let known = libraries.filter { $0.accountID == account.account.id }
                    append(accountID: account.account.id, recentlyAdded: true) {
                        provider, start, limit in
                        let allowed: [String]?
                        if !known.isEmpty {
                            allowed = known.filter { !$0.library.isMusic && visibility.isEnabled($0.key) }.map(\.library.id)
                        } else {
                            let discovered = try await provider.libraries()
                            allowed = discovered.isEmpty && !hasDisabledLibraries ? nil : discovered.filter {
                                !$0.isMusic && visibility.isEnabled("\(account.account.id):\($0.id)")
                            }.map(\.id)
                        }
                        if allowed?.isEmpty == true { return .init(items: [], nextOffset: nil) }
                        let page = try await provider.homeRowPage(
                            .latest(libraryIDs: allowed), startIndex: start, limit: limit
                        )
                        let allowedIDs = allowed.map(Set.init)
                        return .init(
                            items: page.items.filter { item in
                                item.libraryID.map { allowedIDs?.contains($0) ?? true } ?? true
                            },
                            nextOffset: page.nextOffset
                        )
                    }
                }
            }
        case .library(let libraryRow):
            let section = libraryRow.section
            title = section.title
            localizedTitle = section.localizedTitle
            titleSuffix = section.localizedTitleSuffix
            snapshot = section.items
            if let collection = row.choice.collectionSection {
                append(accountID: collection.source.accountID, libraryID: collection.source.libraryID) {
                    provider, start, limit in
                    let page = try await provider.collectionMembers(
                        of: collection.source.collectionID, page: .init(startIndex: start, limit: limit)
                    )
                    guard page.startIndex == start, page.items.count <= limit else { throw AppError.invalidResponse }
                    let result = try HomeRowPage(page)
                    return .init(
                        items: result.items.filter { $0.kind == .movie || $0.kind == .series },
                        nextOffset: result.nextOffset
                    )
                }
            } else if let server = row.choice.serverRow {
                isRecentlyAdded = server.section.kind == .recentlyAdded
                let excluded = Set(visibility.disabledKeys.compactMap {
                    $0.hasPrefix(server.accountID + ":") ? String($0.dropFirst(server.accountID.count + 1)) : nil
                })
                append(accountID: server.accountID, libraryID: server.section.libraryID,
                       history: server.section.isAccountWideHistory,
                       recentlyAdded: server.section.kind == .recentlyAdded) { provider, start, limit in
                    try await provider.homeRowPage(
                        .server(
                            server.section, excludedLibraryIDs: server.section.isAccountWideHistory ? [] : excluded,
                            anchorIDs: section.items.map(\.id)
                        ),
                        startIndex: start, limit: limit
                    )
                }
            } else if let library = row.choice.library {
                if section.id == LibraryHomeRowKind.recentlyAdded.rawValue {
                    isRecentlyAdded = true
                    append(accountID: library.accountID, libraryID: library.library.id, recentlyAdded: true) {
                        provider, start, limit in
                        let page = try await provider.items(
                            in: library.library.id, kind: library.library.kind,
                            page: .init(startIndex: start, limit: limit, sort: .init(field: .dateAdded, direction: .descending))
                        )
                        guard page.startIndex == start, page.items.count <= limit else { throw AppError.invalidResponse }
                        return try HomeRowPage(page)
                    }
                } else if section.id == LibraryHomeRowKind.nextUp.rawValue {
                    append(accountID: library.accountID, libraryID: library.library.id) { provider, start, limit in
                        try await provider.homeRowPage(
                            .nextUp(libraryID: library.library.id), startIndex: start, limit: limit
                        )
                    }
                } else if let browseID = section.browseID {
                    append(accountID: library.accountID, libraryID: library.library.id) { provider, start, limit in
                        try await provider.homeRowPage(
                            .recommendation(
                                libraryID: library.library.id, kind: library.library.kind, browseID: browseID,
                                anchorIDs: section.items.map(\.id)
                            ),
                            startIndex: start, limit: limit
                        )
                    }
                }
            }
        case .liveTV:
            break
        }
        let mergeSources = mergesSources
        let hidesWatched = isRecentlyAdded && visibility.hideWatchedRecentlyAdded
        let serverInfo = accounts.sourceServerInfo()
        let isAdmitted = visibility.isHomeRowVisible(row.choice)
            && row.choice.library.map { visibility.isEnabled($0.key) } != false
            && row.choice.collectionSection?.source.libraryKey.map(visibility.isEnabled) != false
        return HomeRowBrowseModel(
            title: title, localizedTitle: localizedTitle, titleSuffix: titleSuffix,
            snapshot: snapshot, loaders: loaders, snapshotProvider: snapshotProvider,
            watchlistDates: watchlistDates, isCurrent: { isAdmitted && isCurrent() }
        ) { groups in
            let items = mergeSources ? MediaItemMerger.merge(
                HomeAggregator.interleave(groups), serverInfo: { serverInfo[$0] }, identitySources: identitySources
            ) : groups.flatMap { $0 }
            return items.filter { !hidesWatched || !HomeRecentlyAddedPolicy.isWatched($0) }
        }
    }
}
