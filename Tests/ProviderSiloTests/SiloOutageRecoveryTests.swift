import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

private actor RestartingSiloHTTP: HTTPClient {
    private var online = false
    private let provenUndelivered: Bool
    private(set) var refreshCount = 0

    init(provenUndelivered: Bool = true) { self.provenUndelivered = provenUndelivered }
    func recover() { online = true }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        if endpoint.path == "/api/v2/auth/refresh" {
            refreshCount += 1
            XCTAssertTrue(endpoint.reportsUndeliveredRequests)
            if !online {
                if provenUndelivered { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
                throw AppError.serverUnreachable
            }
            json = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
        } else {
            XCTAssertTrue(online)
            json = #"{"items":[{"id":"movies","name":"Movies","type":"movie"}]}"#
        }
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension SiloProviderTests {
    func testNASOutageBeforeRefreshTransmissionCanRecoverWithoutLosingLogin() async throws {
        var login = try credential()
        login.expiresAt = .distantPast
        let raw = try login.encoded()
        let store = SiloCredentialStub(raw)
        let ctx = context(raw)
        let http = RestartingSiloHTTP()
        let first = try SiloProvider(context: ctx, credentials: store, http: http)
        do {
            _ = try await first.libraries()
            XCTFail("The NAS is offline.")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        XCTAssertEqual(try store.credential(accountID: ctx.accountID, revision: ctx.credentialRevision), raw)
        await http.recover()
        let reopened = try SiloProvider(context: ctx, credentials: store, http: http)
        let libraries = try await reopened.libraries()
        XCTAssertEqual(libraries.map(\.id), ["movies"])
        let updated = try SiloCredential.decode(store.credential(accountID: ctx.accountID, revision: ctx.credentialRevision))
        XCTAssertEqual(updated.loginID, login.loginID)
        XCTAssertEqual(updated.refreshToken, "new-refresh")
        XCTAssertEqual(updated.refreshPending, false)
        let count = await http.refreshCount
        XCTAssertEqual(count, 2, "Only the proven-undelivered attempt may be retried.")
    }

    func testAmbiguousNetworkFailureStillCannotReplayARotatingRefresh() async throws {
        var login = try credential()
        login.expiresAt = .distantPast
        let raw = try login.encoded()
        let store = SiloCredentialStub(raw)
        let ctx = context(raw)
        let http = RestartingSiloHTTP(provenUndelivered: false)
        let first = try SiloProvider(context: ctx, credentials: store, http: http)
        do { _ = try await first.libraries(); XCTFail("The connection failed.") }
        catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        await http.recover()
        let reopened = try SiloProvider(context: ctx, credentials: store, http: http)
        do { _ = try await reopened.libraries(); XCTFail("The first refresh might have consumed its token.") }
        catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        let count = await http.refreshCount
        XCTAssertEqual(count, 1)
    }
}
