import XCTest
@testable import CoreNetworking

final class URLSessionReuseTests: XCTestCase {
    /// The transport lanes are process-wide on purpose. As computed properties
    /// each provider/refresh built a fresh `URLSession`, discarding its
    /// connection pool and re-paying connect/TLS cost for the next Home fetch.
    func testNetworkLanesShareOneSessionPerProcess() {
        XCTAssertTrue(URLSession.plozzDefault === URLSession.plozzDefault)
        XCTAssertTrue(URLSession.plozzInteractive === URLSession.plozzInteractive)
        XCTAssertTrue(URLSession.plozzDiscovery === URLSession.plozzDiscovery)
    }
}
