import CoreModels
import CoreNetworking
import Foundation

private func searchWithDeadline(
    _ provider: any MediaProvider,
    query: String,
    limit: Int,
    seconds: Double
) async -> [MediaItem] {
    let searchTask = Task {
        let items = (try? await provider.search(query: query, limit: limit)) ?? []
        guard provider.catalogIdentityRequiresEnrichment else { return items }
        let prepared = await IdentityEnrichment.prepare(items, enrichIdentifiedItems: true) { item in
            try await provider.item(id: item.id)
        }
        guard !Task.isCancelled else { return [] }
        if prepared.inconclusive {
            FanoutDiagnostics.emit("source.search incomplete identities provider=\(provider.kind.rawValue)")
        }
        let fullByID = Dictionary(
            prepared.indexable.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.compactMap { item in
            guard item.kind == .movie || item.kind == .series else { return item }
            guard var full = fullByID[item.id] else { return nil }
            full.libraryID = item.libraryID ?? full.libraryID
            full.sourceAccountID = item.sourceAccountID ?? full.sourceAccountID
            return full
        }
    }
    // Dispatch keeps the deadline responsive even when cooperative tasks are saturated.
    let timeout = DispatchWorkItem { searchTask.cancel() }
    DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + seconds,
        execute: timeout
    )
    let result = await withTaskCancellationHandler {
        await searchTask.value
    } onCancel: {
        searchTask.cancel()
    }
    timeout.cancel()
    return result
}

