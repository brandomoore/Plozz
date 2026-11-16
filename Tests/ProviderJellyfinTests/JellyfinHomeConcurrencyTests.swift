import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinHomeConcurrencyTests: XCTestCase {
    func testCollectionExistenceProbesOverlapWithoutReorderingLibrariesOrLoadingArtwork() async throws {
        let http = CollectionProbeHTTPClient()
        let session = UserSession(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                          provider: .jellyfin),
            userID: "viewer", userName: "Viewer", deviceID: "test", accessToken: "fixture"
        )
        let provider = JellyfinProvider(session: session, http: http)
        let load = Task { try await provider.libraries() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await http.requests.count < 3, ContinuousClock.now < deadline { await Task.yield() }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3, "All existence probes must start before any response completes.")
        for endpoint in requests {
            func value(_ name: String) -> String? { endpoint.queryItems.first { $0.name == name }?.value }
            XCTAssertEqual(value("Limit"), "1")
            XCTAssertEqual(value("EnableImages"), "false")
            XCTAssertNil(value("Fields"), "Existence discovery must not request full card metadata.")
        }
        await http.release("third")
        await http.release("second")
        await http.release("first")
        let libraries = try await load.value
        XCTAssertEqual(libraries.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(libraries.map(\.hasCollections), [true, false, nil])
    }

    func testLatestEpisodeLookupsUseARefillingFourRequestWindow() async throws {
        let http = RecencyWindowHTTPClient()
        let session = UserSession(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                          provider: .jellyfin),
            userID: "viewer", userName: "Viewer", deviceID: "test", accessToken: "fixture"
        )
        let provider = JellyfinProvider(session: session, http: http)
        let load = Task { try await provider.continueWatching(limit: .max) }
        await waitForStarts(4, http: http)
        let first = await http.started
        XCTAssertEqual(Set(first), Set((0..<4).map { "show-\($0)" }))
        await http.release("show-3")
        await waitForStarts(5, http: http)
        let refilled = await http.started
        XCTAssertTrue(refilled.contains("show-4"), "One completion must refill without waiting for its batch peers.")
        await http.releaseAll()
        let items = try await load.value
        let maximum = await http.peak
        let started = await http.started
        XCTAssertEqual(items.count, 9)
        XCTAssertEqual(started.count, 9)
        XCTAssertEqual(maximum, 4)
        XCTAssertTrue(items.allSatisfy { $0.lastPlayedAt != nil })
    }

    private func waitForStarts(_ count: Int, http: RecencyWindowHTTPClient) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await http.started.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let actual = await http.started.count
        XCTAssertEqual(actual, count)
    }
}

private actor CollectionProbeHTTPClient: HTTPClient {
    private(set) var requests: [Endpoint] = []
    private var released: Set<String> = []
    private var waits: [String: CheckedContinuation<Void, Never>] = [:]
    func release(_ id: String) {
        released.insert(id)
        waits.removeValue(forKey: id)?.resume()
    }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        if endpoint.path.hasSuffix("/Views") {
            json = #"{"Items":[{"Id":"first","Name":"First","CollectionType":"boxsets"},{"Id":"second","Name":"Second","CollectionType":"boxsets"},{"Id":"third","Name":"Third","CollectionType":"boxsets"}]}"#
        } else {
            let id = try XCTUnwrap(endpoint.queryItems.first { $0.name == "ParentId" }?.value)
            requests.append(endpoint)
            if !released.contains(id) { await withCheckedContinuation { waits[id] = $0 } }
            if id == "third" { throw AppError.serverUnreachable }
            json = id == "first"
                ? #"{"Items":[{"Id":"collection","Type":"BoxSet"}],"TotalRecordCount":10000}"#
                : #"{"Items":[],"TotalRecordCount":0}"#
        }
        return (Data(json.utf8), try XCTUnwrap(HTTPURLResponse(
            url: baseURL.appendingPathComponent(endpoint.path), statusCode: 200, httpVersion: nil, headerFields: nil
        )))
    }
}

private actor RecencyWindowHTTPClient: HTTPClient {
    private(set) var started: [String] = []
    private(set) var peak = 0
    private var active = 0
    private var released = false
    private var waits: [String: CheckedContinuation<Void, Never>] = [:]

    func release(_ id: String) { waits.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        released = true
        let pending = waits.values
        waits.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        func query(_ name: String) -> String? { endpoint.queryItems.first { $0.name == name }?.value }
        let json: String
        if endpoint.path.hasSuffix("/Resume") {
            json = #"{"Items":[],"TotalRecordCount":0}"#
        } else if endpoint.path.hasSuffix("/NextUp") {
            let items = (0..<9).map {
                #"{"Id":"episode-\#($0)","Type":"Episode","SeriesId":"show-\#($0)"}"#
            }.joined(separator: ",")
            json = #"{"Items":[\#(items)],"TotalRecordCount":9}"#
        } else if query("IncludeItemTypes") == "Series" {
            let items = (0..<9).map { #"{"Id":"show-\#($0)","Type":"Series"}"# }.joined(separator: ",")
            json = #"{"Items":[\#(items)]}"#
        } else {
            let id = try XCTUnwrap(query("ParentId"))
            started.append(id)
            active += 1
            peak = max(peak, active)
            if !released { await withCheckedContinuation { waits[id] = $0 } }
            active -= 1
            json = #"{"Items":[{"Id":"played","Type":"Episode","SeriesId":"\#(id)","UserData":{"LastPlayedDate":"2026-09-01T00:00:00Z"}}]}"#
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: baseURL.appendingPathComponent(endpoint.path), statusCode: 200, httpVersion: nil, headerFields: nil
        ))
        return (Data(json.utf8), response)
    }
}
