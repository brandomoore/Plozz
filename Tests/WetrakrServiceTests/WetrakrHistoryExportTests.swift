import CoreModels
import CoreNetworking
import CoreTrackerAuth
import Foundation
import XCTest
@testable import WetrakrService
@testable import TestSupportNetworking

final class WetrakrHistoryExportTests: XCTestCase {
    private let date = "2020-01-02T03:04:05.000Z"
    private let target = WetrakrHistoryExportTarget(userID: 42, mediaID: 10, kind: .movie)
    private let emptyHistory = #"{"data":[],"meta":{"page":1,"limit":20,"total":0,"totalPages":0}}"#
    private let movie = MediaItem(
        id: "movie", title: "Fixture movie", kind: .movie, isPlayed: true,
        providerIDs: ["Tmdb": "550"], lastPlayedAt: Date(timeIntervalSince1970: 1_577_934_245)
    )
    private let episode = MediaItem(
        id: "episode", title: "Fixture episode", kind: .episode, seasonNumber: 0, episodeNumber: 1,
        isPlayed: true, providerIDs: ["Tmdb": "200", "SeriesTmdb": "100"]
    )

    private func media(_ kind: MediaItemKind = .movie, status: String = "none") -> String {
        let fields: String
        switch kind {
        case .episode: fields = #""id":20,"type":"episode","media_id":30,"season_number":0,"number":1,"ids":{"tmdb":200}"#
        case .series: fields = #""id":30,"type":"show","ids":{"tmdb":100}"#
        default: fields = #""id":10,"type":"movie","ids":{"tmdb":550}"#
        }
        return #"{\#(fields),"interactions":{"user":{"tracking":{"last":{"status":"\#(status)"}}}}}"#
    }

    private func history(kind: String = "movie", unknown: Bool = false, count: Int = 1) -> String {
        """
        {"data":[{"date":"\(date)","tracks":[{"_track_log_id":"play","target":"\(kind)","status":"watched",
        "tracked_at":"\(date)","tracked_at_unknown":\(unknown)}]}],
        "meta":{"page":1,"limit":20,"total":\(count),"totalPages":\(count)}}
        """
    }

    private func acknowledgement(kind: String = "movie", id: Int = 10) -> String {
        #"{"added":{"plays":[{"type":"\#(kind)","id":\#(id),"play_id":"play","watched_at":"\#(date)"}]}}"#
    }

