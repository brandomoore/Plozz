import CoreModels
import CoreNetworking
import Foundation
import XCTest

final class StubHTTPClientTests: XCTestCase {
    func testConcurrentRequestsKeepEveryRecordAndItsFieldsTogether() async throws {
        let http = StubHTTPClient()
        let count = 256
        for index in 0..<count {
            http.stub(pathSuffix: "/items/\(index)", json: "\(index)")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    let method: HTTPMethod = index.isMultiple(of: 2) ? .get : .post
                    let baseURL = URL(string: "https://server-\(index).example")!
                    let query = [URLQueryItem(name: "index", value: "\(index)")]
                    let endpoint = Endpoint(method: method, path: "/items/\(index)", queryItems: query)
                    let (data, _) = try await http.send(endpoint, baseURL: baseURL)
                    XCTAssertEqual(String(decoding: data, as: UTF8.self), "\(index)")
                    XCTAssertEqual(http.queryItems(forPathSuffix: endpoint.path), query)
                    XCTAssertEqual(http.method(forPathSuffix: endpoint.path), method)
                    XCTAssertEqual(http.baseURL(forPathSuffix: endpoint.path), baseURL)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(http.sentPaths.count, count)
        XCTAssertEqual(Set(http.sentPaths).count, count)
        XCTAssertEqual(http.sentMethods.count, count)
        XCTAssertEqual(http.sentQueryItems.count, count)
        XCTAssertEqual(http.sentBaseURLs.count, count)
    }

    func testConcurrentRequestsConsumeEachQueuedResponseExactlyOnce() async throws {
        let http = StubHTTPClient()
        let count = 256
        http.stubSequence(pathSuffix: "/poll", jsons: (0..<count).map(String.init))
        let bodies = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<count {
                group.addTask {
                    let (data, _) = try await http.send(
                        Endpoint(path: "/poll"), baseURL: URL(string: "https://server.example")!
                    )
                    return String(decoding: data, as: UTF8.self)
                }
            }
            var result: [String] = []
            for try await body in group { result.append(body) }
            return result
        }
        XCTAssertEqual(bodies.count, count)
        XCTAssertEqual(Set(bodies), Set((0..<count).map(String.init)))
        XCTAssertEqual(http.sentPaths.count, count)
    }
}
