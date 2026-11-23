import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import SimklService

@MainActor
final class SimklHistoryExportTests: XCTestCase {
    private let movie = MediaItem(
        id: "movie", title: "Fixture movie", kind: .movie, isPlayed: true, providerIDs: ["Tmdb": "550"]
    )
    private let target = SimklHistoryExportTarget(userID: 42, movieID: 10)

    private func client(_ http: SimklExportHTTP) -> SimklClient {
        let clock = SimklExportClock()
        return .init(config: .init(clientID: "fixture"), http: http, gate: .init(
            now: { clock.now() }, sleep: { clock.advance($0) }
        ))
    }

    func testResolverUsesUnfollowedPublicRedirectAndCorroboratingMovieMetadata() async throws {
        let http = SimklExportHTTP()
        let adapter = SimklHistoryExportAdapter(client: client(http), connectionID: "connection")
        let resolved = try await adapter.resolve(movie, token: "fixture", validate: {})
        XCTAssertEqual(resolved, target)
        let resolver = try XCTUnwrap(http.requests.first { $0.path == "/redirect" })
        XCTAssertEqual(resolver.redirectPolicy, .doNotFollow)
        XCTAssertNil(resolver.headers["Authorization"])
        XCTAssertEqual(resolver.queryItems.first { $0.name == "to" }?.value, "simkl")
        XCTAssertEqual(resolver.queryItems.first { $0.name == "type" }?.value, "movie")
        let state = try await adapter.state(target, token: "fixture", validate: {})
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertTrue(http.requests.allSatisfy { $0.method == .get })
    }