/// Builds the shared on-demand cross-server source probe used by both app shells.
public func crossServerSourceResolver(
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> (@Sendable (MediaItem) async -> CrossServerSourceResolution)? {
    guard !accounts.isEmpty else { return nil }
    let serverInfo = accounts.sourceServerInfo()
    let orderedAccountIDs = accounts.map(\.account.id)
    let providersByAccountID: [String: any MediaProvider] = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { primary in
        await CrossServerSourceResolver.resolveWithEvidence(
            primary: primary,
            otherAccountIDs: orderedAccountIDs,
            search: { accountID, query in
                guard let provider = providersByAccountID[accountID] else { return [] }
                return await searchWithDeadline(
                    provider,
                    query: query,
                    limit: 25,
                    seconds: 4
                )
            },
            serverInfo: { serverInfo[$0] },
            identitySources: identitySources
        )
    }
}

/// Recovers only curated hero titles missing from the index, never the full
/// Discovery candidate feed. Search suggestions still require live verification.
public func heroLibraryTargetResolver(
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
    visibility: @escaping @Sendable () async -> HomeLibraryVisibility = { .default },
    allowsDiscovery: @escaping @Sendable () async -> Bool = { true }
) -> (@Sendable (MediaItem) async -> MediaItem?)? {
    guard let resolveSources = crossServerSourceResolver(
        in: accounts, identitySources: identitySources
    ) else { return nil }
    return { item in
        guard !Task.isCancelled, !item.locallyValidatedPlayableSource,
              item.kind == .movie || item.kind == .series,
              MediaItemIdentity.hasStrongRetargetIdentity(item),
              identitySources(item).isEmpty,
              await allowsDiscovery() else { return nil }
        let initialVisibility = await visibility()
        let lookup = Task<MediaItem?, Never> {
            let resolution = await resolveSources(item)
            guard !Task.isCancelled, !resolution.sources.isEmpty else { return nil }
            let verification = HeroDiscoveryRuntime(
                accounts: accounts,
                identitySources: { _ in resolution.sources },
                allowsDiscovery: allowsDiscovery
            )
            let verified = await verification.resolveLibrarySources(
                in: [item], visibility: initialVisibility
            )
            return verified.first(where: \.locallyValidatedPlayableSource)
        }
        // One budget covers all title variants and live verification for this
        // slide; an unreachable account must not spend four seconds per variant.
        let deadline = DispatchWorkItem { lookup.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: deadline)
        let result = await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
        deadline.cancel()
        guard !Task.isCancelled else { return nil }
        guard !lookup.isCancelled else {
            PlozzLog.app.error("Hero library recovery timed out; the title remains unverified.")
            return nil
        }
        guard await allowsDiscovery(), await visibility() == initialVisibility,
              !Task.isCancelled else { return nil }
        return result
    }
}

/// A cross-account library search for the Related row: one query fanned out to
/// every signed-in server, results pooled.
///
/// Pooled rather than per-account because a related title only has to exist
/// *somewhere* the viewer can reach. Which server holds it is the detail page's
/// problem once they open it, not this row's.
///
/// The same short deadline as the cross-server probe applies: a cold or unreachable
/// server must not hold up a row that is, by design, supplementary.
public func relatedTitleLibrarySearch(
    in accounts: [ResolvedAccount]
) -> (@Sendable (String, Int) async -> [MediaItem])? {
    guard !accounts.isEmpty else { return nil }
    let entries = accounts.map { ($0.account.id, $0.provider) }
    return { query, limit in
        await withTaskGroup(of: [MediaItem].self) { group in
            for (accountID, provider) in entries {
                group.addTask {
                    await searchWithDeadline(provider, query: query, limit: limit, seconds: 4)
                        .map { $0.taggingSource(accountID) }
                }
            }
            var pooled: [MediaItem] = []
            // Scoped by account, because an item id is provider-LOCAL: two servers
            // routinely use the same raw id for unrelated titles, so pooling on id
            // alone let one server's fuzzy hit suppress another's correct one — and
            // which survived depended on which search happened to finish first.
            var seen = Set<String>()
            for await hits in group {
                for hit in hits {
                    let key = "\(hit.sourceAccountID ?? "_"):\(hit.id)"
                    if seen.insert(key).inserted { pooled.append(hit) }
                }
            }
            return pooled
        }
    }
}

/// Resolves an indexed copy only through its active account, with the same
/// cooperative deadline as fallback searches. Native metadata stays authoritative.
public func relatedTitleLibraryItemLoader(
    in accounts: [ResolvedAccount]
) -> @Sendable (MediaSourceRef) async -> MediaItem? {
    let providers = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { source in
        guard !Task.isCancelled else { return nil }
        guard let provider = providers[source.accountID] else {
            PlozzLog.app.error("Related: indexed source has no active account; falling back to library search.")
            return nil
        }
        let lookup = Task<MediaItem?, Never> {
            do {
                try Task.checkCancellation()
                let item = try await provider.item(id: source.itemID)
                try Task.checkCancellation()
                return item.taggingSource(source.accountID)
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    PlozzLog.app.error("Related: indexed item lookup failed; falling back to library search.")
                }
                return nil
            }
        }
        let timeout = DispatchWorkItem { lookup.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
        let item = await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
        timeout.cancel()
        guard !Task.isCancelled else { return nil }
        if lookup.isCancelled {
            PlozzLog.app.error("Related: indexed item lookup timed out; falling back to library search.")
            return nil
        }
        return item
    }
}

/// Only batch-capable active accounts appear here. Other providers keep the
/// individual lookup path; provider kinds and raw item IDs are not account keys.
public func relatedTitleLibraryBatchLoaders(
    in accounts: [ResolvedAccount]
) -> [String: @Sendable ([String]) async -> [MediaItem]] {
    var loaders: [String: @Sendable ([String]) async -> [MediaItem]] = [:]
    for account in accounts {
        guard let provider = account.provider as? any LibraryItemBatchProviding else { continue }
        let accountID = account.account.id
        loaders[accountID] = { ids in
            guard !Task.isCancelled, !ids.isEmpty else { return [] }
            let lookup = Task<[MediaItem], Never> {
                do {
                    try Task.checkCancellation()
                    let items = try await provider.libraryItems(ids: ids)
                    try Task.checkCancellation()
                    let requested = Set(ids)
                    guard items.allSatisfy({ requested.contains($0.id) }),
                          Set(items.map(\.id)).count == items.count else {
                        throw AppError.invalidResponse
                    }
                    return items.map { $0.taggingSource(accountID) }
                } catch {
                    if !Task.isCancelled, !(error is CancellationError), (error as? AppError) != .cancelled {
                        PlozzLog.app.error("Related: indexed batch failed; falling back to individual lookups.")
                    }
                    return []
                }
            }
            let timeout = DispatchWorkItem { lookup.cancel() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
            let items = await withTaskCancellationHandler {
                await lookup.value
            } onCancel: {
                lookup.cancel()
            }
            timeout.cancel()
            guard !Task.isCancelled else { return [] }
            if lookup.isCancelled {
                PlozzLog.app.error("Related: indexed batch timed out; falling back to individual lookups.")
                return []
            }
            return items
        }
    }
    return loaders
}
