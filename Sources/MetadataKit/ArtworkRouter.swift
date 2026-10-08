import Foundation
import CoreModels

/// The single front door for resolving external artwork — the piece that makes the
/// provider set *scalable and content-aware*.
///
/// Given a ``MediaItem`` and an ``ArtworkKind``, the router:
///   1. classifies the item's ``ContentType`` (anime / movie / tvShow / music),
///   2. runs an ordered, content-type-specific fallback chain of providers
///      (keyless per-IP APIs first, the optional TMDb tier as backup),
///   3. memoizes the resolved URL in the persistent ``MetadataDiskCache`` so the
///      whole library is enriched with a small one-time burst of calls, then
///      effectively none — which is what lets the keyless backbone serve any
///      number of users without ever straining a shared quota.
///
/// It self-configures from the app bundle, so call sites just use
/// ``ArtworkRouter/shared`` without any app wiring.
public actor ArtworkRouter {
    public static let shared = ArtworkRouter()

    private let anilist = AniListArtworkProvider()
    private let kitsu = KitsuArtworkProvider()
    private let tvmaze = TVmazeArtworkProvider()
    private let wikidata = WikidataArtworkProvider()
    private let wikipedia = WikipediaArtworkProvider()
    private let deezer = DeezerMusicProvider()
    private let musicBrainz = MusicBrainzArtworkProvider()
    private var tmdb: TMDbMetadataProvider
    /// Bundled TheTVDB backdrop tier (hero art only). Nil-safe when unconfigured.
    private let tvdb = TVDBArtworkProvider(client: TVDBClient(config: .resolved()))
    private let cache: MetadataDiskCache
    private let enrichmentBaseline: MetadataEnrichmentConfig
    private let settingsStore: any MetadataProviderSettingsStoring
    /// Original language is show/movie-level metadata, so every episode in a
    /// series shares one answer. Keep positive and negative results separately:
    /// a plain `[String: String?]` cannot retain nil (assigning nil removes the
    /// entry), which would repeat the network lookup on every episode.
    private var originalLanguages: [String: String] = [:]
    private var missingOriginalLanguages = Set<String>()
    /// Candidate lists, memoised for the process.
    ///
    /// Not the persistent cache: that stores one URL per key and a list has no
    /// representation in it. A title's candidates are cheap to recompute once per
    /// run, and holding them here is what makes returning to a page free. Capped
    /// because a large library would otherwise grow this without bound; dropping
    /// the lot costs one recomputation, which is far better than leaking.
    private var heroCandidates: [String: [SourcedValue<URL>]] = [:]
    private static let heroCandidatesCap = 600

    public init(
        config: MetadataProviderConfig = .resolved(),
        cache: MetadataDiskCache = .shared,
        enrichmentBaseline: MetadataEnrichmentConfig = .resolved(),
        settingsStore: any MetadataProviderSettingsStoring = MetadataProviderSettingsStore()
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.enrichmentBaseline = enrichmentBaseline
        self.settingsStore = settingsStore
    }

    /// Reconfigures the TMDb tier at runtime (e.g. after the user sets a proxy).
    public func reconfigure(_ config: MetadataProviderConfig) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
    }

    /// `true` when the optional TMDb tier is configured (proxy or local token).
    public var isTMDbEnabled: Bool { tmdb.isEnabled }

    /// Best available original spoken language for playback policy.
    ///
    /// Anime has a local, stronger answer (`ja`) and never needs a network call.
    /// Other video asks TMDb once per title; a miss stays a miss for this router
    /// session so episode hand-offs never add repeated metadata latency.
    public func originalAudioLanguage(for item: MediaItem) async -> String? {
        if let classified = ContentClassifier.originalAudioLanguage(for: item) {
            return classified
        }
        let query = MetadataQuery(item).seriesScoped
        let key = Self.originalLanguageCacheKey(for: item, query: query)
        if let cached = originalLanguages[key] { return cached }
        if missingOriginalLanguages.contains(key) { return nil }
        guard let language = await tmdb.originalLanguage(for: query) else {
            missingOriginalLanguages.insert(key)
            return nil
        }
        originalLanguages[key] = language
        return language
    }

    static func originalLanguageCacheKey(
        for item: MediaItem,
        query: MetadataQuery? = nil
    ) -> String {
        let query = query ?? MetadataQuery(item).seriesScoped
        if item.kind == .episode || item.kind == .season {
            let namespaces: [ProviderIDNamespace] = [
                .seriesTmdb, .seriesTvdb, .seriesImdb, .seriesTvmaze,
                .seriesAniList, .seriesMal, .seriesAniDB,
            ]
            for namespace in namespaces {
                if let value = item.providerID(namespace) {
                    return "original-language|\(namespace.canonicalKey.lowercased()):\(value)"
                }
            }
        }
        return "original-language|\(query.cacheKey(for: .poster))"
    }

    // MARK: - Video artwork

    /// External artwork for an ordered presentation ladder. Library bytes remain
    /// the first-paint resolver's responsibility. Only `.episodeThumbnail` may
    /// consult episode artwork; other episode placements resolve the owning show.
    public func artworkURL(for item: MediaItem, placements: [ArtworkPlacement]) async -> URL? {
        await sourcedArtworkURL(for: item, placements: placements)?.value
    }

    public func sourcedArtworkURL(
        for item: MediaItem, placements: [ArtworkPlacement]
    ) async -> SourcedValue<URL>? {
        guard item.supportsExternalArtworkLookup else { return nil }
        let lookup = item.artworkLookupItem
        let policy = settingsStore.load().artworkPolicyIdentity
        var seen = Set<ArtworkPlacement>()
        for placement in placements where seen.insert(placement).inserted {
            guard !Task.isCancelled, settingsStore.load().artworkPolicyIdentity == policy else { return nil }
            if placement == .episodeThumbnail && lookup.kind != .episode { continue }
            let subject = placement == .episodeThumbnail ? lookup : Self.seriesArtworkItem(for: lookup)
            let kind: ArtworkKind
            switch placement {
            case .poster, .seriesPoster, .seasonPoster: kind = .poster
            case .logo: kind = .logo
            case .episodeThumbnail: kind = .thumbnail
            case .homeHero, .detailBackdrop, .banner, .seasonBanner: kind = .hero
            default: continue
            }
            let cachedSubject = lookup.kind == .season && (placement == .poster || placement == .seasonPoster)
                ? lookup : subject
            let cachedPlacement: ArtworkPlacement = lookup.kind == .season && placement == .poster
                ? .seasonPoster : placement
            let answer = await sourcedArtworkURL(
                kind, for: MetadataQuery(subject),
                catalogCandidates: cachedSubject.metadataArtworkURLs(for: cachedPlacement)
            )
            guard !Task.isCancelled, settingsStore.load().artworkPolicyIdentity == policy else { return nil }
            if let answer { return answer }
        }
        return nil
    }

    /// A query-only show subject. Never reinterpret child IDs or episode stills
    /// as series identity/artwork, and never mutate the playable original.
    public nonisolated static func seriesArtworkItem(for item: MediaItem) -> MediaItem {
        let episode = item.artworkLookupItem
        guard episode.kind == .episode || episode.kind == .season else { return episode }
        let query = MetadataQuery(episode).seriesScoped
        let hasSeriesTitle = episode.parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        var ids = query.providerIDs
        ids.removeProviderID(.plexGuid)
        for (namespace, value) in [
            (ProviderIDNamespace.aniList, query.animeIDs.anilist),
            (.myAnimeList, query.animeIDs.mal), (.aniDB, query.animeIDs.anidb)
        ] where ids.providerID(namespace) == nil {
            if let value { ids[namespace.canonicalKey] = String(value) }
        }
        var series = MediaItem(
            id: episode.seriesID ?? episode.id, title: episode.parentTitle ?? episode.title, kind: .series,
            genres: episode.genres, tags: episode.tags, seriesID: episode.seriesID,
            posterURL: episode.seriesPosterURL, backdropURL: episode.fallbackArtworkURL,
            fallbackArtworkURL: episode.fallbackArtworkURL, logoURL: episode.logoURL,
            providerIDs: ids,
            allowsTitleBasedMetadataMatching: episode.allowsTitleBasedMetadataMatching && hasSeriesTitle,
            metadataProvenance: episode.metadataProvenance,
            sourceAccountID: episode.sourceAccountID,
            artworkSourceAccountIDsByURL: episode.artworkSourceAccountIDsByURL
        )
        series.artworkMetadataSourcesByURL = episode.artworkMetadataSourcesByURL
        if let selection = episode.artworkSelections.first(where: { $0.placement == .seriesPoster }) {
            series.artworkSelections = [
                .init(placement: .poster, references: selection.references),
                selection
            ]
        }
        if let logo = episode.artworkSelections.first(where: { $0.placement == .logo }) {
            series.artworkSelections.append(logo)
        }
        return series
    }

    /// Resolves a `kind` artwork URL for `item`, trying the content-type-specific
    /// provider chain and caching the (positive or negative) result. Never throws.
    public func artworkURL(_ kind: ArtworkKind, for item: MediaItem) async -> URL? {
        await sourcedArtworkURL(kind, for: item)?.value
    }

    public func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for item: MediaItem
    ) async -> SourcedValue<URL>? {
        guard item.supportsExternalArtworkLookup else { return nil }
        let subject = item.artworkLookupItem
        return await sourcedArtworkURL(
            kind, for: MetadataQuery(subject),
            catalogCandidates: subject.metadataArtworkURLs(for: Self.placement(for: kind))
        )
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        await sourcedArtworkURL(kind, for: query)?.value
    }

    /// Resolves artwork together with the provider that supplied it.
    public func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for query: MetadataQuery
    ) async -> SourcedValue<URL>? {
        await sourcedArtworkURL(kind, for: query, catalogCandidates: [])
    }

    private func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for query: MetadataQuery,
        catalogCandidates: [SourcedValue<URL>]
    ) async -> SourcedValue<URL>? {
        let providers = configuredProviders(for: query, kind: kind)
        guard !providers.isEmpty else { return nil }
        let cache = self.cache

        let answers = await withTaskGroup(
            of: (Int, SourcedValue<URL>?).self,
            returning: [(Int, SourcedValue<URL>?)].self
        ) { group in
            for (index, entry) in providers.enumerated() {
                group.addTask {
                    let saved = catalogCandidates.first(where: { $0.source == entry.source })
                    let key = Self.providerCacheKey(
                        query: query,
                        kind: kind,
                        source: entry.source
                    )
                    if let hit = await cache.cached(key) {
                        return (
                            index,
                            hit.map { SourcedValue(value: $0, source: entry.source) } ?? saved
                        )
                    }
                    let url = await entry.provider.artworkURL(kind, for: query)
                    await cache.store(url, for: key)
                    return (
                        index,
                        url.map { SourcedValue(value: $0, source: entry.source) } ?? saved
                    )
                }
            }
            var completed = Array<SourcedValue<URL>??>(
                repeating: nil,
                count: providers.count
            )
            var nextPriority = 0
            while let (index, answer) = await group.next() {
                completed[index] = .some(answer)
                while nextPriority < completed.count,
                      let priorityAnswer = completed[nextPriority] {
                    if let priorityAnswer {
                        group.cancelAll()
                        return [(nextPriority, priorityAnswer)]
                    }
                    nextPriority += 1
                }
            }
            return []
        }
        guard !Task.isCancelled,
              configuredProviders(for: query, kind: kind).map(\.source) == providers.map(\.source)
        else { return nil }
        return answers.sorted { $0.0 < $1.0 }.compactMap(\.1).first
    }

    /// Ordered artwork candidates for `item`. See the ``MetadataQuery`` overload.
    public func sourcedArtworkURLs(
        _ kind: ArtworkKind,
        for item: MediaItem,
        limit: Int = 2
    ) async -> [SourcedValue<URL>] {
        guard item.supportsExternalArtworkLookup else { return [] }
        let subject = item.artworkLookupItem
        return await sourcedArtworkURLs(
            kind, for: MetadataQuery(subject), limit: limit,
            catalogCandidates: subject.metadataArtworkURLs(for: Self.placement(for: kind))
        )
    }

    /// Ordered artwork candidates for `kind`, best first, across the provider chain.
    ///
    /// Deliberately a **separate** entry point rather than a change to
    /// ``sourcedArtworkURL(_:for:)``. That one stops at the first provider which
    /// answers, and Home depends on it doing exactly that — widening it to gather
    /// candidates would ask providers that would never otherwise have been called,
    /// on the browse path, which is precisely the wrong place to spend a request.
    ///
    /// This one also supplies the deterministic Home/detail pair. Enabled providers
    /// race concurrently; results are put back into configured priority order before
    /// selection, so a slow high-priority source cannot serialize the whole chain.
    ///
    /// Results are memoised for the process, so returning to a title is free.
    public func sourcedArtworkURLs(
        _ kind: ArtworkKind,
        for query: MetadataQuery,
        limit: Int = 2
    ) async -> [SourcedValue<URL>] {
        await sourcedArtworkURLs(kind, for: query, limit: limit, catalogCandidates: [])
    }

    private func sourcedArtworkURLs(
        _ kind: ArtworkKind,
        for query: MetadataQuery,
        limit: Int,
        catalogCandidates: [SourcedValue<URL>]
    ) async -> [SourcedValue<URL>] {
        guard limit > 0 else { return [] }
        let providers = configuredProviders(for: query, kind: kind)
        let sourceFingerprint = providers.map(\.source.rawValue).joined(separator: ",")
        let catalogFingerprint = catalogCandidates.map {
            "\($0.source.rawValue):\(ArtworkReference.remote($0.value).privacySafeIdentity)"
        }.joined(separator: ",")
        let key = "\(query.cacheKey(for: kind))|candidates|\(sourceFingerprint)|\(catalogFingerprint)"
        if let hit = heroCandidates[key] { return hit }
        let cache = self.cache

        let batches = await withTaskGroup(
            of: (Int, MetadataSource, [URL]).self,
            returning: [(Int, MetadataSource, [URL])].self
        ) { group in
            for (index, entry) in providers.enumerated() {
                group.addTask {
                    let saved = catalogCandidates.filter { $0.source == entry.source }.map(\.value)
                    let cached = await cache.cached(Self.providerCacheKey(
                        query: query, kind: kind, source: entry.source
                    ))
                    if let cached, cached == nil {
                        return (index, entry.source, saved)
                    }
                    let offered = await entry.provider.artworkURLs(kind, for: query, limit: limit)
                    let fallback = (cached ?? nil).map { [$0] } ?? saved
                    return (index, entry.source, offered.isEmpty ? fallback : offered)
                }
            }
            var completed = Array<[URL]?>(repeating: nil, count: providers.count)
            var nextPriority = 0
            while let (index, _, offered) = await group.next() {
                completed[index] = offered
                while nextPriority < completed.count,
                      let priorityAnswer = completed[nextPriority] {
                    if !priorityAnswer.isEmpty {
                        group.cancelAll()
                        return completed.enumerated().compactMap { index, urls in
                            urls.map { (index, providers[index].source, $0) }
                        }
                    }
                    nextPriority += 1
                }
            }
            return []
        }

        guard !Task.isCancelled,
              configuredProviders(for: query, kind: kind).map(\.source) == providers.map(\.source)
        else { return [] }
        var found: [SourcedValue<URL>] = []
        var asked: [String] = []
        for (_, source, offered) in batches.sorted(by: { $0.0 < $1.0 }) {
            asked.append("\(source.rawValue):\(offered.count)")
            for url in offered {
                guard !found.contains(where: { $0.value == url }) else { continue }
                found.append(SourcedValue(value: url, source: source))
                if found.count >= limit { break }
            }
            if found.count >= limit { break }
        }
        HeroArtDiagnostics.emit(
            "router candidates kind=\(kind) title=\(query.title) type=\(query.contentType) "
            + "asked=[\(asked.joined(separator: " "))] got=\(found.count) "
            + "urls=[\(found.map { HeroArtDiagnostics.brief($0.value) }.joined(separator: " , "))]"
        )
        if heroCandidates.count >= Self.heroCandidatesCap { heroCandidates.removeAll(keepingCapacity: true) }
        heroCandidates[key] = found
        return found
    }

    /// Deterministic Home/detail picks from one online candidate pool. Detail uses
    /// the runner-up when available. A poster-only title retains its permitted
    /// external poster as a last resort.
    public func heroArtworkURL(
        for item: MediaItem,
        placement: ArtworkPlacement
    ) async -> URL? {
        let subject = Self.seriesArtworkItem(for: item)
        let candidates = await sourcedArtworkURLs(.hero, for: subject, limit: 4)
        if let hero = Self.heroCandidate(from: candidates, placement: placement) { return hero }
        return await artworkURL(for: item, placements: [.poster])
    }

    static func heroCandidate(
        from candidates: [SourcedValue<URL>],
        placement: ArtworkPlacement
    ) -> URL? {
        guard placement == .detailBackdrop else { return candidates.first?.value }
        return candidates.dropFirst().first?.value ?? candidates.first?.value
    }

    private func configuredProviders(
        for query: MetadataQuery,
        kind: ArtworkKind
    ) -> [(source: MetadataSource, provider: any ArtworkProvider)] {
        let config = enrichmentBaseline.merged(withUserOverrides: settingsStore.load())
        return config.orderedSources(for: Self.field(for: kind), query: query).compactMap { source in
            provider(for: source).map { (source, $0) }
        }
    }

    private static func field(for kind: ArtworkKind) -> MetadataField {
        switch kind {
        case .poster: .posterURL
        case .hero: .backdropURL
        case .thumbnail: .episodeThumbnail
        case .logo: .logoURL
        }
    }

    private static func placement(for kind: ArtworkKind) -> ArtworkPlacement {
        switch kind {
        case .poster: .poster
        case .hero: .homeHero
        case .thumbnail: .episodeThumbnail
        case .logo: .logo
        }
    }

    static func providerCacheKey(
        query: MetadataQuery,
        kind: ArtworkKind,
        source: MetadataSource
    ) -> String {
        "\(query.cacheKey(for: kind))|provider:\(source.rawValue)"
    }

    private func provider(for source: MetadataSource) -> (any ArtworkProvider)? {
        switch source {
        case .anilist: anilist
        case .kitsu: kitsu
        case .tvmaze: tvmaze
        case .wikidata: wikidata
        case .wikipedia: wikipedia
        case .tmdb: tmdb
        case .tvdb: tvdb
        default: nil
        }
    }

    // MARK: - Music artwork (separate model path)

    /// A large artist image for a music hero/background. Keyless (Deezer).
    public func artistImageURL(artist: String) async -> URL? {
        guard configuredMusicSources.contains(.deezer) else { return nil }
        let key = "music|artist|\(artist.lowercased())|provider:deezer"
        if let hit = await cache.cached(key) { return hit }
        let url = await deezer.artistImageURL(artist: artist)
        await cache.store(url, for: key)
        return url
    }

    /// A large album cover, trying Deezer then MusicBrainz/Cover Art Archive.
    public func albumCoverURL(artist: String?, album: String) async -> URL? {
        for source in configuredMusicSources {
            let key = "music|album|\((artist ?? "").lowercased())|\(album.lowercased())|provider:\(source.rawValue)"
            if let hit = await cache.cached(key) {
                if let hit { return hit }
                continue
            }
            let url: URL?
            switch source {
            case .deezer: url = await deezer.albumCoverURL(artist: artist, album: album)
            case .musicbrainz: url = await musicBrainz.albumCoverURL(artist: artist, album: album)
            default: continue
            }
            await cache.store(url, for: key)
            if let url { return url }
        }
        return nil
    }

    private var configuredMusicSources: [MetadataSource] {
        let config = enrichmentBaseline.merged(withUserOverrides: settingsStore.load())
        return config.order.filter {
            ($0 == .deezer || $0 == .musicbrainz) && config.isEnabled($0)
        }
    }
}
