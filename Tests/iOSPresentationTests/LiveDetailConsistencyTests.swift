#if os(iOS)
import AppRuntime
import CoreModels
import FeatureHomeCore
import Foundation
import MetadataKit
import XCTest

@MainActor
final class LiveDetailConsistencyTests: XCTestCase {
    func testLiveJellyfinDetailRoutes() async throws { try await exercise(.jellyfin) }
    func testLivePlexDetailRoutes() async throws { try await exercise(.plex) }
    func testLiveEmbyDetailRoutes() async throws { try await exercise(.emby) }

    private func exercise(_ kind: ProviderKind) async throws {
        let http = LiveHomeReadOnlyHTTP()
        let account = try await LiveHomeReadOnlyAccount.connect(kind, http: http)
        let provider = account.provider
        let feed = try await provider.continueWatching(limit: 20).map { $0.taggingSource(account.account.id) }
        let (show, episode, season) = try await sampleSeries(account, feed: feed)
        let matches = try await provider.search(query: show.title, limit: 20)
        let search = try XCTUnwrap(matches.first { $0.id == show.id && $0.kind == .series },
                                   "Live Search must return the sampled series.").taggingSource(account.account.id)
        let environment = environment(accounts: [account], feed: feed)
        let routes = [
            try environment.makeViewModel(for: search, libraryOrigin: nil),
            try environment.makeViewModel(for: show, libraryOrigin: account.account.id),
            try environment.makeSeriesContextViewModel(
                seriesID: show.id, seed: episode, sourceAccountID: account.account.id, originAccountID: nil
            )
        ]
        defer { routes.forEach { $0.suspendEnrichment() } }
        for model in routes { await model.load() }
        let canonical = try XCTUnwrap(routes[0].state.value)
        for model in routes {
            let detail = try XCTUnwrap(model.state.value, "A live route must load, not retain an error.")
            XCTAssertTrue(detail.item.id == show.id && detail.item.sourceAccountID == account.account.id)
            XCTAssertTrue(sameEditorial(detail.item, show), "Native editorial metadata must survive hydration.")
            XCTAssertTrue(sameEditorial(detail.item, canonical.item), "All ordinary entries must share metadata.")
            XCTAssertTrue(detail.children.map(\.id) == canonical.children.map(\.id))
            XCTAssertTrue(model.serverResumeEpisode?.id == routes[0].serverResumeEpisode?.id)
            XCTAssertTrue(model.serverResumeEpisode?.resumePosition == routes[0].serverResumeEpisode?.resumePosition)
        }
        if let expected = feed.first(where: { $0.kind == .episode && $0.seriesID == show.id }) {
            XCTAssertTrue(routes[0].serverResumeEpisode?.id == expected.id,
                          "The current server resume target must replace the older episode entry.")
        }
        let retained = routes[0]
        if let season {
            await retained.loadEpisodes(for: season.id)
            XCTAssertFalse(retained.episodes(for: season.id)?.isEmpty ?? true)
        }
        for language in ["en", "fr"] {
            retained.updateMetadataLanguage(language)
            await retained.load()
            XCTAssertTrue(sameEditorial(try XCTUnwrap(retained.state.value?.item), show))
            if let season { XCTAssertFalse(retained.episodes(for: season.id)?.isEmpty ?? true) }
        }
        let explicit = try environment.makeViewModel(for: episode, libraryOrigin: nil)
        defer { explicit.suspendEnrichment() }
        await explicit.load()
        XCTAssertTrue(explicit.state.value?.item.id == episode.id, "Explicit episode information stays episode-owned.")
        if let season {
            let selected = try environment.makeSeriesContextViewModel(
                seriesID: show.id, seed: season, sourceAccountID: account.account.id, originAccountID: nil
            )
            defer { selected.suspendEnrichment() }
            await selected.load()
            await selected.loadEpisodes(for: season.id)
            XCTAssertTrue(selected.state.value?.item.sourceAccountID == account.account.id)
            XCTAssertFalse(selected.episodes(for: season.id)?.isEmpty ?? true)
        }
        let libraries = try await provider.libraries()
        let library = try XCTUnwrap(libraries.first { $0.kind == .movie })
        let page = try await provider.items(in: library.id, kind: .movie, page: .init(limit: 3))
        let movie = try XCTUnwrap(page.items.first { $0.kind == .movie })
        let movieModel = try environment.makeViewModel(for: movie, libraryOrigin: account.account.id)
        defer { movieModel.suspendEnrichment() }
        await movieModel.load()
        let fullMovie = try await provider.item(id: movie.id)
        XCTAssertTrue(sameEditorial(try XCTUnwrap(movieModel.state.value?.item), fullMovie))
        let after = try await provider.item(id: episode.id)
        XCTAssertTrue(after.isPlayed == episode.isPlayed && after.resumePosition == episode.resumePosition,
                      "Read-only detail inspection must not change the test user's history.")
        let counts = await http.counts()
        XCTAssertEqual(counts.blocked, 0)
        XCTAssertGreaterThan(counts.reads, 0)
        print("LIVE_DETAIL provider=\(kind.rawValue) ordinaryRoutes=3 explicitEpisode=1 movie=1 localeReloads=2 resumePresent=\(canonical.serverResumeEpisode != nil) reads=\(counts.reads) blocked=\(counts.blocked)")
    }

