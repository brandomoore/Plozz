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

    private func request(_ id: Int, user: Int = 7, status: Int = 2, type: String = "movie") -> String {
        #"{"id":\#(id),"status":\#(status),"requestedBy":{"id":\#(user)},"media":{"tmdbId":\#(id),"mediaType":"\#(type)"}}"#
    }

    func testPersonalPaginationPreservesActingUserAndExcludesDeclinedAndTVRequests() async throws {
        let http = SeerRecordingHTTPClient()
        http.enqueueStub(
            pathSuffix: "/user/7/requests",
            json: """
                {"pageInfo":{"results":4},"results":[\(request(1)),\(request(2, status: 3))]}
                """)
        http.enqueueStub(
            pathSuffix: "/user/7/requests",
            json: """
                {"pageInfo":{"results":4},"results":[\(request(3, type: "tv")),\(request(4))]}
                """)
        for id in [1, 4] {
            http.enqueueStub(pathSuffix: "/movie/\(id)", json: #"{"id":\#(id),"title":"Film \#(id)"}"#)
        }
        let items = try await service(http).personallyRequestedMovies(
            identity: .user(id: 7, server: SeerServerIdentity(baseURL: baseURL)), language: "en"
        )
        XCTAssertEqual(items.map(\.id), ["seer:movie:1", "seer:movie:4"])
        let requests = http.sent.filter { $0.path.hasSuffix("/requests") }
        XCTAssertEqual(requests.map { $0.queryItems.first { $0.name == "skip" }?.value }, ["0", "2"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-API-User"] == "7" })
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/auth/me") })
    }

    func testUnmappedIdentityResolvesItsOwnUserInsteadOfListingHouseholdRequests() async throws {
        let http = SeerRecordingHTTPClient()
        http.enqueueStub(pathSuffix: "/auth/me", json: #"{"id":9}"#)
        http.enqueueStub(pathSuffix: "/user/9/requests", json: #"{"pageInfo":{"results":0},"results":[]}"#)
        let items = try await service(http).personallyRequestedMovies(identity: .admin, language: "en")
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(http.sentPaths.count, 2)
        XCTAssertTrue(http.sentPaths.last?.hasSuffix("/user/9/requests") == true)
    }

    func testForeignUserResponseAndUnboundIdentityFailClosed() async {
        let http = SeerRecordingHTTPClient()
        http.enqueueStub(
            pathSuffix: "/user/7/requests",
            json: """
                {"pageInfo":{"results":1},"results":[\(request(1, user: 8))]}
                """)
        do {
            _ = try await service(http).personallyRequestedMovies(
                identity: .user(id: 7, server: SeerServerIdentity(baseURL: baseURL)), language: "en"
            )
            XCTFail("Foreign user request must be rejected")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertFalse(http.sentPaths.contains { $0.contains("/movie/") })
        let unboundHTTP = SeerRecordingHTTPClient()
        do {
            _ = try await service(unboundHTTP).personallyRequestedMovies(
                identity: .user(id: 7, server: nil), language: "en"
            )
            XCTFail("Unbound user must not fall back to admin")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        XCTAssertTrue(unboundHTTP.sentPaths.isEmpty)
    }

    func testRestrictedUnmappedProfileCannotReadAdminRequests() async {
        let http = SeerRecordingHTTPClient()
        let service = service(http)
        service.refusesAdminRequests = { true }
        do {
            _ = try await service.personallyRequestedMovies(identity: .admin, language: "en")
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
        let load = Task { try await service.personallyRequestedMovies(identity: identity, language: "en") }
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
}
