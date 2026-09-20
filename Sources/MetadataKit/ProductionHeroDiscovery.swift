import CoreModels
import Foundation

public enum ProductionHeroDiscovery {
    private static let tvdbProviders = TVDBDiscoveryProviderRegistry()

    public static func providers(
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved()
    ) async -> [any HeroDiscoveryProviding] {
        let tvdb = await tvdbProviders.provider(config: tvdbConfig)
        return [
            TMDbDiscoveryProvider(access: providerConfig.tmdb),
            SimklDiscoveryProvider(),
            AniListDiscoveryProvider(),
            tvdb,
            TVmazeDiscoveryProvider()
        ]
    }

    public static func discover(
        _ request: HeroDiscoveryRequest,
        sources: [HeroDiscoverySource],
        providerConfig: MetadataProviderConfig = .resolved(),
        tvdbConfig: TVDBConfig = .resolved()
    ) async -> [MediaItem] {
        let providers = await providers(providerConfig: providerConfig, tvdbConfig: tvdbConfig)
        return await HeroDiscoveryService.shared.discover(
            request, sources: sources,
            providers: providers
        )
    }
}

actor TVDBDiscoveryProviderRegistry {
    private let http: MetadataDiscoveryHTTPClient
    private var providers: [String: TVDBDiscoveryProvider] = [:]
    private var order: [String] = []

    init(http: MetadataDiscoveryHTTPClient = .init()) {
        self.http = http
    }

    func provider(config: TVDBConfig) -> TVDBDiscoveryProvider {
        let candidate = TVDBDiscoveryProvider(config: config, http: http)
        let key = candidate.cacheIdentifier
        order.removeAll { $0 == key }
        order.append(key)
        if let existing = providers[key] { return existing }
        providers[key] = candidate
        while order.count > 8 {
            providers.removeValue(forKey: order.removeFirst())
        }
        return candidate
    }
}
