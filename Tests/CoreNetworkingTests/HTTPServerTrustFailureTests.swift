import XCTest
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPServerTrustFailureTests: XCTestCase {
    func testDiscoveryRetainsTrustRejectionsWithoutChangingOrdinaryErrorMapping() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrustFailureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session)
        for code in [
            URLError.Code.serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired
        ] {
            for reportsTrust in [true, false] {
                var endpoint = Endpoint(path: "/\(code.rawValue)")
                endpoint.reportsServerTrustFailures = reportsTrust
                do {
                    _ = try await http.send(endpoint, baseURL: URL(string: "https://fixture.invalid")!)
                    XCTFail("Expected a trust failure")
                } catch {
                    if reportsTrust { XCTAssertTrue(error is HTTPServerTrustFailure, "\(error)") }
                    else { XCTAssertEqual(error as? AppError, .serverUnreachable) }
                }
            }
        }
    }

    func testDiscoveryKeepsNonTrustTransportFailuresEligibleForFallback() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrustFailureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session)
        for code in [URLError.Code.cannotConnectToHost, .secureConnectionFailed, .timedOut, .cancelled] {
            var endpoint = Endpoint(path: "/\(code.rawValue)")
            endpoint.reportsServerTrustFailures = true
            do {
                _ = try await http.send(endpoint, baseURL: URL(string: "https://fixture.invalid")!)
                XCTFail("Expected a transport failure")
            } catch {
                XCTAssertEqual(error as? AppError, code == .cancelled ? .cancelled : .serverUnreachable)
            }
        }
    }
}

private final class TrustFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let path = request.url?.lastPathComponent, let code = Int(path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
    }
    override func stopLoading() {}
}
