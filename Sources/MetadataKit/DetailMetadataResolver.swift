import CoreModels
import Foundation

/// Gap-only enrichment after a provider's full detail response, shared by both shells.
public actor DetailMetadataResolver {
    private let providerConfig: @Sendable () -> MetadataProviderConfig
    private let settingsStore: any MetadataProviderSettingsStoring
    private let runtime = MetadataProviderRuntime.makeDefault()

    public init(
        providerConfig: @escaping @Sendable () -> MetadataProviderConfig,
        settingsStore: any MetadataProviderSettingsStoring = MetadataProviderSettingsStore()
    ) {
        self.providerConfig = providerConfig
        self.settingsStore = settingsStore
    }

    public func resolve(_ item: MediaItem) async -> MetadataEnrichment {
        let missing = Self.missingFields(in: item)
        guard !missing.isEmpty, !Task.isCancelled else { return MetadataEnrichment() }
        let capabilities = Set(missing.compactMap(MetadataCapability.covering))
        let providers = ProductionMetadataProviders.make(
            providerConfig: providerConfig(),
            cache: runtime.resultCache,
            breakerRegistry: runtime.breakerRegistry
        ).filter { !$0.capabilities.isDisjoint(with: capabilities) }
        let pipeline = MetadataEnrichmentPipeline(
            providers: providers,
            config: MetadataEnrichmentConfig.resolved().merged(withUserOverrides: settingsStore.load())
        )
        return await pipeline.enrich(Self.metadataQuery(for: item), requesting: missing, tier: .foregroundFill)
    }

    static func metadataQuery(for item: MediaItem) -> MetadataQuery {
        let query = MetadataQuery(item)
        guard item.kind == .episode || item.kind == .season else { return query }
        let hasSeriesTitle = item.parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return MetadataQuery(
            contentType: query.contentType, kind: query.kind,
            title: hasSeriesTitle ? query.title : "", alternateTitle: query.alternateTitle,
            year: query.year, seasonNumber: query.seasonNumber, episodeNumber: query.episodeNumber,
            animeIDs: query.animeIDs, providerIDs: query.seriesScoped.providerIDs
        )
    }

    public static func missingFields(in item: MediaItem) -> Set<MetadataField> {
        switch item.kind {
        case .movie, .series, .season, .episode: break
        default: return []
        }
        var missing = Set<MetadataField>()
        if item.cast.isEmpty { missing.insert(.cast) }
        if !item.people.contains(where: { $0.kind?.lowercased() == "director" }) { missing.insert(.directors) }
        if !item.people.contains(where: { $0.kind?.lowercased() == "writer" }) { missing.insert(.writers) }
        if item.studios.isEmpty { missing.insert(.studios) }
        if item.genres.isEmpty { missing.insert(.genres) }
        return missing
    }

    public static func applying(_ enrichment: MetadataEnrichment, to item: MediaItem) -> MediaItem {
        var copy = item
        let missing = missingFields(in: item)
        for (field, people) in [
            (MetadataField.cast, enrichment.cast),
            (.directors, enrichment.directors),
            (.writers, enrichment.writers)
        ] {
            guard missing.contains(field), let people, !people.value.isEmpty else { continue }
            copy.people.append(contentsOf: people.value)
            copy.metadataProvenance.set(people, for: field)
        }
        if missing.contains(.studios), let studios = enrichment.studios, !studios.value.isEmpty {
            copy.studios = studios.value
            copy.metadataProvenance.set(studios, for: .studios)
        }
        if missing.contains(.genres), let genres = enrichment.genres, !genres.value.isEmpty {
            copy.genres = genres.value
            copy.metadataProvenance.set(genres, for: .genres)
        }
        return copy
    }
}
