import Foundation

/// Read-only server evidence for an explicitly selected user and library.
@MainActor
public final class TrackerServerHistorySource {
    public let scope: WatchMutationServerScope
    public let accounts: [TrackerHistoryImportSession.Destination]
    private let resolveProvider: @MainActor @Sendable (String) throws -> any MediaProvider
    private let isAuthorized: @MainActor @Sendable () -> Bool
    private let isPlaying: @MainActor @Sendable (String, String) async -> Bool

    public init(
        scope: WatchMutationServerScope, accounts: [TrackerHistoryImportSession.Destination],
        resolveProvider: @escaping @MainActor @Sendable (String) throws -> any MediaProvider,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool,
        isPlaying: @escaping @MainActor @Sendable (String, String) async -> Bool
    ) {
        self.scope = scope
        self.accounts = accounts
        self.resolveProvider = resolveProvider
        self.isAuthorized = isAuthorized
        self.isPlaying = isPlaying
    }

    public func requireCurrent() throws {
        try Task.checkCancellation()
        guard isAuthorized() else { throw TrackerHistoryError.scopeChanged }
    }

    private func provider(_ accountID: String) throws -> any MediaProvider {
        try requireCurrent()
        guard scope.accounts.contains(where: { $0.accountID == accountID }) else {
            throw TrackerHistoryError.scopeChanged
        }
        return try resolveProvider(accountID)
    }

    public func libraries(accountID: String) async throws -> [MediaLibrary] {
        let libraries = try await provider(accountID).libraries()
        try requireCurrent()
        guard Set(libraries.map(\.id)).count == libraries.count,
              libraries.allSatisfy({ !$0.id.isEmpty && ($0.sourceAccountID == nil || $0.sourceAccountID == accountID) })
        else { throw TrackerHistoryError.incompleteSnapshot }
        return libraries.filter { !$0.isMusic && ($0.kind == .movie || $0.kind == .series) }
    }

    public func items(
        accountID: String, library: MediaLibrary,
        progress: @MainActor (Int) -> Void = { _ in }
    ) async throws -> [MediaItem] {
        guard try await libraries(accountID: accountID).contains(where: {
            $0.id == library.id && $0.kind == library.kind
        }) else { throw TrackerHistoryError.stalePreview }
        let provider = try provider(accountID)
        let kind: MediaItemKind = library.kind == .series ? .episode : .movie
        var items: [MediaItem] = []
        var ids = Set<String>()
        var total: Int?
        while true {
            try requireCurrent()
            let page = try await provider.items(
                in: library.id, kind: kind, page: .init(startIndex: items.count, limit: 200)
            )
            try requireCurrent()
            guard page.startIndex == items.count, (0...50_000).contains(page.totalCount),
                  total == nil || total == page.totalCount,
                  page.items.count <= 200, page.endIndex <= page.totalCount,
                  page.items.allSatisfy({
                      !$0.id.isEmpty && $0.kind == kind && ids.insert($0.id).inserted
                          && ($0.sourceAccountID == nil || $0.sourceAccountID == accountID)
                  }) else { throw TrackerHistoryError.incompleteSnapshot }
            total = page.totalCount
            if page.items.isEmpty {
                guard items.count == total else { throw TrackerHistoryError.incompleteSnapshot }
                return items
            }
            items += page.items
            progress(items.count)
            // Probe the advertised end too: a provider's fallback page count is
            // not evidence that an unexpectedly truncated inventory is complete.
        }
    }

    public func item(accountID: String, itemID: String) async throws -> MediaItem {
        let provider = try provider(accountID)
        return try await Self.freshItem(
            provider: provider, accountID: accountID, itemID: itemID,
            validate: { try self.requireCurrent() }
        )
    }

    public func requireNotPlaying(accountID: String, itemID: String) async throws {
        try requireCurrent()
        let playing = await isPlaying(accountID, itemID)
        try requireCurrent()
        guard !playing else { throw AppError.conflict }
    }

    static func freshItem(
        provider: any MediaProvider, accountID: String, itemID: String,
        validate: @MainActor () throws -> Void
    ) async throws -> MediaItem {
        try validate()
        var item = try await provider.item(id: itemID)
        try validate()
        guard item.id == itemID, item.sourceAccountID == nil || item.sourceAccountID == accountID else {
            throw AppError.invalidResponse
        }
        if item.kind == .episode, let seriesID = item.seriesID {
            let series = try await provider.item(id: seriesID)
            try validate()
            guard series.id == seriesID, series.kind == .series,
                  series.sourceAccountID == nil || series.sourceAccountID == accountID else {
                throw AppError.invalidResponse
            }
            item.providerIDs.mergeSeriesProviderIDs(from: series.providerIDs)
            if item.episodeOrdering == nil { item.episodeOrdering = series.episodeOrdering }
        }
        return item
    }
}
