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

    #if DEBUG
    init(index: LiveTVGuideIndex, settings: LiveTVViewSettingsStore) {
        self.index = index
        self.settings = settings
    }
    #endif

    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> [ServerLiveTVProgramme] {
        let lineup = try await catalog()
        return try await programmes(url: url, channels: channels, from: from, to: to, trustsGuideIDs: trustsGuideIDs,
                                    catalogRevision: nil, pinnedCatalog: { lineup }, download: download)
    }

    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool, catalogRevision: String?,
        pinnedCatalog: @escaping @Sendable () throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> [ServerLiveTVProgramme] {
        let programs = try await index.programs(
            from: url, channels: channels.map(Self.channel), range: DateInterval(start: from, end: to),
            trustsGuideIDs: trustsGuideIDs, catalogRevision: catalogRevision,
            pinnedCatalog: { try Self.catalogChannels(pinnedCatalog()) }, revalidate: download
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
            catalog: { try await Self.catalogChannels(catalog()) }
        )?.map(Self.programme)
    }

    func cachedProgrammes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        trustsGuideIDs: Bool, catalogRevision: String?,
        pinnedCatalog: @escaping @Sendable () throws -> [IPTVProvider.IPTVGuideChannel]
    ) async throws -> [ServerLiveTVProgramme]? {
        try await index.cachedPrograms(
            from: url, channels: channels.map(Self.channel), range: DateInterval(start: from, end: to),
            trustsGuideIDs: trustsGuideIDs, catalogRevision: catalogRevision,
            pinnedCatalog: { try Self.catalogChannels(pinnedCatalog()) }
        )?.map(Self.programme)
    }

    func updateSaved(
        url: URL, catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    ) async throws -> Date? {
        try await index.updateSaved(
            from: url, catalog: { try await Self.catalogChannels(catalog()) }, revalidate: download
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

    private static func catalogChannels(_ lineup: [IPTVProvider.IPTVGuideChannel]) throws -> [LiveTVPrototypeChannel] {
        #if DEBUG
        IPTVLineupProbe.record?(.adapterMaps)
        #endif
        return try lineup.map { channel in
            try Task.checkCancellation()
            return Self.channel(channel)
        }
    }

    private static func channel(_ channel: IPTVProvider.IPTVGuideChannel) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: channel.id, number: 0, name: channel.name, category: "Live TV", symbol: "tv",
            accent: 0, source: .iptv, tagline: "", guideID: channel.guideID,
            guideName: channel.guideName, country: channel.country
        )
    }
}
