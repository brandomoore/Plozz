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
