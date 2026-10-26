import Foundation
import XCTest
@testable import CoreNetworking
@testable import TestSupportNetworking

final class HTTPRedirectPolicyTests: XCTestCase {
    func testURLSessionReturnsTheOriginalRedirectOnlyForDoNotFollow() async throws {
        let limits: [Int?] = [nil, 64 * 1_024]
        for (policy, limit) in [Endpoint.RedirectPolicy.doNotFollow, .sameOrigin, .follow].flatMap({
            policy in limits.map { (policy, $0) }
        }) {
            let server = try LoopbackHTTPServer { request in
                request.target == "/redirect"
                    ? .init(status: 301, headers: ["Location": "/target"], body: Data("original".utf8))
                    : .init(body: Data("followed".utf8))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            let session = URLSession(configuration: configuration)
            addTeardownBlock {
                session.invalidateAndCancel()
                await server.stop()
            }
            let baseURL = try await server.start()
            var endpoint = Endpoint(path: "/redirect")
            endpoint.redirectPolicy = policy
            endpoint.maximumResponseBytes = limit
            let (data, response) = try await URLSessionHTTPClient(session: session).sendRaw(endpoint, baseURL: baseURL)
            let requests = await server.requests
            if policy == .doNotFollow {
                XCTAssertEqual(response.statusCode, 301)
                XCTAssertEqual(response.value(forHTTPHeaderField: "Location"), "/target")
                XCTAssertEqual(String(decoding: data, as: UTF8.self), "original")
                XCTAssertEqual(requests.map(\.target), ["/redirect"])
            } else {
                XCTAssertEqual(response.statusCode, 200)
                XCTAssertEqual(String(decoding: data, as: UTF8.self), "followed")
                XCTAssertEqual(requests.map(\.target), ["/redirect", "/target"])
            }
            session.invalidateAndCancel()
            await server.stop()
        }
    }

    func testManualRedirectsReturnNeitherSameOriginNorExternalRequests() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try XCTUnwrap(URL(string: "https://example.test/redirect"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: origin, statusCode: 301, httpVersion: nil, headerFields: ["Location": "/target"]
        ))
        let task = session.dataTask(with: origin)
        let delegate = NoHTTPRedirectDelegate(evidence: nil)
        for value in ["https://example.test/target", "https://external.test/target"] {
            let completed = expectation(description: value)
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: try XCTUnwrap(URL(string: value)))
            ) {
                XCTAssertNil($0)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 1)
        }
    }
}
