#if canImport(SwiftUI)
import Foundation
import Observation
import CoreModels
import FeatureHome

/// Loads the full set of libraries across every active account for the Settings
/// "Home Libraries" checklist. Lives in the composition root because it drives
/// the provider-agnostic `HomeAggregator`; `FeatureSettings` only ever sees the
/// resulting `[AggregatedLibrary]` data, never a provider.
@MainActor
@Observable
final class LibraryDiscoveryModel {
    private(set) var state: LoadState<[AggregatedLibrary]> = .idle
    private(set) var canSkipSelection = false

    private let aggregator = HomeAggregator()
    private var loadGeneration = UUID()

    /// Discovers libraries across `accounts`, resiliently, WITHOUT publishing any
    /// state, reporting which accounts were unreachable. The Settings path uses
    /// this to write results into a `DiscoveredLibrariesStore`.
    func libraryDiscovery(from accounts: [ResolvedAccount]) async -> HomeAggregator.LibraryDiscovery {
        await aggregator.libraryDiscovery(from: accounts)
    }

    /// Discovers libraries across `accounts`, resiliently, WITHOUT publishing any
    /// state. The Settings path uses this to write results into a
    /// `DiscoveredLibrariesStore` instead — so a Settings-appearance reload never
    /// churns an observable the Settings ROOT list reads (which, mid tab
    /// focus-flip, caused the `setToViewXFlippedScreenShot:` use-after-free).
    func libraries(from accounts: [ResolvedAccount]) async -> [AggregatedLibrary] {
        await aggregator.libraries(from: accounts)
    }

    /// Discovers libraries across `accounts`, resiliently. Always reloads so the
    /// checklist reflects servers added/removed since it was last opened.
    func load(from accounts: [ResolvedAccount]) async {
        let generation = UUID()
        loadGeneration = generation
        state = .loading
        canSkipSelection = false
        let discovery = await libraryDiscovery(from: accounts)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        canSkipSelection = discovery.canSkipSelection(for: accounts)
        if discovery.libraries.isEmpty, !discovery.unreachableAccountIDs.isEmpty {
            state = .failed(.serverUnreachable)
        } else {
            state = discovery.libraries.isEmpty ? .empty : .loaded(discovery.libraries)
        }
    }
}
#endif
