import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import MetadataKit

@MainActor
extension UniversalWatchlistHost {
    public var upcomingAccounts: [ResolvedAccount] {
        let resolved = accountsProviders.resolvedActiveAccounts
        guard let chosen = profiles.storedActiveAccountIDs(for: profiles.activeProfileID) else {
            return resolved
        }
        let selected = Set(chosen)
        return resolved.filter { selected.contains($0.account.id) }
    }
}

public enum UpcomingFeedLoader {
    public static func scopeKey(
        profileID: String, accounts: [ResolvedAccount],
        requestIdentity: SeerRequestIdentity, connectionRevision: UUID,
        language: String, regionCode: String?
    ) -> String {
        let sources = accounts.map {
            [
                $0.account.id, $0.account.server.id, $0.account.server.baseURL.absoluteString,
                $0.account.userID, $0.plexHomeUserID ?? "",
                $0.credentialRevision.rawValue.uuidString,
            ].map { "\($0.utf8.count):\($0)" }.joined()
        }.sorted().joined(separator: "|")
        return [
            profileID, sources, String(describing: requestIdentity),
            connectionRevision.uuidString, language, regionCode ?? "",
        ].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public static func window(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        return DateInterval(
            start: calendar.date(byAdding: .day, value: -30, to: today)!,
            end: calendar.date(byAdding: .day, value: 91, to: today)!
        )
    }

    public static func load(
        accounts: [ResolvedAccount], watchlist: [MediaItem], regionCode: String?,
        interval: DateInterval,
        requestedMovies: @escaping @Sendable () async throws -> [MediaItem],
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        schedule: @escaping @Sendable (MediaItem, DateInterval) async throws -> [UpcomingEpisode] = {
            try await SeriesScheduleResolver.shared.calendarEpisodes(for: MetadataQuery($0), in: $1)
        },
        movieAvailability: @escaping @Sendable (MediaItem, String) async -> ExternalTitleAvailability = {
            await ExternalTitleMetadataResolver.shared.availability(for: $0, regionCode: $1)
        }
    ) async throws -> UpcomingFeedSnapshot {
        let watched = await map(accounts) { account -> (items: [MediaItem], failed: Bool) in
            do {
                return try await watchedSeries(account: account, isCurrent: isCurrent)
            } catch is CancellationError {
                return ([], false)
            } catch {
                PlozzLog.networking.error("Upcoming viewing history could not be refreshed")
                return ([], true)
            }
        }
        try await checkScope(isCurrent)
        var requests: [MediaItem] = []
        var failures = watched.filter(\.failed).count
        var requestsFailed = false
        do {
            requests = try await requestedMovies().filter { $0.kind == .movie }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            PlozzLog.networking.error("Upcoming personal requests could not be refreshed")
            failures += 1
            requestsFailed = true
        }
        try await checkScope(isCurrent)
        let shows = MediaItemMerger.merge(watched.flatMap(\.items))
        let savedMovies = watchlist.filter { $0.kind == .movie }
        let movies = MediaItemMerger.merge(savedMovies + requests)
        let requested = requests
        let titles = shows + movies
        let batches = await map(titles) { item -> (releases: [UpcomingRelease], failed: Bool) in
            guard !Task.isCancelled, await isCurrent() else { return ([], false) }
            do {
                if item.kind == .series {
                    let episodes = try await schedule(item, interval)
                    return (UpcomingReleaseBuilder.episodes(episodes, for: item), false)
                }
                guard let regionCode else { return ([], false) }
                var interests = Set<UpcomingInterest>()
                if savedMovies.contains(where: { sameTitle($0, item) }) { interests.insert(.watchlist) }
                if requested.contains(where: { sameTitle($0, item) }) { interests.insert(.requested) }
                let availability = await movieAvailability(item, regionCode)
                guard availability.releaseDatesAvailable != false else { throw AppError.notFound }
                return (
                    UpcomingReleaseBuilder.movies(
                        availability.releaseEvents.filter { $0.date >= interval.start && $0.date < interval.end },
                        for: item, interests: interests, regionCode: regionCode
                    ), false
                )
            } catch is CancellationError {
                return ([], false)
            } catch {
                PlozzLog.networking.error("Upcoming release dates could not be refreshed")
                return ([], true)
            }
        }
        try await checkScope(isCurrent)
        let failedAccounts = Set(
            zip(accounts, watched).compactMap { account, result in
                result.failed ? account.account.id : nil
            })
        return UpcomingFeedSnapshot(
            releases: batches.flatMap(\.releases), failedSourceCount: failures + batches.filter(\.failed).count,
            failedAccountIDs: failedAccounts, requestsFailed: requestsFailed,
            failedTitleKeys: Set(
                zip(titles, batches).compactMap { item, batch in
                    batch.failed ? UpcomingRelease.titleKey(for: item) : nil
                })
        )
    }

    static func sameTitle(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        let left = MediaItemIdentity.identities(for: lhs)
        let right = MediaItemIdentity.identities(for: rhs)
        guard !MediaItemIdentity.externalIdentitiesConflict(left, right) else { return false }
        return lhs.stablePresentationID == rhs.stablePresentationID || !Set(left).isDisjoint(with: right)
    }

    private static func watchedSeries(
        account: ResolvedAccount,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> (items: [MediaItem], failed: Bool) {
        try await checkScope(isCurrent)
        let libraries = try await account.provider.libraries()
        var series: [MediaItem] = []
        var failed = false
        for library in libraries where library.kind == .series || library.kind == .folder || library.kind == .unknown {
            do {
                var offset = 0
                var seen = Set<String>()
                while true {
                    try await checkScope(isCurrent)
                    let page = try await account.provider.items(
                        in: library.id, kind: .series, page: PageRequest(startIndex: offset, limit: 200)
                    )
                    try await checkScope(isCurrent)
                    guard page.startIndex == offset,
                        !page.items.isEmpty || !page.hasMore
                    else { throw AppError.invalidResponse }
                    for var item in page.items {
                        guard seen.insert(item.id).inserted else { throw AppError.invalidResponse }
                        guard item.kind == .series,
                            item.hasBeenPlayed || item.isPlayed
                                || (item.playedPercentage ?? 0) > 0 || (item.resumePosition ?? 0) > 0
                        else { continue }
                        item.sourceAccountID = account.account.id
                        item.libraryID = library.id
                        series.append(item)
                    }
                    if !page.hasMore { break }
                    guard page.endIndex > offset else { throw AppError.invalidResponse }
                    offset = page.endIndex
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed = true
                PlozzLog.networking.error("Upcoming library history could not be refreshed")
            }
        }
        // A first unfinished episode may not increment a container's completed
        // episode count yet. History above still retains caught-up series.
        try await checkScope(isCurrent)
        do {
            let continuing = try await account.provider.continueWatching(limit: 200, inLibraries: nil)
            var known = Set(series.map(\.id))
            for episode in continuing where episode.kind == .episode {
                guard let id = episode.seriesID, known.insert(id).inserted else { continue }
                try await checkScope(isCurrent)
                var item = try await account.provider.item(id: id)
                guard item.kind == .series else { continue }
                item.sourceAccountID = account.account.id
                series.append(item)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failed = true
            PlozzLog.networking.error("Upcoming in-progress history could not be refreshed")
        }
        try await checkScope(isCurrent)
        return (series, failed)
    }

    private static func checkScope(_ isCurrent: @MainActor @Sendable () -> Bool) async throws {
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
    }

    private static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var results: [(Int, Output)] = []
            for index in inputs.indices.prefix(4) {
                group.addTask { (index, await operation(inputs[index])) }
                next += 1
            }
            while let result = await group.next() {
                results.append(result)
                if next < inputs.count, !Task.isCancelled {
                    let index = next
                    group.addTask { (index, await operation(inputs[index])) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
