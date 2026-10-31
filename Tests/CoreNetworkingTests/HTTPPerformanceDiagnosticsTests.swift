import CoreModels
import Foundation
import XCTest
@testable import CoreNetworking

@MainActor
final class HTTPPerformanceDiagnosticsTests: XCTestCase {
    private struct Payload: Decodable { let value: String }

    func testSearchAndScopedCaptureShareSafeUnderlyingTransportEvidence() async throws {
        let journal = SearchDiagnosticJournal()
        journal.start()
        let error = URLError(.cannotConnectToHost, userInfo: [
            NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain, code: 61,
                userInfo: [NSLocalizedDescriptionKey: "private-server"]
            )
        ])
        for route: ResponseDecodingDiagnostic.Route in [.other, .serverAuthentication] {
            let source = try XCTUnwrap(journal.beginSearch()?.source(
                index: 0, provider: .silo, limit: 40, disabledLibraries: 0
            ))
            let captured = await SearchDiagnosticJournal.$currentSource.withValue(source) {
                await HTTPResponseDiagnostics.$route.withValue(route) {
                    await HTTPResponseDiagnostics.capture { () async throws -> Bool in
                        HTTPResponseDiagnostics.recordTransportFailure(error)
                        throw AppError.serverUnreachable
                    }
                }
            }
            source.finish(error: .serverUnreachable)
            let transport = try XCTUnwrap(captured.transport.first)
            XCTAssertEqual(transport.route, route == .other ? .search : route)
            XCTAssertEqual(transport.urlErrorCode, URLError.cannotConnectToHost.rawValue)
            XCTAssertEqual(transport.underlying.count, 1)
            XCTAssertEqual(transport.underlying.first?.code, 61)
            XCTAssertEqual(journal.export(scope: DiagnosticExportScope()).entries.last?.facts.transport, [transport])
        }
        let text = String(decoding: try JSONEncoder().encode(journal.export(scope: DiagnosticExportScope())), as: UTF8.self)
        XCTAssertFalse(text.contains("private-server"))
        XCTAssertNil(SearchDiagnosticJournal.currentSource)
        XCTAssertFalse(HTTPResponseDiagnostics.isCapturing)
    }

    func testSearchJournalCapturesRequestsAfterSuccessFailureTimeoutAndCancellation() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient(session: session)
        let journal = SearchDiagnosticJournal()
        journal.start()
        for (path, expected): (String, AppError?) in [
            ("/success", nil), ("/failure", .invalidResponse),
            ("/timeout", .serverUnreachable), ("/cancelled", .cancelled)
        ] {
            let source = try XCTUnwrap(journal.beginSearch()?.source(index: 0, provider: .silo, limit: 40, disabledLibraries: 0))
            do {
                _ = try await SearchDiagnosticJournal.$currentSource.withValue(source) {
                    try await client.send(
                        Endpoint(method: .get, path: path, queryItems: [.init(name: "q", value: "private-search")],
                                 headers: ["Authorization": "private-token"]),
                        baseURL: XCTUnwrap(URL(string: "https://private-server.invalid"))
                    )
                }
                XCTAssertNil(expected)
                source.finish(resultCount: 1)
            } catch {
                XCTAssertEqual(error as? AppError, expected)
                source.finish(error: try XCTUnwrap(error as? AppError))
            }
        }
        let report = journal.export(scope: DiagnosticExportScope())
        XCTAssertEqual(report.entries.count, 4)
        XCTAssertEqual(report.entries.map(\.facts.outcome), [.results, .failed, .failed, .cancelled])
        XCTAssertTrue(report.entries.allSatisfy { $0.facts.requests.count == 1 })
        XCTAssertTrue(report.entries.allSatisfy { $0.facts.requests.first?.route == .search })
        XCTAssertEqual(report.entries[0].facts.requests.first?.httpStatus, 200)
        XCTAssertEqual(report.entries[1].facts.http.first?.httpStatus, 500)
        XCTAssertEqual(report.entries[2].facts.transport.first?.urlErrorCode, URLError.timedOut.rawValue)
        XCTAssertEqual(report.entries[3].facts.requests.first?.urlErrorCode, URLError.cancelled.rawValue)
        XCTAssertTrue(report.entries[3].facts.transport.isEmpty)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertNil(SearchDiagnosticJournal.currentSource)
        XCTAssertFalse(HTTPResponseDiagnostics.isCapturing)
    }

    func testTransportAndDecodeKeepProviderContextWithoutPrivateRequestOrPayloadData() async throws {
        PerformanceDiagnostics.shared.start()
        defer { PerformanceDiagnostics.shared.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient(session: session)
        let endpoint = Endpoint(method: .get, path: "/success", headers: ["Authorization": "private-credential"])
        let payload = try await PerformanceDiagnostics.$provider.withValue(.emby) {
            try await client.decode(
                Payload.self, from: endpoint, baseURL: XCTUnwrap(URL(string: "https://private-server.invalid"))
            )
        }
        XCTAssertEqual(payload.value, "private-media-title")
        let snapshot = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
        let records = snapshot.recent + snapshot.slow
        let transport = try XCTUnwrap(records.first { $0.operation == .serverRequest })
        let decode = try XCTUnwrap(records.first { $0.operation == .serverDecode })
        XCTAssertEqual(transport.httpStatus, 200)
        XCTAssertEqual(transport.metrics.bytes, Data(#"{"value":"private-media-title"}"#.utf8).count)
        XCTAssertEqual(decode.metrics.bytes, transport.metrics.bytes)
        XCTAssertEqual(transport.provider, .emby)
        XCTAssertEqual(decode.provider, .emby)
        XCTAssertTrue(snapshot.active.isEmpty)
        let encoded = try snapshotText()
        XCTAssertTrue(encoded.contains("serverRequest"))
        XCTAssertTrue(encoded.contains("serverDecode"))
        XCTAssertTrue(encoded.contains("emby"))
        XCTAssertTrue(encoded.contains("succeeded"))
        for secret in ["private-server", "private-credential", "private-media-title", "Authorization", "/success"] {
            XCTAssertFalse(encoded.contains(secret), secret)
        }
    }

    func testHTTPFailureAndCancellationPreserveCallerErrors() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient(session: session)
        for (path, expected, outcome) in [
            ("/failure", AppError.invalidResponse, "failed"),
            ("/cancelled", AppError.cancelled, "cancelled")
        ] {
            PerformanceDiagnostics.shared.start()
            defer { PerformanceDiagnostics.shared.stop() }
            do {
                _ = try await client.send(
                    Endpoint(method: .get, path: path),
                    baseURL: XCTUnwrap(URL(string: "https://private-server.invalid"))
                )
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
            let snapshot = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
            let transport = try XCTUnwrap((snapshot.recent + snapshot.slow).first {
                $0.operation == .serverRequest
            })
            if path == "/failure" {
                XCTAssertEqual(transport.httpStatus, 500)
                XCTAssertEqual(transport.outcome, .failed)
            } else {
                XCTAssertEqual(transport.networkCode, URLError.Code.cancelled.rawValue)
                XCTAssertEqual(transport.outcome, .cancelled)
            }
            XCTAssertTrue(snapshot.active.isEmpty)
            let encoded = try snapshotText()
            XCTAssertTrue(encoded.contains("serverRequest"))
            XCTAssertTrue(encoded.contains(outcome))
            XCTAssertFalse(encoded.contains("private-server"))
            XCTAssertFalse(encoded.contains("private-media-title"))
        }
    }

    func testDisabledDiagnosticsDoNotCollectSuccessfulRequests() async throws {
        PerformanceDiagnostics.shared.stop()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient(session: session)
        let payload = try await client.decode(
            Payload.self, from: Endpoint(method: .get, path: "/success"),
            baseURL: XCTUnwrap(URL(string: "https://private-server.invalid"))
        )
        XCTAssertEqual(payload.value, "private-media-title")
        XCTAssertNil(PerformanceDiagnostics.shared.snapshot())
    }

    private func snapshotText() throws -> String {
        let snapshot = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
        return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PerformanceURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class PerformanceURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/cancelled" || url.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(url.path == "/cancelled" ? .cancelled : .timedOut))
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: url.path == "/failure" ? 500 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"value":"private-media-title"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
