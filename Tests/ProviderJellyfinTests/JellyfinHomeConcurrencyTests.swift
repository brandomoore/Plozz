import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinHomeConcurrencyTests: XCTestCase {
    func testCollectionProbesUseABoundedRefillingWindowAndPreserveAvailability() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = CollectionProbeHTTPClient()
            addTeardownBlock { await http.releaseAll() }
            let provider = JellyfinProvider(session: session(kind), http: http)
            let load = Task { try await provider.libraries() }
            defer { load.cancel() }
            try await waitUntil { await http.requests.count >= 4 }
            let initial = await http.requests
            XCTAssertEqual(initial.count, 4)
            for endpoint in initial {
                func value(_ name: String) -> String? { endpoint.queryItems.first { $0.name == name }?.value }
                XCTAssertEqual(value("Limit"), "1")
                XCTAssertEqual(value("EnableImages"), "false")
                XCTAssertEqual(value("EnableTotalRecordCount"), "true")
                XCTAssertNil(value("Fields"))
                XCTAssertNil(value("SortBy"))
            }
            await http.release("collection-3")
            try await waitUntil { await http.requests.count == 5 }
            await http.releaseAll()
            let libraries = try await load.value
            let peak = await http.peak
            XCTAssertEqual(peak, 4)
            XCTAssertEqual(libraries.map(\.id), (0..<5).map { "collection-\($0)" })
            XCTAssertEqual(libraries.map(\.hasCollections), [true, false, nil, true, true])
        }
    }

    func testCancelledCollectionDiscoveryDoesNotStartTheRemainingProbe() async throws {
        let http = CollectionProbeHTTPClient()
        addTeardownBlock { await http.releaseAll() }
        let provider = JellyfinProvider(session: session(.jellyfin), http: http)
        let load = Task { try await provider.libraries() }
        try await waitUntil { await http.requests.count == 4 }
        load.cancel()
        do { _ = try await load.value; XCTFail("Cancelled discovery succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await http.releaseAll()
        let count = await http.requests.count
        XCTAssertEqual(count, 4)
    }

    func testLatestEpisodeLookupsRefillFourSlotsWithoutChangingFeedMembership() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = RecencyWindowHTTPClient()
            addTeardownBlock { await http.releaseAll() }
            let provider = JellyfinProvider(session: session(kind), http: http)
            let load = Task { try await provider.continueWatching(limit: .max) }
            defer { load.cancel() }
            try await waitUntil { await http.started.count >= 4 }
            let first = await http.started
            XCTAssertEqual(Set(first), Set((0..<4).map { "show-\($0)" }))
            await http.release("show-3")
            try await waitUntil { await http.started.count == 5 }
            await http.releaseAll()
            let items = try await load.value
            let peak = await http.peak
            let started = await http.started
            XCTAssertEqual(Set(items.map(\.id)), Set((0..<9).map { "episode-\($0)" }))
            XCTAssertEqual(started.count, 9)
            XCTAssertEqual(peak, 4)
            XCTAssertTrue(items.allSatisfy {
                $0.lastPlayedAt == JellyfinProvider.parseDate("2026-09-01T00:00:00Z")
            })
        }
    }

    private func session(_ kind: ProviderKind) -> UserSession {
        UserSession(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                          provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "test", accessToken: "fixture"
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("The bounded request window did not reach the expected state")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor CollectionProbeHTTPClient: HTTPClient {
    private(set) var requests: [Endpoint] = []
    private(set) var peak = 0
    private var active = 0
    private var released = false
    private var waits: [String: CheckedContinuation<Void, Never>] = [:]

    func release(_ id: String) { waits.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        released = true
        let pending = Array(waits.values)
        waits.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        if endpoint.path.hasSuffix("/Views") {
            let items = (0..<5).map {
                #"{"Id":"collection-\#($0)","Name":"Collection \#($0)","CollectionType":"boxsets"}"#
            }.joined(separator: ",")
            json = #"{"Items":[\#(items)]}"#
        } else {
            let id = try XCTUnwrap(endpoint.queryItems.first { $0.name == "ParentId" }?.value)
            requests.append(endpoint)
            active += 1
            peak = max(peak, active)
            if !released { await withCheckedContinuation { waits[id] = $0 } }
            active -= 1
            try Task.checkCancellation()
            if id == "collection-2" { throw AppError.serverUnreachable }
            json = id == "collection-1" ? #"{"Items":[],"TotalRecordCount":0}"#
                : #"{"Items":[{"Id":"boxset","Type":"BoxSet"}],"TotalRecordCount":10000}"#
        }
        return (Data(json.utf8), try XCTUnwrap(HTTPURLResponse(
            url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
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
        let pending = Array(waits.values)
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
            try Task.checkCancellation()
            json = #"{"Items":[{"Id":"played","Type":"Episode","SeriesId":"\#(id)","UserData":{"LastPlayedDate":"2026-09-01T00:00:00Z"}}]}"#
        }
        return (Data(json.utf8), try XCTUnwrap(HTTPURLResponse(
            url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
        )))
    }
}
