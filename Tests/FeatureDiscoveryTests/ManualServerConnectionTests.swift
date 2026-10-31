import XCTest
import CoreModels
import CoreNetworking
import FeatureDiscoveryCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class ManualServerConnectionTests: XCTestCase {
    func testDiagnosticReportRetainsFailedCandidatesAndSuccessfulFallback() async throws {
        for provider in [ProviderKind.jellyfin, .emby] {
            let diagnostics = ServerConnectionDiagnostics()
            let http = ManualConnectionHTTP(replies: ["http://private.example:8096": .server])
            let validator = ServerValidator(provider: provider, http: http, diagnostics: diagnostics)
            _ = try await validator.resolveManualAddress("private.example")
            let data = try JSONEncoder().encode(diagnostics.export(scope: DiagnosticExportScope()))
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let entries = try XCTUnwrap(report["entries"] as? [[String: Any]])
            let facts = entries.compactMap { $0["facts"] as? [String: Any] }
            XCTAssertEqual(facts.count, 2)
            XCTAssertEqual(facts.compactMap { $0["candidate"] as? Int }, [1, 2])
            XCTAssertEqual(facts.compactMap { $0["scheme"] as? String }, ["https", "http"])
            XCTAssertEqual(facts.compactMap { $0["outcome"] as? String }, ["failed", "succeeded"])
            XCTAssertEqual(facts.compactMap { $0["provider"] as? String }, [provider.rawValue, provider.rawValue])
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private.example"))
        }
    }

    func testDiagnosticReportDistinguishesTrustRejection() async throws {
        let diagnostics = ServerConnectionDiagnostics()
        let http = ManualConnectionHTTP(replies: ["https://media.example": .trustFailure])
        let validator = ServerValidator(http: http, diagnostics: diagnostics)
        do {
            _ = try await validator.resolveManualAddress("media.example")
            XCTFail("Expected trust rejection")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        let data = try JSONEncoder().encode(diagnostics.export(scope: DiagnosticExportScope()))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(report["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual((entries.first?["facts"] as? [String: Any])?["error"] as? String, "tlsTrustRejected")
    }

    func testBareAndHTTPAddressesFindHTTPSBeforeSignInForBothProviders() async throws {
        for provider in [ProviderKind.jellyfin, .emby] {
            for raw in ["media.example/jf", "http://media.example/jf"] {
                let http = ManualConnectionHTTP(replies: ["https://media.example/jf": .server])
                let store = ManualConnectionStore()
                let model = model(provider: provider, http: http, store: store)
                model.manualURLText = raw

                let result = await model.submitManualURL()

                XCTAssertEqual(result?.baseURL.absoluteString, "https://media.example/jf")
                XCTAssertEqual(result?.id, "server")
                XCTAssertEqual(result?.provider, provider)
                XCTAssertEqual(store.lastServer, result)
                let requests = await http.requests
                XCTAssertEqual(requests, ["https://media.example/jf"])
                XCTAssertEqual(model.phase, .idle)
            }
        }
    }

    func testExplicitPortsAreNotReplacedByGuessedPorts() async throws {
        for raw in ["media.example:8443/jf", "http://media.example:8443/jf"] {
            let http = ManualConnectionHTTP(replies: ["https://media.example:8443/jf": .server])
            let result = try await ServerValidator(http: http).resolveManualAddress(raw)
            XCTAssertEqual(result.baseURL.absoluteString, "https://media.example:8443/jf")
            let requests = await http.requests
            XCTAssertEqual(requests, ["https://media.example:8443/jf"])
        }
    }

    func testHTTPOnlyLANAndReverseProxyServersStillConnect() async throws {
        for (raw, destination, expected) in [
            ("192.168.1.5", "http://192.168.1.5:8096", ["https://192.168.1.5", "http://192.168.1.5:8096"]),
            ("media.example/jf", "http://media.example/jf",
             ["https://media.example/jf", "http://media.example:8096/jf", "http://media.example/jf"]),
            ("http://media.example/jf", "http://media.example/jf", ["https://media.example/jf", "http://media.example/jf"]),
            ("media.example:8096", "http://media.example:8096", ["https://media.example:8096", "http://media.example:8096"])
        ] {
            let http = ManualConnectionHTTP(replies: [destination: .server])
            let result = try await ServerValidator(http: http).resolveManualAddress(raw)
            XCTAssertEqual(result.baseURL.absoluteString, destination)
            let requests = await http.requests
            XCTAssertEqual(requests, expected)
        }
    }

    func testExplicitHTTPSNeverProbesHTTP() async {
        let http = ManualConnectionHTTP(replies: ["http://media.example:8096": .server])
        await assertFailure(.serverUnreachable, raw: "https://media.example", http: http)
        let requests = await http.requests
        XCTAssertEqual(requests, ["https://media.example"])
    }

    func testTLSIdentityFailureNeverFallsBackToHTTP() async {
        let http = ManualConnectionHTTP(replies: [
            "https://media.example": .trustFailure,
            "http://media.example:8096": .server
        ])
        await assertFailure(.serverUnreachable, raw: "media.example", http: http)
        let requests = await http.requests
        XCTAssertEqual(requests, ["https://media.example"])
    }

    func testAccessRejectionAndCancellationStopFurtherProbes() async {
        for error in [AppError.unauthorized, .rateLimited(retryAfter: 20), .cancelled] {
            let http = ManualConnectionHTTP(replies: [
                "https://media.example": .failure(error),
                "http://media.example:8096": .server
            ])
            await assertFailure(error, raw: "media.example", http: http)
            let requests = await http.requests
            XCTAssertEqual(requests, ["https://media.example"])
        }
    }

    func testNonServerResponsesDoNotWinDiscovery() async throws {
        for body in ["<html>Welcome</html>", #"{"unrelated":"json"}"#] {
            let http = ManualConnectionHTTP(replies: [
                "https://media.example": .body(body),
                "http://media.example:8096": .server
            ])
            let result = try await ServerValidator(http: http).resolveManualAddress("media.example")
            XCTAssertEqual(result.baseURL.absoluteString, "http://media.example:8096")
        }
    }

    func testSameHostHTTPRedirectRetainsCanonicalHTTPSPath() async throws {
        let http = ManualConnectionHTTP(replies: [
            "http://media.example/old": .redirect("https://media.example/secure/System/Info/Public")
        ])
        let result = try await ServerValidator(http: http).resolveManualAddress("http://media.example/old")
        XCTAssertEqual(result.baseURL.absoluteString, "https://media.example/secure")
    }

    func testCrossHostAndHTTPSDowngradeResponsesCannotSelectAServer() async {
        for destination in [
            "https://other.example/System/Info/Public",
            "http://media.example/System/Info/Public"
        ] {
            let http = ManualConnectionHTTP(replies: ["https://media.example": .redirect(destination)])
            await assertFailure(.invalidResponse, raw: "https://media.example", http: http)
        }
    }

    func testAllFailuresAreBoundedVisibleAndNotRemembered() async {
        let http = ManualConnectionHTTP(replies: [:])
        let store = ManualConnectionStore()
        let model = model(http: http, store: store)
        model.manualURLText = "media.example"
        let result = await model.submitManualURL()
        XCTAssertNil(result)
        XCTAssertNil(store.lastServer)
        XCTAssertEqual(model.phase, .error(AppError.serverUnreachable.userMessage))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testCancelledOrSupersededValidationCannotRememberALateSuccess() async throws {
        for cancelTask in [false, true] {
            let http = ManualConnectionHTTP(replies: ["https://media.example": .suspended])
            let store = ManualConnectionStore()
            let model = model(http: http, store: store)
            model.manualURLText = "media.example"
            let task = Task { await model.submitManualURL() }
            for _ in 0..<200 {
                if await http.isSuspended { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let suspended = await http.isSuspended
            XCTAssertTrue(suspended)
            if cancelTask { task.cancel() }
            else { model.stopScan() }
            await http.resume()
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertNil(store.lastServer)
            XCTAssertEqual(model.phase, .idle)
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    private func assertFailure(_ expected: AppError, raw: String, http: ManualConnectionHTTP) async {
        do {
            _ = try await ServerValidator(http: http).resolveManualAddress(raw)
            XCTFail("Expected connection failure")
        } catch {
            XCTAssertEqual(error as? AppError, expected)
        }
    }

    private func model(
        provider: ProviderKind = .jellyfin, http: ManualConnectionHTTP, store: ManualConnectionStore
    ) -> ServerPickerViewModel {
        ServerPickerViewModel(provider: provider, discovery: NoManualConnectionDiscovery(),
                              validator: ServerValidator(provider: provider, http: http), store: store)
    }
}

private struct NoManualConnectionDiscovery: ServerDiscovering {
    func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        AsyncStream { $0.finish() }
    }
}

private final class ManualConnectionStore: LastServerStoring, @unchecked Sendable {
    var recentServers: [MediaServer] = []
}

private actor ManualConnectionHTTP: HTTPClient {
    enum Reply: Sendable {
        case server, trustFailure, suspended
        case body(String), redirect(String), failure(AppError)
    }
    let replies: [String: Reply]
    private(set) var requests: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }

    init(replies: [String: Reply]) { self.replies = replies }
    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(baseURL.absoluteString)
        XCTAssertEqual(endpoint.method, .get)
        XCTAssertEqual(endpoint.path, "/System/Info/Public")
        XCTAssertTrue(endpoint.headers.isEmpty)
        XCTAssertTrue(endpoint.queryItems.isEmpty)
        XCTAssertNil(endpoint.body)
        XCTAssertTrue(endpoint.reportsServerTrustFailures)
        var body = #"{"Id":"server","ServerName":"Home","Version":"10.10.0"}"#
        var responseURL = baseURL.appendingPathComponent(endpoint.path)
        switch replies[baseURL.absoluteString] ?? .failure(.serverUnreachable) {
        case .server: break
        case .body(let value): body = value
        case .redirect(let value): responseURL = URL(string: value)!
        case .failure(let error): throw error
        case .trustFailure: throw HTTPServerTrustFailure()
        case .suspended:
            await withCheckedContinuation { continuation = $0 }
        }
        return (Data(body.utf8), HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
