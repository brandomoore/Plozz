import CryptoKit
import Foundation
import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderSilo

extension SiloProviderTests {
    func testOlderServerWithoutBindingRequiresManualSignInBeforeUsingCredentials() async throws {
        let http = EnrollmentHTTP(supportsBinding: false)
        do {
            _ = try await SiloAuthentication(baseURL: URL(string: "https://silo.test")!, http: http)
                .enrollDevice(using: SiloSyncCredential(try credential()), serverID: "server1",
                              serverName: "Silo", deviceID: "new", platform: "tvos")
            XCTFail("Unbound approval must not become automatic credential transfer")
        } catch SiloAuthenticationError.pairingUnavailable {}
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/auth/device/capability"])
    }

    func testExpiringBootstrapRefreshesBeforeIndependentEnrollment() async throws {
        let http = EnrollmentHTTP()
        var source = try credential()
        source.expiresAt = .distantPast
        let original = source.refreshToken
        let session = try await SiloAuthentication(baseURL: URL(string: "https://silo.test")!, http: http)
            .enrollDevice(using: SiloSyncCredential(source), serverID: "server1",
                          serverName: "Silo", deviceID: "new", platform: "ios")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/refresh") }.count, 1)
        XCTAssertEqual(source.refreshToken, original)
        XCTAssertEqual(try SiloCredential.decode(session.accessToken).refreshToken, "new-refresh")
    }

    func testSyncedLoginCreatesIndependentBoundDeviceSessionWithoutSourcePINProof() async throws {
        let http = EnrollmentHTTP()
        let source = try credential()
        let session = try await SiloAuthentication(baseURL: URL(string: "https://silo.test")!, http: http)
            .enrollDevice(using: SiloSyncCredential(source), serverID: "server1",
                          serverName: "Silo", deviceID: "new-device", platform: "tvos")
        let result = try SiloCredential.decode(session.accessToken)
        XCTAssertNotEqual(result.loginID, source.loginID)
        XCTAssertEqual(result.accessToken, "new-access")
        XCTAssertEqual(result.refreshToken, "new-refresh")
        XCTAssertNil(result.profileToken)
        XCTAssertEqual(session.deviceID, "new-device")
        let requests = await http.requests
        let poll = try XCTUnwrap(requests.first { $0.path.hasSuffix("/poll") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(poll.body)) as? [String: String])
        let secret = try XCTUnwrap(body["binding_secret"])
        let raw = try XCTUnwrap(Data(base64Encoded: secret.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="))
        let digest = Data(SHA256.hash(data: raw)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let binding = await http.binding
        XCTAssertEqual(digest, binding)
        XCTAssertEqual(poll.headers["X-Silo-Device-Id"], "new-device")
        XCTAssertTrue(requests.allSatisfy { $0.redirectPolicy == .sameOrigin })
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Token"] == nil })
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/logout") })
    }

    func testProtectedProfileDoesNotCreateAnUnusableDeviceLogin() async throws {
        let http = EnrollmentHTTP(pin: true)
        do {
            _ = try await SiloAuthentication(baseURL: URL(string: "https://silo.test")!, http: http)
                .enrollDevice(using: SiloSyncCredential(try credential()), serverID: "server1",
                              serverName: "Silo", deviceID: "new", platform: "ios")
            XCTFail("PIN proof cannot cross sessions")
        } catch SiloDeviceEnrollmentError.profilePINRequired {}
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/start") })
    }

    func testMismatchedBindingCancelsWithoutApproving() async throws {
        let http = EnrollmentHTTP(wrongBinding: true)
        do {
            _ = try await SiloAuthentication(baseURL: URL(string: "https://silo.test")!, http: http)
                .enrollDevice(using: SiloSyncCredential(try credential()), serverID: "server1",
                              serverName: "Silo", deviceID: "new", platform: "ios")
            XCTFail("An unrelated challenge must not be approved")
        } catch SiloDeviceEnrollmentError.identityMismatch {}
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/approve") })
        XCTAssertTrue(requests.contains { $0.path.hasSuffix("/cancel") })
    }

    func testServerMismatchAfterApprovalRevokesOnlyTheNewSession() async throws {
        let http = EnrollmentHTTP(wrongInstallation: true)
        do {
            _ = try await SiloAuthentication(baseURL: URL(string: "https://silo.test")!, http: http)
                .enrollDevice(using: SiloSyncCredential(try credential()), serverID: "server1",
                              serverName: "Silo", deviceID: "new", platform: "ios")
            XCTFail("The result must match the encrypted account identity")
        } catch SiloDeviceEnrollmentError.identityMismatch {}
        let logout = await http.requests.first { $0.path.hasSuffix("/logout") }
        XCTAssertEqual(logout?.headers["Authorization"], "Bearer new-access")
    }
}

private actor EnrollmentHTTP: HTTPClient {
    var requests: [Endpoint] = []
    var binding = ""
    let pin: Bool
    let wrongBinding: Bool
    let wrongInstallation: Bool
    let supportsBinding: Bool
    init(pin: Bool = false, wrongBinding: Bool = false, wrongInstallation: Bool = false, supportsBinding: Bool = true) {
        self.pin = pin
        self.wrongBinding = wrongBinding
        self.wrongInstallation = wrongInstallation
        self.supportsBinding = supportsBinding
    }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let body: String
        switch endpoint.path {
        case "/api/v2/auth/device/capability":
            body = """
            {"state":"available","allowed":true,"protocol_versions":[2],"session_binding":\(supportsBinding)}
            """
        case "/api/v2/auth/refresh":
            body = #"{"access_token":"source-refreshed"}"#
        case "/api/v2/profiles":
            body = """
            {"items":[{"id":"profile1","name":"Viewer","has_pin":\(pin),"is_child":false}]}
            """
        case "/api/v2/auth/device/start":
            let value = try JSONSerialization.jsonObject(with: XCTUnwrap(endpoint.body)) as? [String: Any]
            binding = try XCTUnwrap(value?["binding"] as? String)
            body = """
            {"device_code":"device-code","user_code":"1234-5678","match_code":"unused",
             "verification_uri":"https://silo.test/activate","verification_uri_complete":"https://silo.test/activate?code=12345678",
             "expires_in":900,"interval":5}
            """
        case "/api/v2/auth/device":
            body = """
            {"binding":"\(wrongBinding ? "wrong" : binding)","server_id":"server1",
             "client_purpose":"device_login","temporary":false,"status":"pending"}
            """
        case "/api/v2/auth/device/approve": body = #"{"status":"approved"}"#
        case "/api/v2/auth/device/cancel": body = #"{"status":"canceled"}"#
        case "/api/v2/auth/device/poll":
            body = """
            {"status":"approved","poll_after":5,"temporary":false,"tokens":{
             "access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,
             "user":{"id":"user1","username":"Viewer"}}}
            """
        case "/api/v2/playback/capabilities":
            body = """
            {"installation_id":"\(wrongInstallation ? "wrong" : "server1")","protocol_versions":[3],
             "features":[],"deliveries":[],"state":"available","allowed":true}
            """
        case "/api/v2/auth/logout": body = "{}"
        default: throw AppError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
