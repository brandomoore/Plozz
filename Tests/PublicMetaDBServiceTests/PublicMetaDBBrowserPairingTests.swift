import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import XCTest
@testable import PublicMetaDBService

private let pairingTestKey = "pm-" + String(repeating: "a", count: 60)

@MainActor
final class PublicMetaDBBrowserPairingTests: XCTestCase {
    func testWebCryptoEnvelopeInteroperatesWithCryptoKitAndBindsTheCodeAndDevice() throws {
        let keys = try PublicMetaDBPairingKeys(privateKey: Data(repeating: 1, count: 32), secret: "")
        let envelope = PublicMetaDBPairingEnvelope(
            version: 1,
            publicKey: "BHzrb5wTQBgmoH_IGUWBKCINTu05sE33fikGVZg5pdK-Xd6Lzu_Z1Pbhax7RQRVQeXt8WPbrwy0rt6jX6A4r86U",
            sealed: "XeUFY2XOIbXHEHfXfUbtDqj6D0Od_enj_g2MYp-xyT0TywlUAoRnxlj8Sw4INRUvqixOS1IzcbcOwvKVa9WRne5siDLjsdmWTbsNtg0oZ_T5JGCQAK0GsVhhVQ"
        )
        XCTAssertEqual(try keys.open(envelope, code: "ABCDEFGH"), pairingTestKey)
        XCTAssertThrowsError(try keys.open(envelope, code: "BCDEFGHJ"))
        XCTAssertThrowsError(try PublicMetaDBPairingKeys().open(envelope, code: "ABCDEFGH"))
        XCTAssertThrowsError(try keys.open(.init(version: 2, publicKey: envelope.publicKey, sealed: envelope.sealed), code: "ABCDEFGH"))
        XCTAssertThrowsError(try keys.open(.init(version: 1, publicKey: envelope.publicKey + "=", sealed: envelope.sealed), code: "ABCDEFGH"))
        var bytes = try XCTUnwrap(PublicMetaDBPairingKeys.decode(envelope.sealed))
        bytes[40] ^= 1
        XCTAssertThrowsError(try keys.open(.init(version: 1, publicKey: envelope.publicKey, sealed: PublicMetaDBPairingKeys.encode(bytes)), code: "ABCDEFGH"))
        XCTAssertEqual(String(reflecting: keys), "PublicMetaDBPairingKeys(<private>)")
    }

