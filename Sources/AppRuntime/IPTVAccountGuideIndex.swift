import CoreModels
import CoreNetworking
import CoreSecureStore
import CryptoKit
import FeatureLiveTVCore
import Foundation
import ProviderIPTV

struct IPTVAccountGuideIndex: IPTVGuideIndexLoading {
    let index: LiveTVGuideIndex

    init(context: ProviderResolutionContext) throws {
        guard let local = context.localMediaContext else {
            throw ProviderResolutionError.localMediaContextRequired(.iptv)
        }
        let identity = try JSONEncoder().encode([
            "account-xmltv-v1", context.accountID, context.credentialRevision.rawValue.uuidString,
            local.profileID, local.profileNamespace
        ])
        let scope = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        index = LiveTVGuideIndex(cache: LiveTVIndexedCache(
            url: try LiveTVIndexedCache.defaultURL(namespace: scope, authorizationScope: "account-xmltv-v1"),
            namespace: scope, authorizationScope: "account-xmltv-v1",
            secureStore: LiveTVSourceStorage.catalogSecrets()
        ))
    }

    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable () async throws -> XMLTVDownloadedDocument
    ) async throws -> [ServerLiveTVProgramme] {
        let allChannels = try await catalog()
        let programs = try await index.programs(
            from: url, catalog: allChannels.map(Self.channel), channels: channels.map(Self.channel),
            range: DateInterval(start: from, end: to), download: download
        )
        return programs.map {
            ServerLiveTVProgramme(
                id: $0.id, channelID: $0.channelID, title: $0.title, subtitle: $0.subtitle,
                overview: $0.details?.description, startDate: $0.start, endDate: $0.end,
                imageURL: $0.details?.artworkURL, categories: $0.details?.categories ?? []
            )
        }
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
