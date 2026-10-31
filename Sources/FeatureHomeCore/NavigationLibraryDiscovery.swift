import CoreModels
import Foundation

/// Older requests cannot overwrite a newer answer in the current authorization scope.
@MainActor
public final class NavigationLibraryDiscovery {
    private var nextRequest = 0
    private var publishedRequest = 0

    public init() {}

    public func refresh(
        from accounts: [ResolvedAccount],
        expectedAccountIDs: Set<String> = [],
        navigation: NavigationStyleSettingsModel,
        isCurrent: () -> Bool
    ) async -> HomeAggregator.LibraryDiscovery? {
        nextRequest += 1
        let request = nextRequest
        await Task.yield()
        guard !Task.isCancelled, request > publishedRequest, isCurrent() else { return nil }
        let discovery = await HomeAggregator().libraryDiscovery(
            from: accounts, expectedAccountIDs: expectedAccountIDs
        )
        guard !Task.isCancelled, request > publishedRequest, isCurrent() else { return nil }
        // Starting a cancellable Settings refresh must not invalidate a live shell request.
        publishedRequest = request
        navigation.updateContentLibraries(
            discovery.libraries,
            accountIDs: Set(accounts.map(\.account.id)).union(expectedAccountIDs),
            unreachableAccountIDs: discovery.unreachableAccountIDs,
            failures: discovery.failures
        )
        return discovery
    }
}
