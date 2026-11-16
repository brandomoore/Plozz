import CoreModels
import XCTest

@testable import SeerService

@MainActor
final class SeerPersonalRequestsTests: XCTestCase {
    private let baseURL = URL(string: "https://requests.example.com/seerr")!

    private func service(_ http: SeerRecordingHTTPClient) -> SeerService {
        SeerService(
            connectionStore: InMemorySeerConnectionStore(
                connection: SeerConnection(baseURL: baseURL, apiKey: "fixture")
            ),
            http: http
        )
    }

    private func request(
        _ id: Int, user: Int = 7, status: Int = 2, type: String = "movie", tmdbID: Int? = nil
    ) -> String {
        #"{"id":\#(id),"status":\#(status),"requestedBy":{"id":\#(user)},"media":{"tmdbId":\#(tmdbID ?? id),"mediaType":"\#(type)"}}"#
    }

    func testPersonalPaginationIncludesRequestedShowsAndMoviesButNotDeclinedRequests() async throws {
        let http = SeerRecordingHTTPClient()
        http.enqueueStub(
            pathSuffix: "/user/7/requests",
            json: """
                {"pageInfo":{"results":6},"results":[\(request(1)),\(request(2, status: 3))]}
                """)
        http.enqueueStub(
            pathSuffix: "/user/7/requests",
            json: """
                {"pageInfo":{"results":6},"results":[\(request(3, status: 1, type: "tv")),\(request(4)),\(request(5, type: "tv", tmdbID: 1)),\(request(6, type: "tv", tmdbID: 1))]}
                """)
        for id in [1, 4] {
            http.enqueueStub(pathSuffix: "/movie/\(id)", json: #"{"id":\#(id),"title":"Film \#(id)"}"#)
        }
        for id in [1, 3] {
            http.enqueueStub(pathSuffix: "/tv/\(id)", json: #"{"id":\#(id),"name":"Show \#(id)"}"#)
        }
        let items = try await service(http).personallyRequestedTitles(
            identity: .user(id: 7, server: SeerServerIdentity(baseURL: baseURL)), language: "en"
        )
        XCTAssertEqual(items.map(\.id), ["seer:movie:1", "seer:movie:4", "seer:series:1", "seer:series:3"])
        XCTAssertEqual(items.map(\.kind), [.movie, .movie, .series, .series])
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/tv/1") }.count, 1,
                       "Multiple season requests enroll a show only once")
        let requests = http.sent.filter { $0.path.hasSuffix("/requests") }
        XCTAssertEqual(requests.map { $0.queryItems.first { $0.name == "skip" }?.value }, ["0", "2"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-API-User"] == "7" })
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/auth/me") })
    }

    func testPersonalTVDetailsRejectAnExplicitlyWrongMediaType() async {
        let http = SeerRecordingHTTPClient()
        http.stub(
            pathSuffix: "/user/7/requests",
            json: #"{"pageInfo":{"results":1},"results":[\#(request(1, type: "tv"))]}"#
        )
        http.stub(pathSuffix: "/tv/1", json: #"{"id":1,"name":"Wrong kind","mediaType":"movie"}"#)
        do {
            _ = try await service(http).personallyRequestedTitles(
                identity: .user(id: 7, server: SeerServerIdentity(baseURL: baseURL)), language: "en"
            )
            XCTFail("An explicit conflicting type must not be overwritten")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testUnmappedIdentityResolvesItsOwnUserInsteadOfListingHouseholdRequests() async throws {
        let http = SeerRecordingHTTPClient()
        http.enqueueStub(pathSuffix: "/auth/me", json: #"{"id":9}"#)
        http.enqueueStub(pathSuffix: "/user/9/requests", json: #"{"pageInfo":{"results":0},"results":[]}"#)
        let items = try await service(http).personallyRequestedTitles(identity: .admin, language: "en")
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(http.sentPaths.count, 2)
        XCTAssertTrue(http.sentPaths.last?.hasSuffix("/user/9/requests") == true)
    }

    func testSelectedConnectionIdentityFollowsRequestUserInsteadOfLegacyProfileMapping() async throws {
        let http = SeerRecordingHTTPClient()
        let service = service(http)
        var profile = Profile(id: "fixture", name: "Fixture")
        profile.seerrUserID = 7
        profile.seerrServerIdentity = SeerServerIdentity(baseURL: baseURL)
        service.configureProfiles(
            store: InMemorySeerAccountConnectionStore(), profiles: [profile], current: { profile }
        )
        let id = try XCTUnwrap(service.profileConnections.defaultID)
        try service.setRequestUser(
            SeerUser(id: 9, name: "Updated", serverIdentity: SeerServerIdentity(baseURL: baseURL)),
            connectionID: id
        )
        http.stub(pathSuffix: "/user/9/requests", json: #"{"pageInfo":{"results":0},"results":[]}"#)

        _ = try await service.personallyRequestedTitles(identity: service.requestIdentity, language: "en")

        XCTAssertEqual(profile.seerrRequestIdentity.userID, 7)
        XCTAssertEqual(service.requestIdentity.userID, 9)
        XCTAssertEqual(http.sentPaths, ["/api/v1/user/9/requests"])
        XCTAssertEqual(http.sent.first?.headers["X-API-User"], "9")
    }

    func testForeignUserResponseAndUnboundIdentityFailClosed() async {
        let http = SeerRecordingHTTPClient()
        http.enqueueStub(
            pathSuffix: "/user/7/requests",
            json: """
                {"pageInfo":{"results":1},"results":[\(request(1, user: 8))]}
                """)
        do {
            _ = try await service(http).personallyRequestedTitles(
                identity: .user(id: 7, server: SeerServerIdentity(baseURL: baseURL)), language: "en"
            )
            XCTFail("Foreign user request must be rejected")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertFalse(http.sentPaths.contains { $0.contains("/movie/") })
        let unboundHTTP = SeerRecordingHTTPClient()
        do {
            _ = try await service(unboundHTTP).personallyRequestedTitles(
                identity: .user(id: 7, server: nil), language: "en"
            )
            XCTFail("Unbound user must not fall back to admin")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        XCTAssertTrue(unboundHTTP.sentPaths.isEmpty)
    }

    func testSelectedLegacyMappingRequiringRelinkCannotReadPersonalRequests() async throws {
        for server in [nil, SeerServerIdentity(baseURL: URL(string: "https://other.example.test")!)] {
            let http = SeerRecordingHTTPClient()
            let service = service(http)
            var profile = Profile(id: "legacy", name: "Legacy")
            profile.seerrUserID = 7
            profile.seerrServerIdentity = server
            service.configureProfiles(
                store: InMemorySeerAccountConnectionStore(), profiles: [profile], current: { profile }
            )
            XCTAssertEqual(service.requestIdentity, .user(id: 7, server: nil))
            for identity in [service.requestIdentity, .user(id: 7, server: SeerServerIdentity(baseURL: baseURL))] {
                do {
                    _ = try await service.personallyRequestedTitles(identity: identity, language: "en")
                    XCTFail("An unverified legacy mapping must require relinking")
                } catch {
                    XCTAssertEqual(error as? AppError, .unauthorized)
                }
            }
            XCTAssertTrue(http.sentPaths.isEmpty)
        }
    }

    func testRestrictedUnmappedProfileCannotReadAdminRequests() async {
        let http = SeerRecordingHTTPClient()
        let service = service(http)
        service.refusesAdminRequests = { true }
        do {
            _ = try await service.personallyRequestedTitles(identity: .admin, language: "en")
            XCTFail("A restricted profile needs its own mapped request identity")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    func testDisconnectRejectsAnInFlightPersonalRequestPage() async {
        let http = SeerRecordingHTTPClient()
        let path = "/user/7/requests"
        http.enqueueStub(pathSuffix: path, json: #"{"pageInfo":{"results":0},"results":[]}"#)
        http.suspend(pathSuffix: path)
        let service = service(http)
        let identity = SeerRequestIdentity.user(id: 7, server: SeerServerIdentity(baseURL: baseURL))
        let load = Task { try await service.personallyRequestedTitles(identity: identity, language: "en") }
        await http.waitUntilSuspended(pathSuffix: path)
        service.disconnect()
        http.resume(pathSuffix: path)
        do {
            _ = try await load.value
            XCTFail("Disconnected request identity must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRequestCompletionInvalidatesPersonalFeedsWithoutAMountedScreen() async throws {
        let http = SeerRecordingHTTPClient()
        let service = service(http)
        let identity = SeerRequestIdentity.user(id: 7, server: SeerServerIdentity(baseURL: baseURL))
        let item = MediaItem(id: "film", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"])
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .personalRequestsDidChange, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { changes += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        for status in [201, 500] {
            http.stub(pathSuffix: "/request", json: #"{"id":42,"media":{"status":2}}"#, status: status)
            let outcome = await service.request(item, identity: identity)
            if status == 201 {
                guard case .success = outcome else { return XCTFail("Expected a successful request") }
            } else {
                guard case .failure = outcome else { return XCTFail("Expected a failed request") }
            }
        }
        XCTAssertEqual(changes, 2, "Both successful and uncertain request attempts invalidate the personal feed")

        http.stub(pathSuffix: "/request", json: #"{"id":42,"media":{"status":2}}"#, status: 201)
        http.suspend(pathSuffix: "/request", onRequestNumber: 3)
        let pending = Task { await service.request(item, identity: identity) }
        await http.waitUntilSuspended(pathSuffix: "/request")
        service.disconnect()
        http.resume(pathSuffix: "/request")
        _ = await pending.value
        XCTAssertEqual(changes, 2, "A late completion from a disconnected service must not invalidate the new identity")
    }
}