    func testLiveCombinedSourcesConvergeAndPreserveExplicitSwitch() async throws {
        let http = LiveHomeReadOnlyHTTP()
        let first = try await LiveHomeReadOnlyAccount.connect(.jellyfin, http: http)
        let second = try await LiveHomeReadOnlyAccount.connect(.plex, http: http)
        let feed = try await first.provider.continueWatching(limit: 20).map { $0.taggingSource(first.account.id) }
        let (show, episode, _) = try await sampleSeries(first, feed: feed)
        let candidates = try await second.provider.search(query: show.title, limit: 20)
        let candidate = try XCTUnwrap(candidates.first { sameIdentity($0, show) },
                                     "The bounded live sample must include a verified second-server copy.")
        let copy = try await second.provider.item(id: candidate.id)
        XCTAssertTrue(sameIdentity(show, copy))
        let otherSeasons = try await second.provider.children(of: copy.id)
        let otherSeason = try XCTUnwrap(otherSeasons.first {
            $0.kind == .season && $0.seasonNumber == episode.seasonNumber
        })
        let otherEpisodes = try await second.provider.children(of: otherSeason.id)
        let otherEpisode = try XCTUnwrap(otherEpisodes.first {
            $0.kind == .episode && $0.episodeNumber == episode.episodeNumber
        })
        let fullEpisode = try await first.provider.item(id: episode.id).taggingSource(first.account.id)
        let fullOtherEpisode = try await second.provider.item(id: otherEpisode.id).taggingSource(second.account.id)
        XCTAssertTrue(fullEpisode.seriesID == show.id && fullOtherEpisode.seriesID == copy.id)
        XCTAssertTrue(show.id != copy.id, "The live pair must exercise differing provider-local parent IDs.")
        var mergedEpisode = fullEpisode
        mergedEpisode.sources = [
            .init(accountID: first.account.id, itemID: fullEpisode.id, kind: .episode,
                  versions: fullEpisode.versions),
            .init(accountID: second.account.id, itemID: fullOtherEpisode.id, kind: .episode,
                  versions: fullOtherEpisode.versions)
        ]
        let homeSelection = PlaybackSourceSelection.bestDetailItem(
            mergedEpisode, accounts: [first, second], identitySources: { _ in [] }
        )
        XCTAssertTrue(homeSelection.sourceAccountID == first.account.id && homeSelection.seriesID == show.id)
        let refs = [
            MediaSourceRef(accountID: first.account.id, itemID: show.id, kind: .series, versions: show.versions),
            MediaSourceRef(accountID: second.account.id, itemID: copy.id, kind: .series, versions: copy.versions)
        ]
        let environment = environment(accounts: [first, second], feed: feed, identities: [show, copy], sources: refs)
        let models = [
            try environment.makeViewModel(for: show, libraryOrigin: first.account.id),
            try environment.makeViewModel(for: copy, libraryOrigin: second.account.id),
            try environment.makeSeriesContextViewModel(
                seriesID: show.id, seed: episode, sourceAccountID: first.account.id, originAccountID: nil
            ),
            try environment.makeSeriesContextViewModel(
                seriesID: XCTUnwrap(homeSelection.seriesID), seed: homeSelection,
                sourceAccountID: homeSelection.sourceAccountID, originAccountID: nil
            )
        ]
        defer { models.forEach { $0.suspendEnrichment() } }
        for model in models { await model.load() }
        let canonical = try XCTUnwrap(models[0].state.value?.item)
        for model in models {
            let item = try XCTUnwrap(model.state.value?.item)
            XCTAssertTrue(item.id == canonical.id && item.sourceAccountID == canonical.sourceAccountID)
            XCTAssertTrue(sameEditorial(item, canonical))
            XCTAssertTrue(model.serverResumeEpisode?.id == models[0].serverResumeEpisode?.id)
        }
        let alternate = canonical.sourceAccountID == first.account.id ? second : first
        await models[0].switchToSource(accountID: alternate.account.id)
        XCTAssertTrue(models[0].state.value?.item.sourceAccountID == alternate.account.id)
        models[0].updateMetadataLanguage("en")
        await models[0].load()
        XCTAssertTrue(models[0].state.value?.item.sourceAccountID == alternate.account.id)
        let counts = await http.counts()
        XCTAssertEqual(counts.blocked, 0)
        print("LIVE_DETAIL combinedProviders=2 routes=4 mergedChildOwnership=true explicitSwitch=1 reads=\(counts.reads) blocked=\(counts.blocked)")
    }

