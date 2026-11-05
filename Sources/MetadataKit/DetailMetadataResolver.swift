import CoreModels
import CoreNetworking
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

    public func trailers(for item: MediaItem, limit: Int = 6) async -> [MediaItem] {
        guard item.allowsTitleBasedMetadataMatching,
              [.movie, .video, .series].contains(item.kind), !Task.isCancelled,
              !settingsStore.load().isDisabled(.tmdb) else { return [] }
        do {
            let provider = TMDbMetadataProvider(access: providerConfig().tmdb)
            let ids = try await provider.trailerVideoIDs(for: MetadataQuery(item), limit: limit)
            return ids.map {
                MediaItem.youTubeTrailer(
                    videoID: $0, title: item.title,
                    parentTitle: item.title, posterURL: item.posterURL
                )
            }
        } catch is CancellationError {
            return []
        } catch {
            PlozzLog.networking.error("Trailer metadata lookup failed; retaining available server trailers.")
            return []
        }
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
        let roles = Set(item.people.compactMap { MediaCrewRole(kind: $0.kind) })
        if !roles.contains(.director) { missing.insert(.directors) }
        if !roles.contains(.writer) { missing.insert(.writers) }
        if roles.isDisjoint(with: [.producer, .executiveProducer]) { missing.insert(.producers) }
        if roles.isDisjoint(with: [.composer, .music]) { missing.insert(.composers) }
        if item.studios.isEmpty { missing.insert(.studios) }
        if item.genres.isEmpty { missing.insert(.genres) }
        if item.kind == .movie || item.kind == .series,
           item.originalLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            missing.insert(.originalLanguage)
        }
        if item.kind == .series {
            if item.seriesStatus == nil { missing.insert(.seriesStatus) }
            if (item.catalogSeasonCount ?? 0) <= 0 { missing.insert(.catalogSeasonCount) }
            if (item.catalogEpisodeCount ?? 0) <= 0 { missing.insert(.catalogEpisodeCount) }
        }
        return missing
    }

    public static func applying(_ enrichment: MetadataEnrichment, to item: MediaItem) -> MediaItem {
        var copy = item
        let missing = missingFields(in: item)
        for (field, people) in [
            (MetadataField.cast, enrichment.cast),
            (.directors, enrichment.directors),
            (.writers, enrichment.writers),
            (.producers, enrichment.producers),
            (.composers, enrichment.composers)
        ] {
            guard missing.contains(field), let people, !people.value.isEmpty else { continue }
            copy.people.append(contentsOf: people.value)
            copy.metadataProvenance.set(people, for: field)
        }
        if let references = enrichment.creditReferences, references.source == .tmdb {
            copy.people = reconcilingCredits(copy.people, references: references.value)
        }
        if missing.contains(.studios), let studios = enrichment.studios, !studios.value.isEmpty {
            copy.studios = studios.value
            copy.metadataProvenance.set(studios, for: .studios)
        }
        if missing.contains(.genres), let genres = enrichment.genres, !genres.value.isEmpty {
            copy.genres = genres.value
            copy.metadataProvenance.set(genres, for: .genres)
        }
        if missing.contains(.originalLanguage), let language = enrichment.originalLanguage,
           !language.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.originalLanguage = language.value
            copy.metadataProvenance.set(language, for: .originalLanguage)
        }
        if missing.contains(.seriesStatus), let status = enrichment.seriesStatus {
            copy.seriesStatus = status.value
            copy.metadataProvenance.set(status, for: .seriesStatus)
        }
        if missing.contains(.catalogSeasonCount), let count = enrichment.catalogSeasonCount, count.value > 0 {
            copy.catalogSeasonCount = count.value
            copy.metadataProvenance.set(count, for: .catalogSeasonCount)
        }
        if missing.contains(.catalogEpisodeCount), let count = enrichment.catalogEpisodeCount, count.value > 0 {
            copy.catalogEpisodeCount = count.value
            copy.metadataProvenance.set(count, for: .catalogEpisodeCount)
        }
        return copy
    }

    private static func reconcilingCredits(_ people: [MediaPerson], references: [MediaPerson]) -> [MediaPerson] {
        func name(_ person: MediaPerson) -> String {
            person.name.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        func role(_ person: MediaPerson) -> String? {
            person.isCast ? "actor" : MediaCrewRole(kind: person.kind).map { "crew.\($0.rawValue)" }
        }
        let referenceGroups = Dictionary(grouping: references, by: name)
        let nativeGroups = Dictionary(grouping: people.indices.filter {
            !people[$0].id.hasPrefix("tmdb:person:")
        }, by: { name(people[$0]) })
        var result = people
        for (name, indices) in nativeGroups {
            guard !name.isEmpty, let candidates = referenceGroups[name],
                  let identity = candidates.first?.id, identity.hasPrefix("tmdb:person:"),
                  Set(candidates.map(\.id)).count == 1 else { continue }
            let nativeIdentities = Set(indices.map {
                let person = people[$0]
                let external = person.externalID?.trimmingCharacters(in: .whitespacesAndNewlines)
                return external.flatMap { $0.isEmpty ? nil : $0 } ?? person.id
            })
            guard nativeIdentities.count == 1,
                  indices.allSatisfy({ people[$0].creditIdentity == nil || people[$0].creditIdentity == identity }),
                  indices.contains(where: { index in
                      guard let nativeRole = role(people[index]) else { return false }
                      return candidates.contains { role($0) == nativeRole }
                  }) else { continue }
            for index in indices { result[index].creditIdentity = identity }
        }
        return result
    }
}
