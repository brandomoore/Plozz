import CoreModels
import CoreNetworking
import Foundation
import XCTest

@testable import TraktService

@MainActor
final class TraktHistoryExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_577_934_245)
    private var movie: MediaItem {
        .init(
            id: "movie", title: "Fixture", kind: .movie, isPlayed: true,
            providerIDs: ["Tmdb": "550"], lastPlayedAt: date)
    }
    private var episode: MediaItem {
        .init(
            id: "episode", title: "Episode", kind: .episode, seasonNumber: 0, episodeNumber: 1, isPlayed: true,
            providerIDs: ["Tvdb": "200", "SeriesTvdb": "100"], lastPlayedAt: date)
    }
    private var target: TraktHistoryExportTarget { .init(userID: "owner", mediaID: 10, kind: .movie) }
    private func client(_ http: TraktExportHTTP) -> TraktClient {
        .init(config: .init(clientID: "fixture"), http: http)
    }
    private func gate() -> TraktHistoryExportGate { .init(sleep: { _ in }) }

    func testMovieResolutionChecksPublicLookupAndCanonicalIdentity() async throws {
        let http = TraktExportHTTP()
        let adapter = TraktHistoryExportAdapter(client: client(http))
        let resolved = try await adapter.resolve(movie, token: "fixture", validate: {})
        XCTAssertEqual(resolved, target)
        XCTAssertEqual(
            http.requests.map(\.path), ["/users/settings", "/search/tmdb/550", "/movies/10", "/users/settings"])
        for request in http.requests where request.path != "/users/settings" {
            XCTAssertNil(request.headers["Authorization"])
            XCTAssertEqual(request.redirectPolicy, .sameOrigin)
            XCTAssertNotNil(request.maximumResponseBytes)
        }
        XCTAssertEqual(http.requests[1].queryItems.first { $0.name == "type" }?.value, "movie")
    }

    func testEpisodeResolutionRequiresDistinctExactEpisodeAndParentEvidence() async throws {
        let http = TraktExportHTTP()
        let adapter = TraktHistoryExportAdapter(client: client(http))
        let resolved = try await adapter.resolve(episode, token: "fixture", validate: {})
        XCTAssertEqual(resolved, .init(userID: "owner", mediaID: 20, kind: .episode))
        XCTAssertTrue(http.requests.contains { $0.path == "/shows/30/seasons/0/episodes/1" })
        for ids in [["Tvdb": "200"], ["Tvdb": "200", "SeriesTvdb": "999"]] {
            var invalid = episode
            invalid.providerIDs = ids
            do {
                _ = try await adapter.resolve(invalid, token: "fixture", validate: {})
                XCTFail("Unverified episode")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
        }
    }

    func testUndatedSourcesAndConflictingCatalogMetadataCannotBeExported() async throws {
        var undated = movie
        undated.lastPlayedAt = nil
        XCTAssertFalse(TraktHistoryExportAdapter.supports(undated))
        let http = TraktExportHTTP()
        http.movieTMDB = 999
        do {
            _ = try await TraktHistoryExportAdapter(client: client(http)).resolve(movie, token: "fixture", validate: {})
            XCTFail("Contradictory source")
        } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
        XCTAssertEqual(http.posts, 0)
    }

    func testExistingWatchlistPausedAndActivePlaybackAreProtected() async throws {
        for protection in ["watchlist", "paused", "active", "watched", "undated"] {
            let http = TraktExportHTTP()
            http.protection = protection
            let adapter = TraktHistoryExportAdapter(client: client(http))
            let resolved = try await adapter.resolve(movie, token: "fixture", validate: {})
            let state = try await adapter.state(resolved, token: "fixture", validate: {})
            if protection == "active" {
                XCTAssertTrue(state.isPlaying)
            } else {
                XCTAssertFalse(state.observations.isEmpty)
            }
            if protection == "undated" {
                XCTAssertTrue(state.isWatched)
                XCTAssertFalse(state.containsWatch(at: date), "Unavailable dates cannot prove a dated write")
            }
            XCTAssertEqual(http.posts, 0)
        }
    }

    func testIncompletePagingAndChangedOwnerNeverEstablishAbsence() async throws {
        let http = TraktExportHTTP()
        let adapter = TraktHistoryExportAdapter(client: client(http))
        let resolved = try await adapter.resolve(movie, token: "fixture", validate: {})
        http.omitPagination = true
        do {
            _ = try await adapter.state(resolved, token: "fixture", validate: {})
            XCTFail("Missing paging evidence")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        http.omitPagination = false
        http.owner = "different"
        do {
            _ = try await adapter.state(resolved, token: "fixture", validate: {})
            XCTFail("Owner changed")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
    }

    func testWriterSendsOneExplicitDatedNativeMovieOrEpisodeWithoutExpansion() async throws {
        for kind in [MediaItemKind.movie, .episode] {
            let http = TraktExportHTTP()
            let target = TraktHistoryExportTarget(userID: "owner", mediaID: kind == .movie ? 10 : 20, kind: kind)
            try await client(http).exportHistory(
                target, date: date, gate: gate(), accessToken: { "fixture" }, authorize: {}, validate: {}
            )
            let request = try XCTUnwrap(http.requests.last)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
            let key = kind == .movie ? "movies" : "episodes"
            XCTAssertEqual(Set(body.keys), [key])
            let entries = try XCTUnwrap(body[key] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(Set(entries[0].keys), ["ids", "watched_at"])
            XCTAssertEqual(entries[0]["ids"] as? [String: Int], ["trakt": target.mediaID])
            XCTAssertEqual((entries[0]["watched_at"] as? String).flatMap(TraktClient.parseTimestamp), date)
            XCTAssertNil(request.headers["Idempotency-Key"], "Trakt does not document this guarantee")
            XCTAssertTrue(request.reportsUndeliveredRequests)
            XCTAssertTrue(request.redactsURLForLogging)
            XCTAssertEqual(request.redirectPolicy, .doNotFollow)
        }
    }

    func testWriterRejectsUndatedAndRevokedAuthorizationBeforeSending() async {
        for hasDate in [false, true] {
            let http = TraktExportHTTP()
            do {
                try await client(http).exportHistory(
                    target, date: hasDate ? date : nil, gate: gate(), accessToken: { "fixture" },
                    authorize: { throw TrackerHistoryError.scopeChanged }, validate: {}
                )
                XCTFail("Unapproved write")
            } catch {
                XCTAssertEqual(error as? TrackerHistoryExportError, .notWritten(hasDate ? .conflict : .invalidResponse))
            }
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testResponseCountsRefusalsAndPostDispatchCancellationKeepCorrectReceipts() async {
        for mode in ["partial", "updated", "extra", "unrelated", "transport", "cancel", "not-sent", "301", "401", "429"] {
            let http = TraktExportHTTP()
            http.failure = mode
            do {
                try await client(http).exportHistory(
                    target, date: date, gate: gate(), accessToken: { "fixture" }, authorize: {}, validate: {}
                )
                XCTFail("Expected rejected or uncertain write")
            } catch {
                let expected: TrackerHistoryExportError
                switch mode {
                case "not-sent": expected = .notWritten(.serverUnreachable)
                case "401": expected = .notWritten(.unauthorized)
                case "429": expected = .notWritten(.rateLimited(retryAfter: 60))
                default: expected = .uncertainWrite
                }
                XCTAssertEqual(error as? TrackerHistoryExportError, expected, mode)
            }
        }
    }

    func testCooldownPreventsAnotherWriteAndSurvivesGateRecreation() async throws {
        let suite = "TraktExportGate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let http = TraktExportHTTP()
        http.failure = "429"
        for _ in 0..<2 {
            let gate = TraktHistoryExportGate(defaults: defaults, now: { now }, sleep: { _ in })
            do {
                try await client(http).exportHistory(
                    target, date: date, gate: gate, accessToken: { "fixture" }, authorize: {}, validate: {}
                )
                XCTFail("Cooldown required")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .notWritten(.rateLimited(retryAfter: 60))) }
        }
        XCTAssertEqual(http.posts, 1)
    }

    func testProductionFactoryRequiresConfirmationReadbackAndRetainsUncertainReplayFence() async throws {
        for failure in ["none", "transport", "cancel"] {
            let http = TraktExportHTTP()
            http.failure = failure
            let tokens = InMemoryTraktTokenStore(
                tokens: .init(
                    accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture,
                    accountIdentity: UUID().uuidString
                ))
            let service = TraktService(config: .init(clientID: "fixture"), http: http, tokenStore: tokens)
            await service.refreshStatus()
            let storage = try DurableLocalStateStore(secureStore: TraktExportStore())
            let session = try service.makeHistoryExportSession(source: source(), store: storage)
            await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [.ready])
            let selection = Set(session.rows.map(\.id))
            await session.apply(rowIDs: selection, confirmed: false)
            XCTAssertEqual(http.posts, 0)
            await session.apply(rowIDs: selection, confirmed: true)
            XCTAssertNil(session.error)
            if failure == "none" {
                if case .confirmed? = session.outcomes.values.first {} else { XCTFail("Independent date readback") }
            } else if case .alreadyPresent? = session.outcomes.values.first {
            } else {
                XCTFail("Presence is not authorship")
            }
            XCTAssertEqual(http.posts, 1)
            http.exported = false
            let replay = try service.makeHistoryExportSession(source: source(), store: storage)
            await replay.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            await replay.apply(rowIDs: Set(replay.rows.map(\.id)), confirmed: true)
            XCTAssertEqual(replay.error as? TrackerHistoryExportError, .previousAttempt)
            XCTAssertEqual(http.posts, 1)
        }
    }

    func testEpisodeFactoryVerifiesExactDatedEpisodeReadback() async throws {
        let http = TraktExportHTTP()
        let service = TraktService(
            config: .init(clientID: "fixture"), http: http,
            tokenStore: InMemoryTraktTokenStore(
                tokens: .init(
                    accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture
                ))
        )
        await service.refreshStatus()
        let session = try service.makeHistoryExportSession(
            source: source(item: episode), store: DurableLocalStateStore(secureStore: TraktExportStore())
        )
        await session.compare(accountID: "account", library: .init(id: "library", title: "Shows", kind: .series))
        XCTAssertNil(session.error)
        XCTAssertEqual(session.rows.map(\.status), [.ready])
        await session.apply(rowIDs: Set(session.rows.map(\.id)), confirmed: true)
        XCTAssertNil(session.error)
        if case .confirmed? = session.outcomes.values.first {} else { XCTFail("Exact episode readback required") }
        XCTAssertEqual(http.posts, 1)
    }

    func testProfileSwitchAwayAndBackDoesNotReviveExportApproval() async throws {
        let http = TraktExportHTTP()
        let service = TraktService(
            config: .init(clientID: "fixture"), http: http,
            tokenStore: InMemoryTraktTokenStore(
                tokens: .init(
                    accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture
                ))
        )
        await service.refreshStatus()
        let session = try service.makeHistoryExportSession(
            source: source(), store: DurableLocalStateStore(secureStore: TraktExportStore())
        )
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertEqual(session.rows.map(\.status), [.ready])
        await service.setActiveProfile(namespace: "different")
        await service.setActiveProfile(namespace: nil)
        await session.apply(rowIDs: Set(session.rows.map(\.id)), confirmed: true)
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        XCTAssertEqual(http.posts, 0)
    }

    func testAuthorizationIsRepeatedAfterWaitingForAnotherExport() async throws {
        let authorization = TraktExportAuthorization()
        let gate = TraktHistoryExportGate(sleep: { _ in await authorization.revoke() })
        let http = TraktExportHTTP()
        for attempt in 0..<2 {
            do {
                try await client(http).exportHistory(
                    target, date: date, gate: gate, accessToken: { "fixture" },
                    authorize: { try await authorization.requireCurrent() }, validate: {}
                )
                XCTAssertEqual(attempt, 0)
            } catch {
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(error as? TrackerHistoryExportError, .notWritten(.conflict))
            }
        }
        XCTAssertEqual(http.posts, 1)
    }

    func testWatchlistRemovalActivityInvalidatesCachedProtection() async throws {
        let http = TraktExportHTTP()
        let adapter = TraktHistoryExportAdapter(client: client(http))
        let resolved = try await adapter.resolve(movie, token: "fixture", validate: {})
        let first = try await adapter.state(resolved, token: "fixture", validate: {})
        XCTAssertTrue(first.observations.isEmpty)
        http.listChanged = true
        http.protection = "watchlist"
        let changed = try await adapter.state(resolved, token: "fixture", validate: {})
        XCTAssertFalse(changed.observations.isEmpty)
        http.listChanged = false
        http.protection = "none"
        let removed = try await adapter.state(resolved, token: "fixture", validate: {})
        XCTAssertTrue(removed.observations.isEmpty)
        XCTAssertEqual(http.requests.filter { $0.path == "/sync/watchlist/movies/added/desc" }.count, 3)
    }

    func testPlannedEpisodesAndSeasonsAreProtectedWithoutBlockingOtherSeasons() async throws {
        for list in ["episode", "season", "another-season"] {
            let http = TraktExportHTTP()
            http.protection = list
            let adapter = TraktHistoryExportAdapter(client: client(http))
            let resolved = try await adapter.resolve(episode, token: "fixture", validate: {})
            let state = try await adapter.state(resolved, token: "fixture", validate: {})
            XCTAssertEqual(state.observations.isEmpty, list == "another-season")
            XCTAssertEqual(http.posts, 0)
        }
    }

    private func source(item: MediaItem? = nil) -> TrackerServerHistorySource {
        let provider = TraktExportProvider(value: item ?? movie)
        return .init(
            scope: .init(
                profile: .init(id: ProfileStore.defaultProfileID, name: "Fixture"),
                accounts: [
                    .init(
                        id: "account", server: provider.session.server, userID: "viewer", userName: "Viewer",
                        deviceID: "device")
                ]),
            accounts: [.init(id: "account", serverName: "Server", userName: "Viewer")],
            resolveProvider: { _ in provider }, isAuthorized: { true }, isPlaying: { _, _ in false }
        )
    }
}

@MainActor
private final class TraktExportHTTP: HTTPClient {
    var requests: [Endpoint] = []
    var owner = "owner"
    var movieTMDB = 550
    var protection = "none"
    var omitPagination = false
    var failure = "none"
    var exported = false
    var posts = 0
    var watchedAt = "2020-01-02T03:04:05.000Z"
    var listChanged = false
    var exportedKind = "movies"
    private var movie: String { #"{"ids":{"trakt":10,"tmdb":\#(movieTMDB)}} "# }
    private let show = #"{"ids":{"trakt":30,"tvdb":100}}"#
    private let episode = #"{"season":0,"number":1,"ids":{"trakt":20,"tvdb":200}}"#

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let publicRead =
            endpoint.path.hasPrefix("/search/") || endpoint.path.hasPrefix("/movies/")
            || endpoint.path.hasPrefix("/shows/")
        if publicRead {
            XCTAssertNil(endpoint.headers["Authorization"])
        } else {
            XCTAssertEqual(endpoint.headers["Authorization"], "Bearer fixture")
        }
        var status = 200
        var headers: [String: String] = [:]
        let stamp = exported ? "2020-01-03T00:00:00.000Z" : "2020-01-02T00:00:00.000Z"
        let listStamp = listChanged ? "2020-01-04T00:00:00.000Z" : stamp
        let json: String
        switch endpoint.path {
        case "/users/settings": json = #"{"user":{"username":"fixture","ids":{"uuid":"\#(owner)"}}}"#
        case "/sync/last_activities":
            json =
                #"{"all":"\#(stamp)","movies":{"watched_at":"\#(stamp)","paused_at":"\#(stamp)"},"episodes":{"watched_at":"\#(stamp)","paused_at":"\#(stamp)"},"watchlist":{"updated_at":"\#(listStamp)"}}"#
        case "/search/tmdb/550": json = #"[{"type":"movie","movie":\#(movie)}]"#
        case "/search/tvdb/200": json = #"[{"type":"episode","show":\#(show),"episode":\#(episode)}]"#
        case "/movies/10": json = movie
        case "/shows/30": json = show
        case "/shows/30/seasons/0/episodes/1": json = episode
        case "/users/me/history", "/users/me/history/movies/10", "/users/me/history/episodes/20":
            let date = protection == "undated" ? "unavailable" : watchedAt
            let media =
                endpoint.path.contains("/episodes/") || exportedKind == "episodes"
                ? #""type":"episode","episode":\#(episode),"show":\#(show)"#
                : #""type":"movie","movie":\#(movie)"#
            json =
                exported || ["watched", "undated"].contains(protection)
                ? #"[{"id":1,"action":"watch","watched_at":"\#(date)",\#(media)}]"# : "[]"
        case "/sync/watchlist/movies/added/desc":
            json = protection == "watchlist" ? #"[{"id":3,"listed_at":"\#(stamp)","movie":\#(movie)}]"# : "[]"
        case "/sync/watchlist/shows/added/desc": json = "[]"
        case "/sync/watchlist/episodes/added/desc":
            json = protection == "episode"
                ? #"[{"id":4,"type":"episode","listed_at":"\#(stamp)","show":\#(show),"episode":\#(episode)}]"# : "[]"
        case "/sync/watchlist/seasons/added/desc":
            let number = protection == "another-season" ? 2 : 0
            json = ["season", "another-season"].contains(protection)
                ? #"[{"id":6,"type":"season","listed_at":"\#(stamp)","show":\#(show),"season":{"number":\#(number),"ids":{"trakt":40}}}]"# : "[]"
        case "/sync/playback":
            json =
                protection == "paused"
                ? #"[{"id":5,"type":"movie","progress":30,"paused_at":"\#(stamp)","movie":\#(movie)}]"# : "[]"
        case "/users/me/watching":
            status = protection == "active" ? 200 : 204
            json =
                protection == "active"
                ? #"{"type":"movie","action":"scrobble","started_at":"2020-01-02T00:00:00Z","expires_at":"2020-01-02T02:00:00Z","movie":\#(movie)}"#
                : ""
        case "/sync/history":
            if failure == "not-sent" { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
            posts += 1
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(endpoint.body)) as? [String: Any])
            let key = body["movies"] == nil ? "episodes" : "movies"
            exportedKind = key
            let entry = try XCTUnwrap((body[key] as? [[String: Any]])?.first)
            watchedAt = try XCTUnwrap(entry["watched_at"] as? String)
            exported = true
            if let code = Int(failure) { status = code }
            if status == 429 { headers["Retry-After"] = "60" }
            let count = failure == "extra" ? 2 : 1
            let movies = key == "movies" ? count : 0
            let episodes = key == "episodes" ? count : 0
            let updated = failure == "updated" ? 1 : 0
            let extra = failure == "unrelated" ? #","shows":1"# : ""
            json =
                failure == "partial"
                ? "{}"
                : #"{"added":{"movies":\#(movies),"episodes":\#(episodes)\#(extra)},"updated":{"movies":\#(updated),"episodes":0},"not_found":{"movies":[],"shows":[],"seasons":[],"episodes":[]}}"#
            if failure == "transport" { throw AppError.serverUnreachable }
            if failure == "cancel" { throw CancellationError() }
        default:
            XCTFail("Unexpected route \(endpoint.path)")
            throw AppError.notFound
        }
        if endpoint.path.hasPrefix("/search/") || endpoint.path.hasPrefix("/users/me/history")
            || endpoint.path.hasPrefix("/sync/watchlist") || endpoint.path == "/sync/playback"
        {
            if !omitPagination {
                let count = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any]).count
                headers = [
                    "X-Pagination-Page": "1", "X-Pagination-Limit": "100",
                    "X-Pagination-Page-Count": count == 0 ? "0" : "1", "X-Pagination-Item-Count": String(count),
                ]
            }
        }
        return (
            Data(json.utf8),
            try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers))
        )
    }
}

private final class TraktExportStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
    func string(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}

private actor TraktExportProvider: MediaProvider {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
    )
    let value: MediaItem
    init(value: MediaItem) { self.value = value }
    func libraries() async throws -> [MediaLibrary] {
        [.init(id: "library", title: "Movies", kind: value.kind == .episode ? .series : .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { value }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: page.startIndex == 0 ? [value] : [], startIndex: page.startIndex, totalCount: 1)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { XCTFail("No server writes") }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor TraktExportAuthorization {
    private var current = true
    func revoke() { current = false }
    func requireCurrent() throws {
        guard current else { throw TrackerHistoryError.scopeChanged }
    }
}
