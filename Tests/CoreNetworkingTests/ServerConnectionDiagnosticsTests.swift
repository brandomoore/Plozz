import CoreModels
import Foundation
import XCTest
@testable import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ServerConnectionDiagnosticsTests: XCTestCase {
    private struct Info: Decodable, Sendable { let Id: String }

    func testTransportFailuresPreserveNumericCauseWithoutPrivateData() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session)
        for code in [-1001, -1003, -1004, -1006, -1009, -1022, -1200, -1202] {
            let diagnostics = ServerConnectionDiagnostics()
            let url = URL(string: "https://private-host.invalid:8443/private-prefix")!
            do {
                try await diagnostics.capture(provider: .jellyfin, stage: .addressValidation, baseURL: url, candidate: 1) {
                    _ = try await http.send(Endpoint(path: "/\(code)"), baseURL: url)
                }
                XCTFail("Expected transport failure")
            } catch {
                XCTAssertEqual(error as? AppError, .serverUnreachable)
            }
            let entry = try XCTUnwrap(entries(diagnostics).first)
            let facts = try XCTUnwrap(entry["facts"] as? [String: Any])
            XCTAssertEqual(facts["outcome"] as? String, "failed")
            XCTAssertEqual(facts["scheme"] as? String, "https")
            XCTAssertEqual(facts["explicitPort"] as? Bool, true)
            XCTAssertEqual(facts["basePath"] as? Bool, true)
            XCTAssertEqual(facts["candidate"] as? Int, 1)
            XCTAssertEqual(facts["error"] as? String, "serverUnreachable")
            let request = try XCTUnwrap((facts["requests"] as? [[String: Any]])?.first)
            XCTAssertEqual(request["urlErrorCode"] as? Int, code)
            XCTAssertEqual(request["route"] as? String, "serverDiscovery")
            XCTAssertNil(request["httpStatus"])
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(request["elapsedMilliseconds"] as? Int), 0)
            XCTAssertEqual(request["requestTimeoutMilliseconds"] as? Int, 60_000)
            if code == -1004 {
                let transport = try XCTUnwrap((facts["transport"] as? [[String: Any]])?.first)
                let underlying = try XCTUnwrap((transport["underlying"] as? [[String: Any]])?.first)
                XCTAssertEqual(underlying["domain"] as? String, "posix")
                XCTAssertEqual(underlying["code"] as? Int, 61)
            }
            try assertPrivateDataAbsent(diagnostics)
        }
    }

    func testHTTPFailuresNonJSONAndSuccessRetainDifferentEvidence() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session)
        for (status, expectedError) in [
            (401, AppError.unauthorized), (404, .notFound), (502, .invalidResponse), (200, .decoding)
        ] {
            let diagnostics = ServerConnectionDiagnostics()
            let url = URL(string: "https://private-host.invalid")!
            do {
                _ = try await diagnostics.capture(provider: .emby, stage: .passwordSignIn, baseURL: url) {
                    try await http.decode(Info.self, from: Endpoint(path: "/\(status)"), baseURL: url)
                }
                XCTFail("Expected HTTP or decoding failure")
            } catch {
                XCTAssertEqual(error as? AppError, expectedError)
            }
            let facts = try XCTUnwrap(entries(diagnostics).first?["facts"] as? [String: Any])
            let request = try XCTUnwrap((facts["requests"] as? [[String: Any]])?.first)
            XCTAssertEqual(request["httpStatus"] as? Int, status)
            XCTAssertEqual(request["format"] as? String, "html")
            XCTAssertNil(request["urlErrorCode"])
            if status == 200 {
                let response = try XCTUnwrap((facts["responses"] as? [[String: Any]])?.first)
                XCTAssertEqual(response["payload"] as? String, "nonJSON")
            }
            try assertPrivateDataAbsent(diagnostics)
        }
        let diagnostics = ServerConnectionDiagnostics()
        let url = URL(string: "http://private-host.invalid")!
        let data = try await diagnostics.capture(provider: .jellyfin, stage: .addressValidation, baseURL: url) {
            try await http.send(Endpoint(path: "/204"), baseURL: url).0
        }
        XCTAssertTrue(data.isEmpty)
        let facts = try XCTUnwrap(entries(diagnostics).first?["facts"] as? [String: Any])
        XCTAssertEqual(facts["outcome"] as? String, "succeeded")
        XCTAssertNil(facts["error"])
        XCTAssertEqual((facts["requests"] as? [[String: Any]])?.first?["httpStatus"] as? Int, 204)
    }

    func testCancelledAttemptsAndUnknownErrorDescriptionsAreNotReported() async throws {
        let diagnostics = ServerConnectionDiagnostics()
        for error in [AppError.cancelled, CancellationError()] as [Error] {
            do {
                try await diagnostics.capture(provider: .jellyfin, stage: .quickConnectApproval, baseURL: nil) {
                    throw error
                }
                XCTFail("Expected cancellation")
            } catch {}
        }
        XCTAssertTrue(try entries(diagnostics).isEmpty)
        do {
            try await diagnostics.capture(provider: .jellyfin, stage: .passwordSignIn, baseURL: nil) {
                throw AppError.unknown("private password token")
            }
        } catch {
            XCTAssertEqual(error as? AppError, .unknown("private password token"))
        }
        XCTAssertEqual(try (entries(diagnostics).first?["facts"] as? [String: Any])?["error"] as? String, "unknown")
        try assertPrivateDataAbsent(diagnostics)
    }

    func testLateCancellationDoesNotRecordSuccess() async throws {
        let diagnostics = ServerConnectionDiagnostics()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await diagnostics.capture(provider: .jellyfin, stage: .passwordSignIn, baseURL: nil) { 7 }
        }
        let value = try await task.value
        XCTAssertEqual(value, 7, "Instrumentation must not change the operation's result")
        XCTAssertTrue(try entries(diagnostics).isEmpty)
    }

    func testRetentionAndExportAliasesAreBounded() async throws {
        let clock = Clock()
        let diagnostics = ServerConnectionDiagnostics(clock: { clock.now })
        for _ in 0..<40 {
            _ = try await diagnostics.capture(provider: .jellyfin, stage: .addressValidation, baseURL: nil) { true }
        }
        let first = try export(diagnostics)
        let second = try export(diagnostics)
        let rows = try XCTUnwrap(first["entries"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 32)
        XCTAssertEqual(first["dropped"] as? Int, 8)
        XCTAssertNotEqual(rows.first?["attempt"] as? String,
                          (second["entries"] as? [[String: Any]])?.first?["attempt"] as? String)
        clock.advance()
        XCTAssertTrue(try entries(diagnostics).isEmpty)
        XCTAssertEqual(try export(diagnostics)["dropped"] as? Int, 40)
    }

    private func entries(_ diagnostics: ServerConnectionDiagnostics) throws -> [[String: Any]] {
        try XCTUnwrap(export(diagnostics)["entries"] as? [[String: Any]])
    }

    private func export(_ diagnostics: ServerConnectionDiagnostics) throws -> [String: Any] {
        let data = try JSONEncoder().encode(diagnostics.export(scope: DiagnosticExportScope()))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertPrivateDataAbsent(_ diagnostics: ServerConnectionDiagnostics) throws {
        let text = String(decoding: try JSONEncoder().encode(diagnostics.export(scope: DiagnosticExportScope())), as: UTF8.self)
        for secret in ["private", "password token", "NSURLError", "invalid:8443"] {
            XCTAssertFalse(text.contains(secret), "Unexpected private field: \(secret)")
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        var now: Date { lock.withLock { value } }
        func advance() { lock.withLock { value = value.addingTimeInterval(49 * 3_600) } }
    }

    private final class ConnectionURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let code = Int(url.lastPathComponent) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            if code < 0 {
                var userInfo: [String: Any] = [
                    NSURLErrorFailingURLStringErrorKey: url.absoluteString,
                    NSLocalizedDescriptionKey: "private password token"
                ]
                if code == -1004 {
                    userInfo[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: 61,
                                                           userInfo: [NSLocalizedDescriptionKey: "private socket address"])
                }
                client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code), userInfo: userInfo))
            } else {
                let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                               headerFields: ["Content-Type": "text/html"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if code != 204 { client?.urlProtocol(self, didLoad: Data("<html>private password token</html>".utf8)) }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }
}
