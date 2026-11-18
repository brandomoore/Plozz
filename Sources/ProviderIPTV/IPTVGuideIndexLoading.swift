import CoreModels
import CoreNetworking
import Foundation

public protocol IPTVGuideIndexLoading: Sendable {
    /// `trustsGuideIDs`: `url` is the account's own guide, so a channel's guide ID alone
    /// decides which listings it gets.
    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> [ServerLiveTVProgramme]
    /// Listings from the saved index alone, never the network. `nil` when the saved guide
    /// cannot answer: nothing saved for this lineup and window, past its reuse limit, or
    /// waiting on a requested revalidation. An empty `channels` asks only whether the
    /// saved guide can answer and reads no listings.
    /// `catalog` reads the whole lineup; it is called only once a saved index could answer
    /// and `catalogRevision` has not been seen before. `catalogRevision` identifies a
    /// committed lineup, not the guide's freshness; without one every lookup validates the
    /// full lineup.
    func cachedProgrammes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool, catalogRevision: String?,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
    ) async throws -> [ServerLiveTVProgramme]?
    /// Brings an already saved guide up to date when the profile's update interval has
    /// passed. Returns when it next falls due; nil when updates are off or nothing is saved.
    func updateSaved(
        url: URL, catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> Date?
    /// The profile's automatic update interval; nil when automatic updates are off.
    var updateInterval: TimeInterval? { get }
    func invalidate() async
    func cancel() async
}

public extension IPTVGuideIndexLoading {
    var updateInterval: TimeInterval? { nil }

    func cachedProgrammes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool, catalogRevision: String?,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
    ) async throws -> [ServerLiveTVProgramme]? { nil }

    func updateSaved(
        url: URL, catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> Date? { nil }
}
