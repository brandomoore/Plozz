import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin
@testable import TestSupportPerformance

@MainActor
final class JellyfinRecommendationPerformanceTests: XCTestCase {
    func testPerformanceHomeRecommendationNavigation() async throws {
        try await PerformanceProbe.measure(self, scenario: "home-recommendation-navigation") {
            let http = RecommendationPerformanceHTTP()
            let session = UserSession(
                server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                              provider: .jellyfin),
                userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
            )
            let provider = JellyfinProvider(session: session, http: http)
            return try await HomeRecommendationScope.$current.withValue(HomeRecommendationScope()) {
                for limit in [20, 8, 20, 20] {
                    let rows = try await provider.homeHubs(
                        libraryID: "movies", kind: .movie, limit: limit, includeUnpromoted: true
                    )
                    XCTAssertEqual(rows.count, 3)
                    XCTAssertEqual(rows[0].items.map(\.id), (0..<limit).map { "0-\($0)" })
                }
                for limit in [40, 70, 140] {
                    for shelf in 0..<2 {
                        let page = try await provider.homeRowPage(
                            .recommendation(libraryID: "movies", kind: .movie,
                                            browseID: "SimilarToRecentlyPlayed:category-\(shelf)",
                                            anchorIDs: (0..<20).map { "\(shelf)-\($0)" }),
                            startIndex: limit - 40, limit: 40
                        )
                        XCTAssertEqual(page.items.map(\.id), ((limit - 40)..<limit).map { "\(shelf)-\($0)" })
                        XCTAssertEqual(page.nextOffset, limit)
                    }
                }
                let metrics = await http.metrics()
                return ["requests": metrics.requests, "bytes": metrics.bytes, "items": 240]
            }
        }
    }
}

private actor RecommendationPerformanceHTTP: HTTPClient {
    private var requests = 0
    private var bytes = 0

    func metrics() -> (requests: Int, bytes: Int) { (requests, bytes) }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(endpoint.path, "/Movies/Recommendations")
        let limit = Int(endpoint.queryItems.first { $0.name == "itemLimit" }?.value ?? "") ?? 0
        XCTAssertGreaterThan(limit, 0)
        try await Task.sleep(for: .milliseconds(5))
        let rows: [[String: Any]] = (0..<3).map { shelf in
            [
                "RecommendationType": "SimilarToRecentlyPlayed", "CategoryId": "category-\(shelf)",
                "BaselineItemName": "Fixture \(shelf)",
                "Items": (0..<limit).map { ["Id": "\(shelf)-\($0)", "Name": "Movie \($0)", "Type": "Movie"] }
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        requests += 1
        bytes += data.count
        return (data, HTTPURLResponse(url: baseURL.appendingPathComponent(endpoint.path), statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!)
    }
}
