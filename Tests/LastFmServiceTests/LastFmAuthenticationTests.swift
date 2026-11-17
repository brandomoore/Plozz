import XCTest
@testable import LastFmService
@testable import TestSupportNetworking

final class LastFmAuthenticationTests: XCTestCase {
    func testChallengeCreationAndConsumptionRequireIndependentTransfers() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/2.0/", json: #"{"token":"fixture-token"}"#)
        http.stub(pathSuffix: "/2.0/", json: """
        {"session":{"key":"fixture-session","name":"fixture-user"}}
        """)
        let client = LastFmClient(
            config: LastFmConfig(apiKey: "fixture", sharedSecret: "fixture"),
            http: http
        )

        let token = try await client.getToken()
        let session = try await client.getSession(token: token)

        XCTAssertEqual(session.sessionKey, "fixture-session")
        XCTAssertEqual(http.sent.map { request in
            request.queryItems.first { $0.name == "method" }?.value
        }, ["auth.getToken", "auth.getSession"])
        XCTAssertEqual(http.sent.map(\.allowsRequestCoalescing), [false, false])
    }
}
