import CoreModels
import CoreNetworking
import Foundation

public protocol IPTVGuideIndexLoading: Sendable {
    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> [ServerLiveTVProgramme]
    /// Listings from a fresh saved index, or `nil` when answering would need a download.
    /// `catalog` reads the whole lineup; call it only once a saved index could answer.
    func cachedProgrammes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
    ) async throws -> [ServerLiveTVProgramme]?
    func invalidate() async
    func cancel() async
}

public extension IPTVGuideIndexLoading {
    func cachedProgrammes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
    ) async throws -> [ServerLiveTVProgramme]? { nil }
}
