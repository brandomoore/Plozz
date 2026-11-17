import XCTest
@testable import SimklService
@testable import TestSupportNetworking

final class SimklAuthenticationTests: XCTestCase {
    func testChallengeCreationAndConsumptionRequireIndependentTransfers() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/pin", json: """
        {"user_code":"fixture","verification_url":"https://fixture.invalid",
         "expires_in":600,"interval":5}
        """)
        http.stub(pathSuffix: "/oauth/pin/fixture", json: """
        {"result":"OK","access_token":"fixture-token"}
        """)
        let client = SimklClient(config: SimklConfig(clientID: "fixture"), http: http)

        let code = try await client.requestDeviceCode()
        let token = try await client.pollForToken(userCode: code.userCode)

        XCTAssertEqual(token, "fixture-token")
        XCTAssertEqual(http.sentPaths, ["/oauth/pin", "/oauth/pin/fixture"])
        XCTAssertEqual(http.sent.map(\.allowsRequestCoalescing), [false, false])
    }
}