    private func http(
        movies: [String]? = nil, parents: [String]? = nil, children: [String]? = nil,
        histories: [String]? = nil, acknowledgements: [String]? = nil
    ) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/account/settings", json: #"{"id":42,"info":{"username":"fixture"}}"#)
        http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
        for path in [
            "/sync/tracking/watched/history/movies", "/sync/tracking/watched/history/episodes",
            "/sync/tracking/playing/movies", "/sync/tracking/playing/episodes",
            "/sync/tracking/planning/movies", "/sync/tracking/planning/shows",
            "/sync/tracking/dropped/movies", "/sync/tracking/dropped/shows", "/sync/tracking/hold/shows"
        ] { http.stub(pathSuffix: path, json: "[]", headers: ["X-Pagination-Item-Count": "0"]) }
        http.stub(pathSuffix: "/media/external/tmdb/550", json: #"{"id":10,"type":"movie"}"#)
        http.stub(pathSuffix: "/media/external/tmdb/100", json: #"{"id":30,"type":"show"}"#)
        for body in movies ?? [media()] { http.stub(pathSuffix: "/movies/10", json: body) }
        for body in parents ?? [media(.series)] { http.stub(pathSuffix: "/shows/30", json: body) }
        for body in children ?? [media(.episode)] {
            http.stub(pathSuffix: "/shows/30/seasons/0/episodes/1", json: body)
            http.stub(pathSuffix: "/episodes/20", json: body)
        }
        for body in histories ?? [emptyHistory] {
            http.stub(pathSuffix: "/movies/10/tracking/history", json: body)
            http.stub(pathSuffix: "/episodes/20/tracking/history", json: body)
        }
        for body in acknowledgements ?? [acknowledgement()] { http.stub(pathSuffix: "/sync/tracking", json: body) }
        return http
    }

    private func client(_ http: any HTTPClient) -> WetrakrClient {
        .init(config: .init(clientID: "history-export-fixture"), http: http, gate: .init())
    }

    func testMovieResolutionUsesExactCatalogIdentityAndAuthenticatedKind() async throws {
        let http = http()
        let adapter = WetrakrHistoryExportAdapter(client: client(http))
        let resolved = try await adapter.resolve(movie, accessToken: "fixture", validateScope: {})
        XCTAssertEqual(resolved, target)
        XCTAssertEqual(http.sentPaths, ["/account/settings", "/media/external/tmdb/550", "/movies/10", "/account/settings"])
        XCTAssertEqual(http.sent[1].queryItems, [.init(name: "type", value: "movie")])
        XCTAssertEqual(http.sent[2].queryItems, [.init(name: "extended", value: "interactions")])
        let state = try await adapter.state(resolved, accessToken: "fixture", validateScope: {})
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertFalse(state.isPlaying)
    }

    func testEpisodeRequiresDistinctEpisodeAndParentIDsAlongsideExactCoordinates() async throws {
        let http = http()
        let adapter = WetrakrHistoryExportAdapter(client: client(http))
        let resolved = try await adapter.resolve(episode, accessToken: "fixture", validateScope: {})
        XCTAssertEqual(resolved, .init(userID: 42, mediaID: 20, kind: .episode))
        XCTAssertTrue(http.sentPaths.contains("/shows/30/seasons/0/episodes/1"))
        XCTAssertTrue(http.sentPaths.contains("/episodes/20"))
        XCTAssertEqual(http.sent.first { $0.path == "/media/external/tmdb/100" }?.queryItems, [.init(name: "type", value: "show")])
        for (own, parent, number) in [(100, 100, 1), (201, 100, 1), (200, 101, 1), (200, 100, 2)] {
            let bad = httpForEpisode(own: own, parent: parent, number: number)
            do {
                _ = try await WetrakrHistoryExportAdapter(client: client(bad)).resolve(
                    episode, accessToken: "fixture", validateScope: {}
                )
                XCTFail("Coordinates alone or conflicting catalog IDs must not authorize export")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            XCTAssertFalse(bad.sentPaths.contains("/sync/tracking"))
        }
    }

    private func httpForEpisode(own: Int, parent: Int, number: Int) -> RecordingHTTPClient {
        http(
            parents: [media(.series).replacingOccurrences(of: #""tmdb":100"#, with: #""tmdb":\#(parent)"#)],
            children: [media(.episode).replacingOccurrences(of: #""tmdb":200"#, with: #""tmdb":\#(own)"#)
                .replacingOccurrences(of: #""number":1"#, with: #""number":\#(number)"#)]
        )
    }

    func testUnsupportedSourcesNeverMakeRequests() async {
        for (kind, ids) in [
            (MediaItemKind.movie, [:]), (.movie, ["Tmdb": "0"]), (.movie, ["Imdb": "../bad"]),
            (.series, ["Tmdb": "550"]), (.episode, ["Tmdb": "100"])
        ] {
            let http = RecordingHTTPClient()
            let item = MediaItem(id: "item", title: "Same title", kind: kind, providerIDs: ids)
            XCTAssertFalse(WetrakrHistoryExportAdapter.supports(item))
            do {
                _ = try await WetrakrHistoryExportAdapter(client: client(http)).resolve(item, accessToken: "fixture", validateScope: {})
                XCTFail("Unsupported source")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            XCTAssertTrue(http.sent.isEmpty)
        }
    }

    func testWrongKindsMissingInteractionsAndContradictoryCatalogIDsFailClosed() async {
        for body in [
            media().replacingOccurrences(of: #""type":"movie""#, with: #""type":"show""#),
            media().replacingOccurrences(of: #""tmdb":550"#, with: #""tmdb":551"#),
            media().replacingOccurrences(of: #""id":10"#, with: #""id":11"#),
            #"{"id":10,"type":"movie","ids":{"tmdb":550}}"#,
            #"{"id":10,"type":"movie","ids":{"tmdb":550},"interactions":{}}"#
        ] {
            let http = http(movies: [body])
            do {
                _ = try await WetrakrHistoryExportAdapter(client: client(http)).resolve(movie, accessToken: "fixture", validateScope: {})
                XCTFail("Unverified metadata")
            } catch { XCTAssertTrue(error is TrackerHistoryError || error is TrackerHistoryExportError) }
            XCTAssertFalse(http.sentPaths.contains("/sync/tracking"))
        }
        var contradictory = movie
        contradictory.providerIDs["Imdb"] = "tt123"
        let http = http(movies: [media().replacingOccurrences(of: #""tmdb":550"#, with: #""tmdb":550,"imdb":"tt999""#)])
        http.stub(pathSuffix: "/media/external/imdb/tt123", json: #"{"id":10,"type":"movie"}"#)
        do {
            _ = try await WetrakrHistoryExportAdapter(client: client(http)).resolve(contradictory, accessToken: "fixture", validateScope: {})
            XCTFail("The resolver's first ID does not prove every ID agrees")
        } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
    }

    func testCurrentListStatesProtectMoviesWithoutInventingWatches() async throws {
        for status in ["planning", "dropped", "paused", "playing", "watched"] {
            let adapter = WetrakrHistoryExportAdapter(client: client(http(movies: [media(status: status)])))
            let target = try await adapter.resolve(movie, accessToken: "fixture", validateScope: {})
            let state = try await adapter.state(target, accessToken: "fixture", validateScope: {})
            XCTAssertEqual(state.observations.count, 1)
            XCTAssertFalse(state.isWatched, "Only actual play history proves a watch")
            XCTAssertEqual(state.isPlaying, status == "playing")
        }
    }

    func testExplicitParentChoicesProtectEpisodesButDerivedStatesDoNot() async throws {
        for status in ["planning", "hold", "paused", "dropped", "watching", "waiting", "watched", "none"] {
            let adapter = WetrakrHistoryExportAdapter(client: client(http(parents: [media(.series, status: status)])))
            let target = try await adapter.resolve(episode, accessToken: "fixture", validateScope: {})
            let state = try await adapter.state(target, accessToken: "fixture", validateScope: {})
            XCTAssertEqual(state.observations.count, ["planning", "hold", "paused", "dropped"].contains(status) ? 1 : 0)
            XCTAssertFalse(state.isWatched)
        }
    }

    func testOnlyExplicitlyEmptyCompleteHistoryProvesAbsence() async throws {
        for body in [
            #"{"data":[]}"#,
            emptyHistory.replacingOccurrences(of: #""total":0"#, with: #""total":1"#),
            emptyHistory.replacingOccurrences(of: #""totalPages":0"#, with: #""totalPages":2"#),
            emptyHistory.replacingOccurrences(of: #""page":1"#, with: #""page":2"#),
            history(kind: "episode"),
            history().replacingOccurrences(of: date, with: "unknown"),
            #"{"data":[{"tracks":[]}],"meta":{"page":1,"limit":20,"total":0,"totalPages":0}}"#
        ] {
            let adapter = WetrakrHistoryExportAdapter(client: client(http(histories: [body])))
            let target = try await adapter.resolve(movie, accessToken: "fixture", validateScope: {})
            do {
                _ = try await adapter.state(target, accessToken: "fixture", validateScope: {})
                XCTFail("Incomplete history or malformed play")
            } catch { XCTAssertTrue(error is TrackerHistoryError || (error as? AppError) == .invalidResponse) }
        }
        for unknown in [false, true] {
            let adapter = WetrakrHistoryExportAdapter(client: client(http(histories: [history(unknown: unknown, count: 100)])))
            let target = try await adapter.resolve(movie, accessToken: "fixture", validateScope: {})
            let state = try await adapter.state(target, accessToken: "fixture", validateScope: {})
            XCTAssertTrue(state.isWatched, "One play proves presence, not complete history")
            let expectedDate = unknown ? nil : try WetrakrDate.parse(date)
            XCTAssertTrue(state.containsWatch(at: expectedDate))
        }
    }

    func testOwnerChangesAndFreshMetadataChangesRejectPreviouslyResolvedTargets() async throws {
        for ownerChanged in [false, true] {
            let http = http(movies: [media(), media().replacingOccurrences(of: #""tmdb":550"#, with: #""tmdb":999"#)])
            let adapter = WetrakrHistoryExportAdapter(client: client(http))
            let target = try await adapter.resolve(movie, accessToken: "fixture", validateScope: {})
            if ownerChanged {
                http.stub(pathSuffix: "/account/settings", json: #"{"id":43,"info":{"username":"other"}}"#)
                _ = try await client(http).send(Endpoint(path: "/account/settings"), accessToken: "fixture")
            }
            do {
                _ = try await adapter.state(target, accessToken: "fixture", validateScope: {})
                XCTFail("Stale identity")
            } catch {
                if ownerChanged { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
                else { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            }
        }
    }

    func testExportSnapshotRetainsCompletePlanningDroppedAndHeldListsAndReusesActivityCache() async throws {
        let http = http()
        let paths = [
            ("planning/movies", "movie", "planning"), ("planning/shows", "show", "planning"),
            ("dropped/movies", "movie", "dropped"), ("dropped/shows", "show", "dropped"),
            ("hold/shows", "show", "hold")
        ]
        // Consume the initial empty fixture responses before replacing them.
        for (index, (path, kind, status)) in paths.enumerated() {
            http.stub(pathSuffix: "/sync/tracking/\(path)",
                      json: #"[{"id":\#(index + 1),"type":"\#(kind)","ids":{"tmdb":550},"status":"\#(status)"}]"#,
                      headers: ["X-Pagination-Item-Count": "1"])
            _ = try await client(http).send(Endpoint(path: "/sync/tracking/\(path)"), accessToken: "fixture")
        }
        let adapter = WetrakrHistoryExportAdapter(client: client(http))
        let first = try await adapter.snapshot(accessToken: "fixture", connectionID: "connection", validateScope: {})
        XCTAssertEqual(first.observations.count, 5)
        XCTAssertTrue(first.observations.allSatisfy { if case .listState = $0.fact { return true }; return false })
        let second = try await adapter.snapshot(accessToken: "fixture", connectionID: "connection", validateScope: {})
        XCTAssertEqual(second.observations, first.observations)
        for (path, _, _) in paths { XCTAssertEqual(http.sentPaths.filter { $0 == "/sync/tracking/\(path)" }.count, 2) }
        XCTAssertEqual(http.sentPaths.filter { $0 == "/sync/tracking/playing/movies" }.count, 2)
    }

    @MainActor
    func testKnownAndUnknownWritesUseExplicitDatesAndNeverAllowRewatchOrExpandSeries() async throws {
        for kind in [MediaItemKind.movie, .episode] {
            for unknown in [false, true] {
                let http = RecordingHTTPClient()
                let id = kind == .movie ? 10 : 20
                http.stub(pathSuffix: "/sync/tracking", json: acknowledgement(kind: kind == .movie ? "movie" : "episode", id: id))
                let transport = ExportHTTP(http: http)
                try await client(transport).exportHistory(
                    .init(userID: 42, mediaID: id, kind: kind), date: unknown ? nil : WetrakrDate.parse(date),
                    idempotencyKey: "fixture-idempotency", accessToken: "fixture", authorize: {}, validateScope: {}
                )
                let request = try XCTUnwrap(http.sent.first)
                let body = try XCTUnwrap(request.json)
                XCTAssertEqual(body["allow_rewatch"] as? Bool, false)
                let items = try XCTUnwrap(body[kind == .movie ? "movies" : "episodes"] as? [[String: Any]])
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items[0]["id"] as? Int, id)
                XCTAssertEqual(items[0]["status"] as? String, "watched")
                XCTAssertEqual(items[0]["tracked_at"] as? String, unknown ? nil : date)
                XCTAssertEqual(items[0]["tracked_at_unknown"] as? Bool, unknown ? true : nil)
                XCTAssertEqual(Set(body.keys), ["allow_rewatch", kind == .movie ? "movies" : "episodes"])
                XCTAssertEqual(Set(items[0].keys), ["id", "status", unknown ? "tracked_at_unknown" : "tracked_at"])
                XCTAssertEqual(request.headers["Idempotency-Key"], "fixture-idempotency")
                XCTAssertEqual(transport.posts, 1)
            }
        }
    }

    func testMalformedWrongTargetDuplicateAndPartialAcknowledgementsRemainUncertain() async {
        for payload in [
            "{}", #"{"added":{"watched":{"movies":1}}}"#,
            acknowledgement(id: 11), acknowledgement(kind: "episode"),
            acknowledgement().replacingOccurrences(of: #""play_id":"play""#, with: #""play_id":"""#),
            #"{"errored":{"movies":[{"id":10,"error":"Already watched!"}]}}"#,
            #"{"added":{"plays":[]},"notFound":{"movies":[{"id":10}]}}"#
        ] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/tracking", json: payload)
            do {
                try await client(http).exportHistory(target, date: nil, idempotencyKey: "fixture", accessToken: "fixture",
                                                     authorize: {}, validateScope: {})
                XCTFail("Unverified acknowledgement")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .uncertainWrite) }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    @MainActor
    func testRefusalsUndeliveredRequestsAndPostDispatchFailuresAreDistinct() async {
        for status in [401, 403, 418, 423, 429, 500, 204] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/tracking", json: "{}", status: status, headers: ["Retry-After": "60"])
            do {
                try await client(http).exportHistory(target, date: nil, idempotencyKey: "fixture", accessToken: "fixture",
                                                     authorize: {}, validateScope: {})
                XCTFail("Refusal")
            } catch {
                let expected: TrackerHistoryExportError = status == 401 ? .notWritten(.unauthorized)
                    : [403, 418, 423].contains(status) ? .notWritten(.accessRestricted)
                    : status == 429 ? .notWritten(.rateLimited(retryAfter: 60)) : .uncertainWrite
                XCTAssertEqual(error as? TrackerHistoryExportError, expected)
            }
        }
        for beforeDispatch in [false, true] {
            let transport = ExportHTTP(http: http())
            transport.failBeforePost = beforeDispatch
            transport.failAfterPost = !beforeDispatch
            do {
                try await client(transport).exportHistory(target, date: nil, idempotencyKey: "fixture", accessToken: "fixture",
                                                          authorize: {}, validateScope: {})
                XCTFail("Transport failure")
            } catch {
                XCTAssertEqual(error as? TrackerHistoryExportError,
                               beforeDispatch ? .notWritten(.serverUnreachable) : .uncertainWrite)
            }
        }
    }

    func testBothFullAuthorizationAndQueuedScopeCheckPreventDispatch() async {
        for atGate in [false, true] {
            let http = http()
            do {
                try await client(http).exportHistory(
                    target, date: nil, idempotencyKey: "fixture", accessToken: "fixture",
                    authorize: { if !atGate { throw TrackerHistoryError.scopeChanged } },
                    validateScope: { if atGate { throw TrackerHistoryError.scopeChanged } }
                )
                XCTFail("Revoked scope")
            } catch {
                if atGate { XCTAssertEqual(error as? TrackerHistoryExportError, .notWritten(.conflict)) }
                else { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
            }
            XCTAssertTrue(http.sent.isEmpty)
        }
    }

    func testNetworkAuthorizationDoesNotRecursivelyAcquireHeldWriteGate() async throws {
        let http = http()
        let client = client(http)
        let probe = ExportAuthorizationProbe(client: client)
        do {
            try await client.exportHistory(
                target, date: nil, idempotencyKey: "fixture", accessToken: "fixture",
                authorize: { try await probe.authorize() },
                validateScope: {}
            )
        } catch {
            await probe.finish()
            throw error
        }
        await probe.finish()
        XCTAssertEqual(http.sentPaths, ["/account/settings", "/sync/tracking"])
    }

    @MainActor
    func testProductionRefreshKeepsGrantAndRejectsReplacementDuringRefresh() async throws {
        for replacing in [false, true] {
            let http = http()
            http.stub(pathSuffix: "/oauth/token/refresh", json:
                #"{"access_token":"refreshed","refresh_token":"rotated","expires_in":3600,"token_type":"bearer"}"#)
            let original = TrackerTokens(accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture)
            let tokens = InMemoryTrackerTokenStore(tokens: original)
            let transport = ExportHTTP(http: http)
            let service = WetrakrService(
                config: .init(clientID: UUID().uuidString), http: transport, tokenStore: tokens, coordinator: .init()
            )
            await service.refreshStatus()
            let identity = service.historySyncIdentity
            let session = try service.makeHistoryExportSession(source: source(movie), store: store())
            var expired = original
            expired.expiresAt = .distantPast
            try tokens.save(expired)
            transport.afterSend = { path in
                if replacing, path == "/oauth/token/refresh" {
                    try tokens.save(.init(accessToken: "other", refreshToken: "other", expiresAt: .distantFuture))
                }
            }
            await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            if replacing {
                XCTAssertTrue(session.error is CancellationError)
                XCTAssertFalse(http.sentPaths.contains("/sync/last_activities"))
                XCTAssertEqual(tokens.load()?.accessToken, "other")
            } else {
                XCTAssertNil(session.error)
                XCTAssertEqual(service.historySyncIdentity, identity)
                XCTAssertEqual(tokens.load()?.accessToken, "refreshed")
            }
            XCTAssertEqual(http.sentPaths.filter { $0 == "/oauth/token/refresh" }.count, 1)
        }
    }

    @MainActor
    func testNewParentHoldAtFinalAuthorizationStopsEpisodeWrite() async throws {
        let http = http(parents: Array(repeating: media(.series), count: 4) + [media(.series, status: "hold")])
        let transport = ExportHTTP(http: http)
        let service = service(transport)
        await service.refreshStatus()
        let session = try service.makeHistoryExportSession(source: source(episode), store: store())
        await session.compare(accountID: "account", library: .init(id: "library", title: "Shows", kind: .series))
        XCTAssertEqual(session.rows.map(\.status), [.ready])
        await session.apply(rowIDs: Set(session.rows.map(\.id)), confirmed: true)
        XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview)
        XCTAssertEqual(transport.posts, 0)
    }

    @MainActor
    func testTwoEpisodeExportContinuesAfterTheFirstPlayDerivesParentWatchingState() async throws {
        var second = episode
        second.id = "episode-2"
        second.episodeNumber = 2
        second.providerIDs["Tmdb"] = "201"
        let secondMedia = media(.episode)
            .replacingOccurrences(of: #""id":20"#, with: #""id":21"#)
            .replacingOccurrences(of: #""number":1"#, with: #""number":2"#)
            .replacingOccurrences(of: #""tmdb":200"#, with: #""tmdb":201"#)
        let histories = Array(repeating: emptyHistory, count: 3) + [history(kind: "episode", unknown: true)]
        let http = http(
            parents: Array(repeating: media(.series), count: 8) + [media(.series, status: "watching")],
            histories: histories,
            acknowledgements: [acknowledgement(kind: "episode", id: 20), acknowledgement(kind: "episode", id: 21)]
        )
        http.stub(pathSuffix: "/shows/30/seasons/0/episodes/2", json: secondMedia)
        http.stub(pathSuffix: "/episodes/21", json: secondMedia)
        for history in histories { http.stub(pathSuffix: "/episodes/21/tracking/history", json: history) }
        let transport = ExportHTTP(http: http)
        let service = service(transport)
        await service.refreshStatus()
        let session = try service.makeHistoryExportSession(source: source(episode, additional: [second]), store: store())
        await session.compare(accountID: "account", library: .init(id: "library", title: "Shows", kind: .series))
        XCTAssertEqual(session.rows.map(\.status), [.ready, .ready])
        await session.apply(rowIDs: Set(session.rows.map(\.id)), confirmed: true)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.outcomes.count, 2)
        XCTAssertTrue(session.outcomes.values.allSatisfy { if case .confirmed = $0 { return true }; return false })
        XCTAssertEqual(transport.posts, 2)
    }

    @MainActor
    func testProductionFactoryRequiresConsentAndIndependentReadbackForKnownAndUnknownDates() async throws {
        for unknown in [false, true] {
            var item = movie
            if unknown { item.lastPlayedAt = nil }
            let http = http(histories: Array(repeating: emptyHistory, count: 3) + [history(unknown: unknown)])
            let transport = ExportHTTP(http: http)
            let service = service(transport)
            await service.refreshStatus()
            let session = try service.makeHistoryExportSession(source: source(item), store: store())
            XCTAssertEqual(http.sent.count, 1)
            await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [.ready])
            let selection = Set(session.rows.map(\.id))
            await session.apply(rowIDs: selection, confirmed: false)
            XCTAssertEqual(transport.posts, 0)
            await session.apply(rowIDs: selection, confirmed: true)
            XCTAssertNil(session.error)
            if case .confirmed? = session.outcomes.values.first {} else { XCTFail("No independently verified watch date") }
            XCTAssertEqual(transport.posts, 1)
            XCTAssertEqual(Array(http.sentPaths.suffix(4)), ["/account/settings", "/movies/10", "/movies/10/tracking/history", "/account/settings"])
        }
    }

    @MainActor
    func testLostReplyAndLaterRemoteDeletionNeverReplayCanonicalReceiptAfterMetadataChanges() async throws {
        let http = http(histories: Array(repeating: emptyHistory, count: 3) + [history(), emptyHistory])
        let transport = ExportHTTP(http: http)
        transport.failAfterPost = true
        let service = service(transport)
        await service.refreshStatus()
        let store = try store()
        let session = try service.makeHistoryExportSession(source: source(movie), store: store)
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        await session.apply(rowIDs: Set(session.rows.map(\.id)), confirmed: true)
        XCTAssertNil(session.error)
        if case .alreadyPresent? = session.outcomes.values.first {} else { XCTFail("Presence is not authorship") }
        var renamed = movie
        renamed.title = "Changed server metadata"
        let replay = try service.makeHistoryExportSession(source: source(renamed), store: store)
        await replay.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertEqual(replay.rows.map(\.status), [.ready])
        await replay.apply(rowIDs: Set(replay.rows.map(\.id)), confirmed: true)
        XCTAssertEqual(replay.error as? TrackerHistoryExportError, .previousAttempt)
        XCTAssertEqual(transport.posts, 1)
    }

    @MainActor
    func testProductionFactoryRejectsForeignProfileAndRevokedServerAuthorization() async throws {
        let http = http()
        let service = service(http)
        await service.refreshStatus()
        XCTAssertThrowsError(try service.makeHistoryExportSession(source: source(movie, profileID: "other"), store: store()))
        let session = try service.makeHistoryExportSession(source: source(movie, authorized: false), store: store())
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        XCTAssertEqual(http.sent.count, 1)
    }

    @MainActor private func service(_ http: any HTTPClient) -> WetrakrService {
        .init(config: .init(clientID: UUID().uuidString), http: http,
              tokenStore: InMemoryTrackerTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture
              )), coordinator: .init())
    }

    @MainActor private func source(
        _ item: MediaItem, additional: [MediaItem] = [],
        profileID: String = ProfileStore.defaultProfileID, authorized: Bool = true
    ) -> TrackerServerHistorySource {
        let provider = ExportProvider(item: item, additional: additional)
        return .init(
            scope: .init(profile: .init(id: profileID, name: "Test"), accounts: [
                .init(id: "account", server: provider.session.server, userID: "viewer", userName: "Viewer", deviceID: "device")
            ]),
            accounts: [.init(id: "account", serverName: "Server", userName: "Viewer")],
            resolveProvider: { _ in provider }, isAuthorized: { authorized }, isPlaying: { _, _ in false }
        )
    }

    private func store() throws -> DurableLocalStateStore { try .init(secureStore: ExportSecureStore()) }
}

@MainActor private final class ExportHTTP: HTTPClient {
    let http: RecordingHTTPClient
    var failBeforePost = false
    var failAfterPost = false
    var posts = 0
    var afterSend: (@MainActor @Sendable (String) throws -> Void)?
    init(http: RecordingHTTPClient) { self.http = http }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
        if endpoint.path == "/sync/tracking", endpoint.method == .post {
            XCTAssertEqual(endpoint.path, "/sync/tracking")
            XCTAssertEqual(endpoint.maximumResponseBytes, 1_024 * 1_024)
            XCTAssertTrue(endpoint.reportsUndeliveredRequests)
            XCTAssertTrue(endpoint.redactsURLForLogging)
            if failBeforePost { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
            posts += 1
        }
        let response = try await http.sendRaw(endpoint, baseURL: baseURL)
        try afterSend?(endpoint.path)
        if endpoint.path == "/sync/tracking", endpoint.method == .post, failAfterPost { throw AppError.serverUnreachable }
        return response
    }
}

private actor ExportAuthorizationProbe {
    let client: WetrakrClient
    private var read: Task<Void, Error>?
    init(client: WetrakrClient) { self.client = client }

    func authorize() async throws {
        let done = XCTestExpectation(description: "Authorization can use the request gate before write admission")
        read = Task { [client] in
            defer { done.fulfill() }
            _ = try await client.send(Endpoint(path: "/account/settings"), accessToken: "fixture")
        }
        let result = await XCTWaiter.fulfillment(of: [done], timeout: 3)
        guard result == .completed else { throw TrackerHistoryError.scopeChanged }
        try await read?.value
    }

    func finish() async {
        read?.cancel()
        _ = await read?.result
        read = nil
    }
}

private final class ExportSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private actor ExportProvider: MediaProvider {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
    )
    let value: MediaItem
    let values: [MediaItem]
    init(item: MediaItem, additional: [MediaItem]) { value = item; values = [item] + additional }
    func libraries() async throws -> [MediaLibrary] {
        [.init(id: "library", title: "Library", kind: value.kind == .movie ? .movie : .series)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard let item = values.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: page.startIndex == 0 ? values : [], startIndex: page.startIndex, totalCount: values.count)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { XCTFail("No server or scrobble writes") }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