    func testSuccessfulHandoffUsesPrivateBoundedTransportAndVerifiesBeforeSaving() async throws {
        let http = PairingHTTP()
        try await withService(http) { service, store in
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .connected)
            XCTAssertEqual(store.load(namespace: nil)?.key, pairingTestKey)
            XCTAssertNil(service.playbackConsent)
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(service.browserPairing.isActive)
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.path), [
                "/api/publicmetadb/pairing", "/api/publicmetadb/pairing/ABCDEFGH/redeem", "/api/external/lists"
            ])
            for request in requests.prefix(2) {
                XCTAssertEqual(request.redirectPolicy, .sameOrigin)
                XCTAssertEqual(request.maximumResponseBytes, 4096)
                XCTAssertTrue(request.redactsURLForLogging)
                XCTAssertTrue(request.queryItems.isEmpty)
                XCTAssertFalse(request.path.contains(pairingTestKey))
                XCTAssertFalse(String(data: request.body ?? Data(), encoding: .utf8)?.contains(pairingTestKey) == true)
            }
            XCTAssertEqual(requests[0].headers["Authorization"], requests[1].headers["Authorization"])
        }
    }

    func testProfileChangeRevokesPairingAndCannotSaveOrVerifyTheOldKey() async throws {
        let http = PairingHTTP()
        try await withService(http) { service, store in
            await http.setBeforeRedeem { service.selectProfile(namespace: "other") }
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .disconnected)
            XCTAssertNil(store.load(namespace: nil))
            XCTAssertNil(store.load(namespace: "other"))
            XCTAssertFalse(service.browserPairing.isActive)
            let requests = await http.requests
            XCTAssertEqual(requests.last?.method, .delete)
            XCTAssertFalse(requests.contains { $0.path == "/api/external/lists" })
        }
    }

    func testTaskCancellationRevokesPairingWithoutSaving() async throws {
        let http = PairingHTTP()
        let pairing = PublicMetaDBBrowserPairing(http: http, sleep: {})
        await http.setBeforeRedeem { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await pairing.receiveKey() }
        do { _ = try await task.value; XCTFail("Cancelled handoff returned a key") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.requests
        XCTAssertEqual(requests.last?.method, .delete)
        XCTAssertFalse(pairing.isActive)
    }

    func testPollingHasAnActualBoundAndRevokesOnExhaustion() async throws {
        let http = PairingHTTP(pending: true)
        let pairing = PublicMetaDBBrowserPairing(http: http, sleep: {})
        do { _ = try await pairing.receiveKey(); XCTFail("Exhausted polling succeeded") }
        catch { XCTAssertEqual(error as? PublicMetaDBPairingFailure, .expired) }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/redeem") }.count, 200)
        XCTAssertEqual(requests.last?.method, .delete)
        XCTAssertFalse(pairing.isActive)
    }

    func testUnavailableOversizedAndMalformedChallengesNeverBecomeCredentials() async throws {
        for failure in [PairingHTTP.StartFailure.unavailable, .oversized, .malformedCode, .expired] {
            let http = PairingHTTP(startFailure: failure)
            let pairing = PublicMetaDBBrowserPairing(http: http, sleep: {})
            do { _ = try await pairing.receiveKey(); XCTFail("Invalid challenge succeeded") }
            catch { XCTAssertTrue(error is PublicMetaDBPairingFailure) }
            let requests = await http.requests
            XCTAssertFalse(requests.contains { $0.path.hasSuffix("/redeem") })
            XCTAssertFalse(pairing.isActive)
        }
    }

    func testBrowserCancellationCannotOverwriteAReplacementConnection() async throws {
        let http = PairingHTTP()
        try await withService(http) { service, store in
            let replacement = "pm-" + String(repeating: "b", count: 60)
            await http.setBeforeRedeem { await service.connect(key: replacement) }
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .connected)
            XCTAssertEqual(store.load(namespace: nil)?.key, replacement)
            XCTAssertNil(service.playbackConsent)
        }
    }

    func testRejectedBrowserKeyPreservesSavedCredentialAndLeavesConsentDisabled() async throws {
        let http = PairingHTTP(verificationStatus: 401)
        try await withService(http) { service, store in
            let previous = PublicMetaDBCredentials(key: "pm-" + String(repeating: "b", count: 60))
            try store.save(previous, namespace: nil)
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .failed(.unauthorized))
            XCTAssertEqual(store.load(namespace: nil)?.connectionID, previous.connectionID)
            XCTAssertNil(service.playbackConsent)
            XCTAssertNil(service.watchlistSelection)
            XCTAssertNil(service.connectionID)
        }
    }

    func testUnpublishedRelayErrorKeepsItsSpecificDisplayMessage() async throws {
        let http = PairingHTTP(startFailure: .transportInvalidResponse)
        try await withService(http) { service, store in
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .pairingFailed(.unavailable))
            var message = PublicMetaDBPairingFailure.unavailable.userMessage
            message.locale = Locale(identifier: "en")
            XCTAssertEqual(
                String(localized: message),
                "QR code unavailable."
            )
            XCTAssertNil(store.load(namespace: nil))
            XCTAssertFalse(service.browserPairing.isActive)
        }
    }

    func testTransportCancellationDoesNotBecomeAnErrorOrCredential() async throws {
        let http = PairingHTTP(startFailure: .transportCancelled)
        try await withService(http) { service, store in
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .disconnected)
            XCTAssertNil(store.load(namespace: nil))
            XCTAssertFalse(service.browserPairing.isActive)
        }
    }

    private func withService(
        _ http: PairingHTTP,
        body: (PublicMetaDBService, PairingCredentialStore) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBBrowserPairingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PairingCredentialStore()
        let service = PublicMetaDBService(credentials: store, http: http, defaults: defaults)
        try await body(service, store)
    }
}

