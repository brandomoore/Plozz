import CoreModels
#if canImport(UIKit)
import UIKit
#endif
import CoreNetworking
import ProviderJellyfin
import ProviderPlex
import ProviderSilo
import ProviderIPTV
import FeatureLiveTVCore
import Foundation

public enum ManagedProviderRegistry {
    /// Whether this build links the on-device decode engine (Plozzigen).
    ///
    /// This is what a provider tells its server about the client's real
    /// capabilities. Jellyfin and Emby pick direct-play versus transcode from
    /// the device profile we send, so leaving it at the conservative default
    /// tells the server we cannot demux Matroska — and it re-encodes an entire
    /// 4K HEVC remux that the device could have played untouched. Plex is less
    /// visibly affected because its decision leans on its own container rules,
    /// which is exactly why this stayed hidden: the same file direct-played from
    /// Plex and transcoded from Jellyfin on the same device.
    ///
    /// Defined here, next to the registry, so both app shells read one value.
    /// The iOS shell built this registry without the flag while the tvOS shell
    /// passed it, so iPhone and iPad silently advertised a weaker client.
    public static var hybridEngineEnabled: Bool {
        #if canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    public static func make(
        hybridEngineEnabled: Bool = ManagedProviderRegistry.hybridEngineEnabled,
        siloCredentials: (any RotatingCredentialStoring)? = nil,
        durableStore: DurableLocalStateStore? = nil
    ) -> ProviderRegistry {
        let registry = ProviderRegistry()
        registerIPTV(into: registry, durableStore: durableStore)
        registry.register(.silo) { context in
            guard let siloCredentials else { throw AppError.unauthorized }
            return try SiloProvider(context: context, credentials: siloCredentials)
        }
        registry.register(.jellyfin) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: hybridEngineEnabled
            )
        }
        registry.register(.emby) { context in
            JellyfinProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: hybridEngineEnabled
            )
        }
        registry.register(.plex) { context in
            PlexProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision,
                interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive),
                hybridEngineEnabled: hybridEngineEnabled,
                connectionRefresh: PlexProvider.connectionRefresh(for: context.session)
            )
        }
        return registry
    }

    public static func registerIPTV(into registry: ProviderRegistry, durableStore: DurableLocalStateStore?) {
        registry.register(.iptv) { context in
            try IPTVProvider(context: context, durableStore: durableStore, guideLoader: iptvGuideLoader)
        }
    }

    static let iptvGuideLoader: IPTVProvider.IPTVGuideLoader = { data, url, channels, from, to in
        let source = channels.enumerated().map { index, channel in
            LiveTVPrototypeChannel(
                id: channel.id, number: index + 1, name: channel.name, category: "Live TV",
                symbol: "tv", accent: 0, source: .iptv, tagline: "",
                guideID: channel.guideID, guideName: channel.guideName, country: channel.country
            )
        }
        let task = Task.detached(priority: .userInitiated) {
            let parser = LiveTVXMLTVParser(provider: LiveTVGuideSource.provider(for: url))
            return try data.starts(with: [0x1f, 0x8b])
                ? parser.parse(gzipData: data, channels: source, now: from)
                : parser.parseXML(data: data, channels: source, now: from)
        }
        let guide = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        return guide.programs.filter { $0.start < to && $0.end > from }.map {
            ServerLiveTVProgramme(
                id: $0.id, channelID: $0.channelID, title: $0.title, subtitle: $0.subtitle,
                overview: $0.details?.description, startDate: $0.start, endDate: $0.end,
                imageURL: $0.details?.artworkURL, categories: $0.details?.categories ?? []
            )
        }
    }
}