    func testLiveFrenchMetadataAndEnglishReleaseAlias() async throws {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(
            url: try LiveHomeReadOnlyAccount.broker().appendingPathComponent("metadata"), timeoutInterval: 15
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        struct Configuration: Decodable { let tmdbBearerToken: String }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard !config.tmdbBearerToken.isEmpty else { throw AppError.invalidResponse }
        let provider = TMDbMetadataProvider(access: .directToken(config.tmdbBearerToken))
        let wrapped = ResilientEnrichmentProvider(
            base: TMDbEnrichmentProvider(provider: provider),
            breaker: ProviderCircuitBreaker(), cache: ProviderResultCache()
        )
        let pipeline = MetadataEnrichmentPipeline(providers: [wrapped], config: .init(order: [.tmdb]))
        var frenchEpisodeOverviews = Set<String>()
        for number in [34, 36] {
            let episode = MediaItem(
                id: "public-\(number)", title: "Sonic Boom", kind: .episode,
                seasonNumber: 1, episodeNumber: number, providerIDs: ["SeriesTmdb": "62211"]
            )
            let query = MetadataQuery(episode)
            let french = await pipeline.enrich(
                query.forMetadataLanguage("fr"), requesting: [.overview], tier: .foregroundFill
            )
            let english = await pipeline.enrich(
                query.forMetadataLanguage("en"), requesting: [.overview], tier: .foregroundFill
            )
            let frenchAgain = await pipeline.enrich(
                query.forMetadataLanguage("fr"), requesting: [.overview], tier: .foregroundFill
            )
            XCTAssertFalse(french.overview?.value.isEmpty ?? true)
            XCTAssertFalse(english.overview?.value.isEmpty ?? true)
            XCTAssertTrue(french.overview?.value != english.overview?.value)
            XCTAssertTrue(frenchAgain.overview?.value == french.overview?.value)
            XCTAssertTrue(french.overview?.sourceURL?.path == "/3/tv/62211/season/1/episode/\(number)")
            if let overview = french.overview?.value { frenchEpisodeOverviews.insert(overview) }
            let series = await pipeline.enrich(
                query.seriesScoped.forMetadataLanguage("fr"), requesting: [.overview], tier: .foregroundFill
            )
            XCTAssertFalse(series.overview?.value.isEmpty ?? true)
            XCTAssertTrue(series.overview?.sourceURL?.path == "/3/tv/62211")
            XCTAssertTrue(series.overview?.value != french.overview?.value)
        }
        XCTAssertEqual(frenchEpisodeOverviews.count, 2, "Distinct episodes must not receive the parent synopsis.")
        let alias = MediaItem(id: "public-movie", title: "Spirited Away", kind: .movie, productionYear: 2001)
        var exact = alias
        exact.providerIDs = ["Tmdb": "129"]
        let found = try await provider.detailMetadata(
            for: MetadataQuery(alias).forMetadataLanguage("fr"), missing: [.overview]
        )
        let expected = try await provider.detailMetadata(
            for: MetadataQuery(exact).forMetadataLanguage("fr"), missing: [.overview]
        )
        XCTAssertFalse(found.overview?.value.isEmpty ?? true)
        XCTAssertTrue(found.overview?.value == expected.overview?.value)
        print("LIVE_DETAIL publicMetadata frenchEpisodes=2 cacheLanguageIsolation=true englishReleaseAlias=true")
    }

    private func sampleSeries(
        _ account: ResolvedAccount, feed: [MediaItem]
    ) async throws -> (MediaItem, MediaItem, MediaItem?) {
        let provider = account.provider
        let show: MediaItem
        if let current = feed.first(where: { $0.kind == .episode && $0.seriesID != nil }),
           let id = current.seriesID {
            show = try await provider.item(id: id)
        } else {
            let libraries = try await provider.libraries()
            let library = try XCTUnwrap(libraries.first { $0.kind == .series })
            let page = try await provider.items(in: library.id, kind: .series, page: .init(limit: 5))
            show = try await provider.item(id: XCTUnwrap(page.items.first { $0.kind == .series }).id)
        }
        let children = try await provider.children(of: show.id).map { $0.taggingSource(account.account.id) }
        if let episode = children.last(where: { $0.kind == .episode }) {
            return (show.taggingSource(account.account.id), episode, nil)
        }
        let season = try XCTUnwrap(children.first { $0.kind == .season && ($0.seasonNumber ?? 0) > 0 })
        let episodes = try await provider.children(of: season.id).map { $0.taggingSource(account.account.id) }
        let episode = try XCTUnwrap(episodes.last { $0.kind == .episode })
        return (show.taggingSource(account.account.id), episode, season)
    }

    private func environment(
        accounts: [ResolvedAccount], feed: [MediaItem], identities: [MediaItem] = [], sources: [MediaSourceRef] = []
    ) -> DetailOpenEnvironment {
        let providers = Dictionary(uniqueKeysWithValues: accounts.map { ($0.account.id, $0.provider) })
        return DetailOpenEnvironment(
            resolveProvider: { accountID in
                guard let accountID, let provider = providers[accountID] else { throw AppError.unauthorized }
                return provider
            },
            resolveOptionalProvider: { providers[$0] },
            identitySources: { item in
                identities.contains(where: {
                    $0.kind == item.kind && !Set(MediaItemIdentity.identities(for: $0))
                        .isDisjoint(with: MediaItemIdentity.identities(for: item))
                }) ? sources : []
            },
            crossServerSourceResolver: nil, continueWatchingSnapshot: { feed },
            metadataLanguage: "fr", onlineTrailerResolver: { _ in [] }
        )
    }

    private func sameIdentity(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let left = MediaItemIdentity.identities(for: a)
        let right = MediaItemIdentity.identities(for: b)
        return a.kind == b.kind && !Set(left).isDisjoint(with: right)
            && !MediaItemIdentity.externalIdentitiesConflict(left, right)
    }

    private func sameEditorial(_ a: MediaItem, _ b: MediaItem) -> Bool {
        a.title == b.title && a.overview == b.overview && a.genres == b.genres
            && a.people == b.people && a.studios == b.studios
    }
}
#endif
