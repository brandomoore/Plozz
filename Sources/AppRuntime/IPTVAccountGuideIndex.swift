import CoreModels
import CoreNetworking
import CoreSecureStore
import CryptoKit
import FeatureLiveTVCore
import Foundation
import ProviderIPTV

struct IPTVAccountGuideIndex: IPTVGuideIndexLoading {
    let index: LiveTVGuideIndex
    private let settings: LiveTVViewSettingsStore
    var updateInterval: TimeInterval? { settings.load().guideUpdateInterval.seconds }

    init(context: ProviderResolutionContext) throws {
        guard let local = context.localMediaContext else {
            throw ProviderResolutionError.localMediaContextRequired(.iptv)
        }
        let identity = try JSONEncoder().encode([
            "account-xmltv-v1", context.accountID, context.credentialRevision.rawValue.uuidString,
            local.profileID, local.profileNamespace
        ])
        let scope = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        // Read on every use so a change in Settings applies without rebuilding the provider.
        let settings = LiveTVViewSettingsStore(namespace: local.profileNamespace)
        self.settings = settings
        index = LiveTVGuideIndex(
            cache: LiveTVIndexedCache(
                url: try LiveTVIndexedCache.defaultURL(namespace: scope, authorizationScope: "account-xmltv-v1"),
                namespace: scope, authorizationScope: "account-xmltv-v1",
                secureStore: LiveTVSourceStorage.catalogSecrets()
            ),
            updateInterval: { settings.load().guideUpdateInterval.seconds }
        )
    }

    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> [ServerLiveTVProgramme] {
        let allChannels = try await catalog()
        let programs = try await index.programs(
            from: url, catalog: allChannels.map(Self.channel), channels: channels.map(Self.channel),
            range: DateInterval(start: from, end: to), trustsGuideIDs: trustsGuideIDs, revalidate: download
        )
        return programs.map(Self.programme)
    }

    func cachedProgrammes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool, catalogRevision: String?,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel]
    ) async throws -> [ServerLiveTVProgramme]? {
        try await index.cachedPrograms(
            from: url, channels: channels.map(Self.channel), range: DateInterval(start: from, end: to),
            trustsGuideIDs: trustsGuideIDs, catalogRevision: catalogRevision,
            catalog: { try await catalog().map(Self.channel) }
        )?.map(Self.programme)
    }

    func updateSaved(
        url: URL, catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> Date? {
        try await index.updateSaved(
            from: url, catalog: { try await catalog().map(Self.channel) }, revalidate: download
        )
    }

    private static func programme(_ program: LiveTVPrototypeProgram) -> ServerLiveTVProgramme {
        ServerLiveTVProgramme(
            id: program.id, channelID: program.channelID, title: program.title, subtitle: program.subtitle,
            overview: program.details?.description, startDate: program.start, endDate: program.end,
            imageURL: program.details?.artworkURL, categories: program.details?.categories ?? []
        )
    }

    func invalidate() async { await index.invalidate() }
    func cancel() async { await index.cancel() }

    private static func channel(_ channel: IPTVProvider.IPTVGuideChannel) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: channel.id, number: 0, name: channel.name, category: "Live TV", symbol: "tv",
            accent: 0, source: .iptv, tagline: "", guideID: channel.guideID,
            guideName: channel.guideName, country: channel.country
        )
    }
}
