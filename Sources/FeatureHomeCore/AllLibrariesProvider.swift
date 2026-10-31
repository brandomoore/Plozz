import CoreModels

/// Both shells use the same source inventory, per-library kinds and merge policy.
public func resolveAllLibrariesBrowse(
    libraries: [AggregatedLibrary],
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
    identityRevision: @escaping @Sendable () -> Int = { 0 }
) -> (any MediaProvider)? {
    var sources: [AggregatedLibrarySource] = []
    var seen: Set<String> = []
    for aggregated in libraries where !aggregated.library.isMusic {
        let library = aggregated.library
        for accountID in library.allSourceAccountIDs {
            guard
                let provider = accounts.first(where: { $0.account.id == accountID })?.provider,
                let containerID = library.containerID(forSourceAccountID: accountID)
            else { continue }
            guard seen.insert("\(accountID)\u{1F}\(containerID)").inserted else { continue }
            sources.append(
                AggregatedLibrarySource(
                    accountID: accountID, containerID: containerID,
                    provider: provider, kind: library.kind
                )
            )
        }
    }
    guard !sources.isEmpty else { return nil }
    return AggregatedLibraryProvider(
        sources: sources,
        serverInfo: accounts.sourceServerInfo(),
        identitySources: identitySources,
        identityRevision: identityRevision
    )
}

/// Rebuild retained browse state when source membership or container kinds change,
/// but not when discovery merely returns the same libraries in a different order.
public func allLibrariesSourceSignature(_ libraries: [AggregatedLibrary]) -> String {
    libraries
        .filter { !$0.library.isMusic }
        .flatMap { aggregated in
            aggregated.library.allSourceAccountIDs.map { accountID in
                let container = aggregated.library.containerID(forSourceAccountID: accountID) ?? ""
                return "\(accountID)/\(container)/\(aggregated.library.kind.rawValue)"
            }
        }
        .sorted()
        .joined(separator: ",")
}