    func testUnsafeLocationsAndWrongCatalogsNeverResolve() async {
        for location in [
            "http://simkl.com/movies/10/title", "https://external.test/movies/10/title",
            "https://simkl.com/tv/10/title", "https://simkl.com/anime/10/title",
            "https://simkl.com/movies/0/title", "https://simkl.com/movies/10/title?to=watched",
            "https://simkl.com/movies/10/title/extra", "https://simkl.com:8443/movies/10/title"
        ] {
            let http = SimklExportHTTP()
            http.location = location
            do {
                _ = try await SimklHistoryExportAdapter(client: client(http), connectionID: "c")
                    .resolve(movie, token: "fixture", validate: {})
                XCTFail("Unverified redirect")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            XCTAssertFalse(http.requests.contains { $0.path == "/movies/10" })
        }
    }

    func testExactMetadataAndOwnerMustRemainCurrent() async throws {
        for ownerChange in [false, true] {
            let http = SimklExportHTTP()
            let adapter = SimklHistoryExportAdapter(client: client(http), connectionID: "c")
            _ = try await adapter.resolve(movie, token: "fixture", validate: {})
            if ownerChange { http.owner = 43 } else { http.tmdb = 551 }
            do {
                _ = try await adapter.state(target, token: "fixture", validate: {})
                XCTFail("Changed proof")
            } catch {
                if ownerChange { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
                else { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            }
            XCTAssertEqual(http.posts, 0)
        }
        let http = SimklExportHTTP()
        http.catalogType = "show"
        do {
            _ = try await SimklHistoryExportAdapter(client: client(http), connectionID: "c")
                .resolve(movie, token: "fixture", validate: {})
            XCTFail("Movie path is not proof of type")
        } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
    }

    func testUnsupportedEpisodesAndUnidentifiedMoviesNeverMakeRequests() async {
        for item in [
            MediaItem(id: "episode", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 1,
                      providerIDs: ["Tvdb": "200", "SeriesTvdb": "100"]),
            MediaItem(id: "movie", title: "Movie", kind: .movie)
        ] {
            let http = SimklExportHTTP()
            XCTAssertFalse(SimklHistoryExportAdapter.supports(item))
            do {
                _ = try await SimklHistoryExportAdapter(client: client(http), connectionID: "c")
                    .resolve(item, token: "fixture", validate: {})
                XCTFail("No verified target")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testSnapshotRetainsListChoicesAndPlaybackWithoutInventingWatches() async throws {
        for status in ["plantowatch", "dropped", "playing"] {
            let http = SimklExportHTTP()
            http.listState = status
            let adapter = SimklHistoryExportAdapter(client: client(http), connectionID: "c")
            _ = try await adapter.resolve(movie, token: "fixture", validate: {})
            let state = try await adapter.state(target, token: "fixture", validate: {})
            XCTAssertFalse(state.observations.isEmpty)
            XCTAssertFalse(state.isWatched)
            XCTAssertEqual(http.posts, 0)
        }
    }

    func testKnownAndUnknownDatesAreExplicitAndRewatchesStayDisabled() async throws {
        for date in [nil, Date(timeIntervalSince1970: 1_577_934_245)] {
            let http = SimklExportHTTP()
            try await client(http).exportHistory(target, date: date, token: "fixture", authorize: {}, validate: {})
            let request = try XCTUnwrap(http.requests.first)
            XCTAssertEqual(request.method, .post)
            XCTAssertEqual(request.path, "/sync/history")
            XCTAssertTrue(request.reportsUndeliveredRequests)
            XCTAssertEqual(request.redirectPolicy, .sameOrigin)
            XCTAssertTrue(request.redactsURLForLogging)
            XCTAssertEqual(request.maximumResponseBytes, 1_024 * 1_024)
            XCTAssertFalse(request.queryItems.contains { $0.name == "allow_rewatch" })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["movies"])
            let entry = try XCTUnwrap((body["movies"] as? [[String: Any]])?.first)
            XCTAssertEqual(Set(entry.keys), ["ids", "watched_at", "is_rewatch"])
            XCTAssertEqual(entry["is_rewatch"] as? Bool, false)
            XCTAssertEqual(try SimklHistoryDate.watchDate(try XCTUnwrap(entry["watched_at"] as? String)), date)
        }
    }

    func testPartialWrongTargetOrRewatchAcknowledgementsRemainUncertain() async {
        for kind in ["empty", "wrong-target", "partial", "rewatch", "expanded"] {
            let http = SimklExportHTTP()
            http.badAcknowledgement = kind
            do {
                try await client(http).exportHistory(target, date: nil, token: "fixture", authorize: {}, validate: {})
                XCTFail("Unproven delivery")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .uncertainWrite) }
            XCTAssertEqual(http.posts, 1)
        }
    }

    func testRefusalAndDeliveryUncertaintyRemainDistinct() async {
        for status in [401, 403, 429, 500] {
            let http = SimklExportHTTP()
            http.writeStatus = status
            do {
                try await client(http).exportHistory(target, date: nil, token: "fixture", authorize: {}, validate: {})
                XCTFail("Rejected response")
            } catch {
                let expected: TrackerHistoryExportError = status == 429 ? .notWritten(.rateLimited(retryAfter: 60))
                    : status == 500 ? .uncertainWrite : .notWritten(.unauthorized)
                XCTAssertEqual(error as? TrackerHistoryExportError, expected)
            }
        }
        for before in [false, true] {
            let http = SimklExportHTTP()
            http.failBefore = before
            http.failAfter = !before
            do {
                try await client(http).exportHistory(target, date: nil, token: "fixture", authorize: {}, validate: {})
                XCTFail("Transport failure")
            } catch {
                XCTAssertEqual(error as? TrackerHistoryExportError,
                               before ? .notWritten(.serverUnreachable) : .uncertainWrite)
            }
        }
    }

    func testFullAndDispatchAuthorizationPreventWrites() async {
        for dispatch in [false, true] {
            let http = SimklExportHTTP()
            do {
                try await client(http).exportHistory(
                    target, date: nil, token: "fixture",
                    authorize: { if !dispatch { throw TrackerHistoryError.scopeChanged } },
                    validate: { if dispatch { throw TrackerHistoryError.scopeChanged } }
                )
                XCTFail("Revoked scope")
            } catch {
                if dispatch { XCTAssertEqual(error as? TrackerHistoryExportError, .notWritten(.conflict)) }
                else { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
            }
            XCTAssertEqual(http.posts, 0)
        }
    }

    func testProductionFactoryRequiresConfirmationAndIndependentReadback() async throws {
        for failure in ["none", "transport", "cancellation"] {
            let http = SimklExportHTTP()
            http.failAfter = failure == "transport"
            http.cancelAfter = failure == "cancellation"
            let service = SimklService(config: .init(clientID: UUID().uuidString), http: http,
                                       tokenStore: InMemorySimklTokenStore(tokens: .init(accessToken: "fixture")))
            await service.refreshStatus()
            let store = try DurableLocalStateStore(secureStore: SimklExportStore())
            let session = try service.makeHistoryExportSession(source: source(), store: store)
            await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [.ready])
            let ids = Set(session.rows.map(\.id))
            await session.apply(rowIDs: ids, confirmed: false)
            XCTAssertEqual(http.posts, 0)
            await session.apply(rowIDs: ids, confirmed: true)
            XCTAssertNil(session.error)
            if failure != "none" {
                if case .alreadyPresent? = session.outcomes.values.first {} else { XCTFail("Presence is not authorship") }
            } else if case .confirmed? = session.outcomes.values.first {} else { XCTFail("Readback required") }
            XCTAssertEqual(http.posts, 1)
            http.exported = false
            let replay = try service.makeHistoryExportSession(source: source(), store: store)
            await replay.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            await replay.apply(rowIDs: Set(replay.rows.map(\.id)), confirmed: true)
            XCTAssertEqual(replay.error as? TrackerHistoryExportError, .previousAttempt)
            XCTAssertEqual(http.posts, 1)
        }
    }

    func testProductionFactoryRejectsForeignProfileAndStaleConnection() async throws {
        let http = SimklExportHTTP()
        let tokens = InMemorySimklTokenStore(tokens: .init(accessToken: "fixture"))
        let service = SimklService(config: .init(clientID: UUID().uuidString), http: http, tokenStore: tokens)
        await service.refreshStatus()
        XCTAssertThrowsError(try service.makeHistoryExportSession(
            source: source(profile: "foreign"), store: DurableLocalStateStore(secureStore: SimklExportStore())
        ))
        let session = try service.makeHistoryExportSession(source: source(), store: DurableLocalStateStore(secureStore: SimklExportStore()))
        try tokens.save(.init(accessToken: "replacement"))
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testExistingScrobbleBackupRechecksCredentialsBeforeThePacedWrite() async throws {
        for switchProfile in [false, true] {
            let http = SimklExportHTTP()
            let tokens = InMemorySimklTokenStore(tokens: .init(accessToken: "fixture"))
            tokens.setNamespace("other")
            try tokens.save(.init(accessToken: "fixture"))
            tokens.setNamespace(nil)
            http.afterScrobble = {
                if switchProfile { tokens.setNamespace("other") }
                else { try tokens.save(.init(accessToken: "replacement")) }
            }
            let scrobbler = SimklScrobbler(
                config: .init(clientID: UUID().uuidString), http: http, tokenStore: tokens
            )
            try await scrobbler.scrobbleResult(item: movie, progress: 100, event: .stop)
            XCTAssertEqual(http.requests.map(\.path), ["/scrobble/stop"])
            XCTAssertEqual(http.posts, 1)
        }
    }

    func testTransportCancellationDoesNotClaimProvenNonDelivery() async {
        for afterDispatch in [false, true] {
            let http = SimklExportHTTP()
            http.cancelAfter = afterDispatch
            do {
                try await client(http).exportHistory(
                    target, date: nil, token: "fixture", authorize: {},
                    validate: { if !afterDispatch { throw CancellationError() } }
                )
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertEqual(error as? TrackerHistoryExportError,
                               afterDispatch ? .uncertainWrite : .notWritten(.cancelled))
            }
            XCTAssertEqual(http.posts, afterDispatch ? 1 : 0)
        }
    }

    func testResolverDoesNotMislabelAuthenticationQuotaOrServerFailuresAsUnsupported() async {
        for code in [401, 403, 429, 500] {
            let http = SimklExportHTTP()
            http.redirectStatus = code
            do {
                _ = try await SimklHistoryExportAdapter(client: client(http), connectionID: "c")
                    .resolve(movie, token: "fixture", validate: {})
                XCTFail("Resolver request failed")
            } catch {
                XCTAssertEqual(error as? AppError, code == 429 ? .rateLimited(retryAfter: 60)
                               : code == 500 ? .invalidResponse : .unauthorized)
            }
            XCTAssertFalse(http.requests.contains { $0.path == "/movies/10" })
            XCTAssertEqual(http.posts, 0)
        }
    }

    private func source(profile: String = ProfileStore.defaultProfileID) -> TrackerServerHistorySource {
        let provider = SimklExportProvider(value: movie)
        return .init(
            scope: .init(profile: .init(id: profile, name: "Fixture"), accounts: [
                .init(id: "account", server: provider.session.server, userID: "viewer", userName: "Viewer", deviceID: "device")
            ]),
            accounts: [.init(id: "account", serverName: "Server", userName: "Viewer")],
            resolveProvider: { _ in provider }, isAuthorized: { true }, isPlaying: { _, _ in false }
        )
    }
}

@MainActor
private final class SimklExportHTTP: HTTPClient {
    var requests: [Endpoint] = []
    var owner = 42
    var tmdb = 550
    var catalogType = "movie"
    var location = "https://simkl.com/movies/10/fixture"
    var listState = "none"
    var exported = false
    var watchedAt = "1970-01-01T00:00:01Z"
    var posts = 0
    var writeStatus = 201
    var redirectStatus = 301
    var failBefore = false
    var failAfter = false
    var cancelAfter = false
    var badAcknowledgement: String?
    var afterScrobble: (() throws -> Void)?

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        var status = 200
        var headers: [String: String] = [:]
        let json: String
        switch endpoint.path {
        case "/users/settings":
            json = #"{"account":{"id":\#(owner)},"user":{"name":"fixture"}}"#
        case "/redirect":
            status = redirectStatus
            if status == 429 { headers["Retry-After"] = "60" }
            headers["Location"] = location
            json = ""
        case "/movies/10":
            json = #"{"type":"\#(catalogType)","ids":{"simkl":10,"tmdb":\#(tmdb)}}"#
        case "/sync/activities":
            let stamp = exported ? "2020-01-03T00:00:00Z" : "2020-01-02T00:00:00Z"
            let fields = Dictionary(uniqueKeysWithValues: [
                "all", "plantowatch", "watching", "completed", "hold", "dropped", "removed_from_list", "playback"
            ].map { ($0, stamp) })
            json = String(decoding: try JSONSerialization.data(withJSONObject: [
                "all": stamp, "movies": fields, "tv_shows": fields, "anime": fields
            ]), as: UTF8.self)
        case "/sync/all-items/movies":
            if exported || ["plantowatch", "dropped"].contains(listState) {
                json = #"{"movies":[{"status":"\#(exported ? "completed" : listState)","last_watched_at":"\#(watchedAt)","movie":{"ids":{"simkl":10,"tmdb":550}}}]}"#
            } else { json = "{}" }
        case "/sync/all-items/shows", "/sync/all-items/anime": json = "{}"
        case "/sync/playback":
            json = listState == "playing"
                ? #"[{"id":9,"progress":30,"type":"movie","movie":{"ids":{"simkl":10,"tmdb":550}}}]"# : "[]"
        case "/scrobble/stop":
            posts += 1
            try afterScrobble?()
            json = "{}"
        case "/sync/history":
            if failBefore { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
            posts += 1
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(endpoint.body)) as? [String: Any])
            let input = try XCTUnwrap((body["movies"] as? [[String: Any]])?.first)
            watchedAt = try XCTUnwrap(input["watched_at"] as? String)
            exported = true
            status = writeStatus
            if status == 429 { headers["Retry-After"] = "60" }
            if badAcknowledgement == "empty" { json = "{}" }
            else {
                let id = badAcknowledgement == "wrong-target" ? 11 : 10
                let episodes = badAcknowledgement == "expanded" ? 1 : 0
                let failed = badAcknowledgement == "partial" ? #"[{"ids":{"simkl":10}}]"# : "[]"
                let rewatch = badAcknowledgement == "rewatch" ? #","rewatch_id":1"# : ""
                json = #"{"added":{"movies":1,"shows":0,"episodes":\#(episodes),"statuses":[{"request":{"type":"movie","ids":{"simkl":\#(id)},"watched_at":"\#(watchedAt)"},"response":{"status":"completed","simkl_type":"movie"\#(rewatch)}}]},"not_found":{"movies":\#(failed),"shows":[],"episodes":[]}}"#
            }
            if failAfter { throw AppError.serverUnreachable }
            if cancelAfter { throw CancellationError() }
        default:
            XCTFail("Unexpected route \(endpoint.path)")
            throw AppError.notFound
        }
        return (Data(json.utf8), try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers)))
    }
}

final class SimklExportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(interval) }
}

private final class SimklExportStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private actor SimklExportProvider: MediaProvider {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
    )
    let value: MediaItem
    init(value: MediaItem) { self.value = value }
    func libraries() async throws -> [MediaLibrary] { [.init(id: "library", title: "Movies", kind: .movie)] }
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
