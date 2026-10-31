import XCTest
import CoreModels
import CoreNetworking
@testable import FeatureAuthCore

final class PasswordSignInServiceTests: XCTestCase {
    private let server = MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin)

    func testSignInRecordsRejectionAndSuccessWithoutCredentials() async throws {
        let diagnostics = ServerConnectionDiagnostics()
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/Users/AuthenticateByName", responses: [
            .init(status: 401, json: ""),
            .init(status: 200, json: #"{"AccessToken":"private-token","ServerId":"srv","User":{"Id":"u1","Name":"private-user"}}"#)
        ])
        let service = PasswordSignInService(server: server, deviceID: "dev1", http: stub, diagnostics: diagnostics)
        do {
            _ = try await service.signIn(username: "private-user", password: "private-password")
            XCTFail("Expected rejected credentials")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidCredentials)
        }
        let session = try await service.signIn(username: "private-user", password: "private-password")
        XCTAssertEqual(session.accessToken, "private-token")
        let data = try JSONEncoder().encode(diagnostics.export(scope: DiagnosticExportScope()))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let facts = try XCTUnwrap(report["entries"] as? [[String: Any]]).compactMap { $0["facts"] as? [String: Any] }
        XCTAssertEqual(facts.compactMap { $0["stage"] as? String }, ["passwordSignIn", "passwordSignIn"])
        XCTAssertEqual(facts.compactMap { $0["outcome"] as? String }, ["failed", "succeeded"])
        XCTAssertEqual(facts.first?["error"] as? String, "invalidCredentials")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
    }

    func testSignInBuildsSession() async throws {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK","ServerId":"srv","User":{"Id":"u1","Name":"Alice"}}
        """)
        let service = PasswordSignInService(server: server, deviceID: "dev1", http: stub)

        let session = try await service.signIn(username: "alice", password: "pw")
        XCTAssertEqual(session.accessToken, "TOK")
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.userName, "Alice")
        XCTAssertEqual(session.deviceID, "dev1")
        XCTAssertEqual(session.server.id, "srv")
        XCTAssertEqual(session.server.baseURL, server.baseURL)
    }

    func testSignInFallsBackToSelectedServerIDWhenServerOmitsIt() async throws {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK","ServerId":null,"User":{"Id":"u1","Name":"Alice"}}
        """)
        let service = PasswordSignInService(server: server, deviceID: "dev1", http: stub)

        let session = try await service.signIn(username: "alice", password: "pw")
        XCTAssertEqual(session.server.id, "s")
    }

    func testEmbySignInPreservesProviderIdentity() async throws {
        let embyServer = MediaServer(
            id: "emby",
            name: "Emby Home",
            baseURL: URL(string: "http://host:8096")!,
            provider: .emby
        )
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/Users/AuthenticateByName", json: """
        {"AccessToken":"TOK","ServerId":"emby","User":{"Id":"u1","Name":"Alice"}}
        """)

        let session = try await PasswordSignInService(
            server: embyServer,
            deviceID: "dev1",
            http: stub
        ).signIn(username: "alice", password: "pw")

        XCTAssertEqual(session.server.provider, .emby)
        XCTAssertEqual(session.accessToken, "TOK")
    }
}