private actor PairingHTTP: HTTPClient {
    enum StartFailure: Sendable {
        case unavailable, oversized, malformedCode, expired, transportInvalidResponse, transportCancelled
    }
    var requests: [Endpoint] = []
    private var receiver: String?
    private let pending: Bool
    private let startFailure: StartFailure?
    private let verificationStatus: Int
    private var beforeRedeem: (@MainActor @Sendable () async -> Void)?

    init(pending: Bool = false, startFailure: StartFailure? = nil, verificationStatus: Int = 200) {
        self.pending = pending
        self.startFailure = startFailure
        self.verificationStatus = verificationStatus
    }
    func setBeforeRedeem(_ action: @escaping @MainActor @Sendable () async -> Void) { beforeRedeem = action }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        if startFailure == .transportInvalidResponse { throw AppError.invalidResponse }
        if startFailure == .transportCancelled { throw AppError.cancelled }
        var status = 200
        let data: Data
        if endpoint.method == .delete {
            status = 204
            data = Data()
        } else if endpoint.path == "/api/external/lists" {
            status = verificationStatus
            data = Data(#"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#.utf8)
        } else if endpoint.path.hasSuffix("/redeem") {
            let action = beforeRedeem
            beforeRedeem = nil
            await action?()
            if pending {
                status = 202
                data = Data(#"{"status":"pending"}"#.utf8)
            } else {
                let raw = try XCTUnwrap(PublicMetaDBPairingKeys.decode(XCTUnwrap(receiver)))
                let peer = try P256.KeyAgreement.PublicKey(x963Representation: raw)
                let sender = P256.KeyAgreement.PrivateKey()
                let shared = try sender.sharedSecretFromKeyAgreement(with: peer)
                let context = PublicMetaDBPairingKeys.context
                let aes = shared.hkdfDerivedSymmetricKey(
                    using: SHA256.self, salt: Data("ABCDEFGH".utf8), sharedInfo: Data(context.utf8), outputByteCount: 32
                )
                let box = try AES.GCM.seal(
                    Data(pairingTestKey.utf8), using: aes, authenticating: Data("\(context):ABCDEFGH".utf8)
                )
                data = try JSONEncoder().encode(PublicMetaDBPairingEnvelope(
                    version: 1, publicKey: PublicMetaDBPairingKeys.encode(sender.publicKey.x963Representation),
                    sealed: PublicMetaDBPairingKeys.encode(XCTUnwrap(box.combined))
                ))
            }
        } else {
            struct Start: Decodable { let publicKey: String }
            receiver = try JSONDecoder().decode(Start.self, from: XCTUnwrap(endpoint.body)).publicKey
            status = startFailure == .unavailable ? 503 : 201
            if startFailure == .oversized { data = Data(repeating: 65, count: 4097) }
            else {
                data = try JSONSerialization.data(withJSONObject: [
                    "code": startFailure == .malformedCode ? "../../other" : "ABCDEFGH",
                    "expiresAt": Date().addingTimeInterval(startFailure == .expired ? -1 : 600).timeIntervalSince1970 * 1000,
                ])
            }
        }
        return (data, try XCTUnwrap(HTTPURLResponse(
            url: baseURL.appendingPathComponent(endpoint.path), statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )))
    }
}

private final class PairingCredentialStore: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PublicMetaDBCredentials] = [:]
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { values[namespace ?? ""] } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {
        lock.withLock { values[namespace ?? ""] = credentials }
    }
    func clear(namespace: String?) throws { lock.withLock { _ = values.removeValue(forKey: namespace ?? "") } }
}
