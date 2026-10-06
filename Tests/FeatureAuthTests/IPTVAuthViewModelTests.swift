import CoreModels
import Foundation
@testable import FeatureAuthCore
import XCTest

@MainActor
final class IPTVAuthViewModelTests: XCTestCase {
    func testPlaylistBasicBearerAndGuideHeadersStaySeparate() throws {
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list",
            guideAddress: "https://guide.example/xmltv", onAuthenticated: { _ in }
        )
        model.authentication = .basic
        model.username = "fixture-user"
        model.password = "fixture-password"
        XCTAssertTrue(model.canConnect)
        model.addGuideHeader()
        model.guideHeaders[0].name = "Authorization"
        model.guideHeaders[0].value = "Bearer guide-fixture"
        let basic = try model.makeCredential()
        XCTAssertEqual(basic.headers["Authorization"], "Basic " + Data("fixture-user:fixture-password".utf8).base64EncodedString())
        XCTAssertEqual(try basic.guideHeaders(for: XCTUnwrap(basic.guideURL))["Authorization"], "Bearer guide-fixture")
        XCTAssertTrue(try basic.guideHeaders(for: XCTUnwrap(URL(string: "https://foreign.example/guide"))).isEmpty)
        model.authentication = .bearer
        XCTAssertFalse(model.canConnect)
        model.token = "playlist-fixture"
        XCTAssertEqual(try model.makeCredential().headers["Authorization"], "Bearer playlist-fixture")
    }

    func testXtreamNormalizesAnAPIEndpointAndRequiresCredentials() throws {
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/prefix/player_api.php?unused=1",
            onAuthenticated: { _ in }
        )
        model.mode = .xtream
        XCTAssertFalse(model.canConnect)
        model.username = "viewer"
        model.password = "fixture"
        XCTAssertTrue(model.canConnect)
        XCTAssertEqual(try model.makeCredential().address.absoluteString, "https://provider.example/prefix")
    }

    func testSeedPreservesEveryConfiguredGuideAndRejectsDuplicateHeaders() throws {
        let guides = try ["https://guide.example/one", "https://guide.example/two"].map {
            try XCTUnwrap(URL(string: $0))
        }
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list", guideURLs: guides,
            onAuthenticated: { _ in }
        )
        XCTAssertEqual(try model.makeCredential().explicitGuideURLs, guides)
        model.addHeader()
        model.headers[0].name = "Cookie"
        model.headers[0].value = "session=fixture"
        model.addHeader()
        model.headers[1].name = "cookie"
        model.headers[1].value = "session=duplicate"
        XCTAssertThrowsError(try model.makeCredential())
    }

    func testCancellationRejectsLateSuccessfulAuthentication() async throws {
        let gate = IPTVSignInGate()
        var received = 0
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list",
            signIn: { credential, _, _, _ in await gate.complete(credential) },
            onAuthenticated: { _ in received += 1 }
        )
        model.connect()
        await gate.waitUntilRequested()
        model.cancel()
        await gate.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(received, 0)
        XCTAssertFalse(model.isConnecting)
    }

    func testPersistenceFailureRemainsVisibleAndAllowsRetry() async throws {
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list",
            signIn: { credential, _, _, _ in IPTVSignInGate.session(credential) },
            onAuthenticated: { _ in throw IPTVAuthViewModel.CompletionError.persistence }
        )
        defer { model.cancel() }
        model.connect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.issue == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(model.issue)
        XCTAssertTrue(model.canConnect)
    }

    func testEditingConnectionRetainsAccountIdentityAndUsesFreshPrivateCatalog() async throws {
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.example/old?token=fixture")),
            headers: ["Authorization": "Basic Zml4dHVyZTpwYXNzd29yZA=="],
            guideURL: XCTUnwrap(URL(string: "https://guide.example/one")),
            additionalGuideURLs: [XCTUnwrap(URL(string: "https://guide.example/two"))],
            guideHeaders: ["X-Guide-Key": "fixture"]
        )
        var original = IPTVSignInGate.session(credential)
        original.accessToken = try credential.encoded()
        var received: UserSession?
        let model = IPTVAuthViewModel(
            deviceID: "device", reconnecting: original,
            signIn: { credential, _, _, _ in
                var result = IPTVSignInGate.session(credential)
                result.server.id = "new-catalog"
                result.userID = "new-user"
                result.accessToken = try credential.encoded()
                return result
            },
            onAuthenticated: { received = $0 }
        )
        XCTAssertEqual(try model.makeCredential().headers, credential.headers)
        XCTAssertEqual(try model.makeCredential().explicitGuideURLs, credential.explicitGuideURLs)
        XCTAssertEqual(try model.makeCredential().explicitGuideHeaders, credential.explicitGuideHeaders)
        model.address = "https://provider.example/new?token=updated"
        model.connect()
        defer { model.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while received == nil, ContinuousClock.now < deadline { await Task.yield() }
        let updated = try XCTUnwrap(received)
        XCTAssertEqual(Account.stableID(for: updated), Account.stableID(for: original))
        let updatedCredential = try IPTVCredential.decode(updated.accessToken)
        XCTAssertEqual(updatedCredential.address.absoluteString, model.address)
        XCTAssertNotEqual(updatedCredential.identity, credential.identity)
        XCTAssertNotEqual(updatedCredential.catalogKey, credential.catalogKey)
    }
}

private actor IPTVSignInGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested = false
    func complete(_ credential: IPTVCredential) async -> UserSession {
        requested = true
        await withCheckedContinuation { continuation = $0 }
        return Self.session(credential)
    }
    func waitUntilRequested() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !requested, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(requested)
    }
    func release() { continuation?.resume(); continuation = nil }
    nonisolated static func session(_ credential: IPTVCredential) -> UserSession {
        UserSession(
            server: MediaServer(id: "fixture", name: "Fixture", baseURL: credential.address, provider: .iptv),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
        )
    }
}
