import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderPlex

final class PlexEmptyHomeUserLibrariesTests: XCTestCase {
    private func provider(_ http: any HTTPClient) -> PlexProvider {
        PlexProvider(
            session: .init(
                server: .init(id: "server", name: "Server", baseURL: URL(string: "https://server.example")!, provider: .plex),
                userID: "owner", userName: "Owner", deviceID: "fixture", accessToken: "home-user-cloud"
            ),
            http: http
        )
    }

    func testAuthenticatedHomeUserWithoutServerGrantHasNoVideoOrMusicLibraries() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
        http.stub(pathSuffix: "/api/v2/resources", json: "[]")
        let provider = provider(http)
        let libraries = try await provider.libraries()
        let music = try await provider.musicLibraries()
        XCTAssertTrue(libraries.isEmpty)
        XCTAssertTrue(music.isEmpty)
        XCTAssertEqual(http.sentPaths, [
            "/library/sections", "/api/v2/resources", "/library/sections", "/api/v2/resources"
        ])
        XCTAssertTrue(http.sentHeaders.allSatisfy { $0["X-Plex-Token"] == "home-user-cloud" })
        XCTAssertEqual(http.baseURL(forPathSuffix: "/api/v2/resources")?.host, "plex.tv")
    }

    func testValidEmptySectionsDoNotNeedACloudAuthorizationCheck() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: #"{"MediaContainer":{"size":0}}"#)
        let libraries = try await provider(http).libraries()
        XCTAssertTrue(libraries.isEmpty)
        XCTAssertEqual(http.sentPaths, ["/library/sections"])
    }

    func testActualExpiredCredentialsRemainUnauthorized() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
        http.stub(pathSuffix: "/api/v2/resources", json: "{}", status: 401)
        do {
            _ = try await provider(http).libraries()
            XCTFail("An expired cloud credential must still require sign-in.")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testRemovedServerGrantIsCheckedWithTheDistinctLiveCloudToken() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
        http.stub(pathSuffix: "/api/v2/resources", json: "[]")
        let provider = PlexProvider(
            session: .init(
                server: .init(id: "server", name: "Server", baseURL: URL(string: "https://server.example")!, provider: .plex),
                userID: "owner", userName: "Owner", deviceID: "fixture", accessToken: "server-scoped-token"
            ),
            cloudTokenResolver: { "home-user-cloud" },
            http: http
        )
        let libraries = try await provider.libraries()
        XCTAssertTrue(libraries.isEmpty)
        XCTAssertEqual(http.sentHeaders.map { $0["X-Plex-Token"] }, ["server-scoped-token", "home-user-cloud"])
    }

    func testCloudIdentityChangedDuringGrantCheckCannotPublishAnEmptyInventory() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
        stub.stub(pathSuffix: "/api/v2/resources", json: "[]")
        let state = CloudIdentity()
        let http = GatedResourcesHTTP(stub: stub) { await state.invalidate() }
        let provider = PlexProvider(
            session: .init(
                server: .init(id: "server", name: "Server", baseURL: URL(string: "https://server.example")!, provider: .plex),
                userID: "owner", userName: "Owner", deviceID: "fixture", accessToken: "server-scoped-token"
            ),
            cloudTokenResolver: { try await state.token() },
            http: http
        )
        do {
            _ = try await provider.libraries()
            XCTFail("A superseded Home identity must not publish a sharing result.")
        } catch is CancellationError {
        }
    }

    func testExistingServerGrantCannotBeConvertedToEmptyLibraries() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
        http.stub(pathSuffix: "/api/v2/resources", json: """
        [{"clientIdentifier":"server","provides":"server","accessToken":"server-token"}]
        """)
        do {
            _ = try await provider(http).libraries()
            XCTFail("A server's rejection with an existing grant is not proof of no shared libraries.")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    private actor CloudIdentity {
        private var isCurrent = true
        func invalidate() { isCurrent = false }
        func token() throws -> String {
            guard isCurrent else { throw CancellationError() }
            return "home-user-cloud"
        }
    }

    func testMalformedOrFailedResourceLookupCannotClaimTheProfileHasNoLibraries() async throws {
        for (response, status, expected) in [
            ("not-json", 200, AppError.decoding),
            ("{}", 503, .invalidResponse),
            (#"[{"clientIdentifier":"server","provides":"server","accessToken":""}]"#, 200, .invalidResponse)
        ] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
            http.stub(pathSuffix: "/api/v2/resources", json: response, status: status)
            do {
                _ = try await provider(http).libraries()
                XCTFail("Unknown sharing state must remain an explicit failure.")
            } catch let error as AppError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testResourceTokenResolutionDoesNotDependOnAdvertisedConnectionsOrServerProbes() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/api/v2/resources", json: """
        [{"clientIdentifier":"server","provides":"server","accessToken":"server-token"}]
        """)
        let client = PlexAuthClient(deviceProfile: .init(clientIdentifier: "fixture"), http: http)
        let token = try await client.serverAccessToken(forServerID: "server", authToken: "home-user-cloud")
        XCTAssertEqual(token, "server-token")
        XCTAssertEqual(http.sentPaths, ["/api/v2/resources"])
    }

    func testCancelledCloudCheckCannotPublishEmptyLibraries() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: "{}", status: 401)
        stub.stub(pathSuffix: "/api/v2/resources", json: "[]")
        let reached = expectation(description: "Cloud sharing verification started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let http = GatedResourcesHTTP(stub: stub) {
            reached.fulfill()
            for await _ in gate.stream { break }
        }
        let provider = provider(http)
        let fetch = Task { try await provider.libraries() }
        await fulfillment(of: [reached], timeout: 2)
        fetch.cancel()
        gate.continuation.finish()
        do {
            _ = try await fetch.value
            XCTFail("Cancellation is not an empty library inventory.")
        } catch is CancellationError {
        }
    }
}

private struct GatedResourcesHTTP: HTTPClient {
    let stub: StubHTTPClient
    let beforeResources: @Sendable () async -> Void

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        if endpoint.path == "/api/v2/resources" { await beforeResources() }
        return try await stub.send(endpoint, baseURL: baseURL)
    }
}
