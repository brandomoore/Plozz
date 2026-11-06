import XCTest
import CoreModels
import Synchronization
@testable import CoreNetworking

final class OfflineNetworkSessionTests: XCTestCase {
    private final class Probe: URLProtocol, @unchecked Sendable {
        static let count = Mutex(0)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.count.withLock { $0 += 1 }
            client?.urlProtocol(
                self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data("local server".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testExplicitModeBlocksDirectSessionsAndRestoresLANAccessWhenDisabled() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Probe.self]
        let session = OfflineNetworkSession.make(configuration: configuration)
        defer {
            OfflineMode.shared.setEnabled(false)
            session.invalidateAndCancel()
        }
        Probe.count.withLock { $0 = 0 }
        let url = URL(string: "http://192.0.2.1:32400/library")!
        OfflineMode.shared.setEnabled(true)
        do {
            _ = try await session.data(from: url)
            XCTFail("Explicit offline mode must not admit an HTTP request.")
        } catch {
            XCTAssertEqual(Probe.count.withLock { $0 }, 0)
        }
        OfflineMode.shared.setEnabled(false)
        let (data, _) = try await session.data(from: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "local server")
        XCTAssertEqual(Probe.count.withLock { $0 }, 1)
    }
}
