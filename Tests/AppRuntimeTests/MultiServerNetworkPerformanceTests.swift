import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import XCTest
@testable import TestSupportNetworking
@testable import TestSupportPerformance

@MainActor
final class MultiServerNetworkPerformanceTests: XCTestCase {
    func testPerformanceOneServer() async throws { try await measure("one", count: 1) }
    func testPerformanceThreeServers() async throws { try await measure("three", count: 3) }
    func testPerformanceTenServers() async throws { try await measure("ten", count: 10) }
    func testPerformanceTwentyServers() async throws { try await measure("twenty", count: 20) }
    func testPerformanceLargeResponses() async throws {
        try await measure("large", count: 20, libraries: 24, overviewBytes: 16_384)
    }
    func testPerformanceAdverseServers() async throws {
        try await measure("adverse", count: 20, adverse: true)
    }

    func testCancelledMultiServerHomeSettlesWithoutStartingEveryAccount() async throws {
        try await withServers(count: 20, libraries: 8, overviewBytes: 128, adverse: false, delay: .seconds(2)) {
            accounts, wire in
            let task = Task { await HomeAggregator().content(from: accounts) }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(3)
            while await wire.snapshot().requests < 5 {
                guard ContinuousClock.now < deadline else {
                    XCTFail("Home did not start its requests")
                    throw AppError.invalidResponse
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let start = ContinuousClock.now
            task.cancel()
            _ = await task.value
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
            let state = await wire.snapshot()
            XCTAssertLessThan(state.accounts.count, accounts.count)
        }
    }

    private func measure(
        _ name: String, count: Int, libraries: Int = 8, overviewBytes: Int = 128, adverse: Bool = false
    ) async throws {
        try await PerformanceProbe.measure(self, scenario: "home-network-\(name)") {
            try await self.withServers(
                count: count, libraries: libraries, overviewBytes: overviewBytes, adverse: adverse
            ) { accounts, wire in
                let progress = NetworkHomeProgress()
                var peak = Int64(0)
                var maximumGap = Duration.zero
                let heartbeat = Task { @MainActor in
                    var previous = ContinuousClock.now
                    while !Task.isCancelled {
                        peak = max(peak, try PerformanceProbe.memoryUsage()["physicalFootprintBytes"] ?? 0)
                        do { try await Task.sleep(for: .milliseconds(5)) }
                        catch is CancellationError { break }
                        let now = ContinuousClock.now
                        maximumGap = max(maximumGap, previous.duration(to: now))
                        previous = now
                    }
                }
                defer { heartbeat.cancel() }
                let start = ContinuousClock.now
                async let navigation = HomeAggregator().libraryDiscovery(from: accounts)
                async let home = HomeAggregator().content(
                    from: accounts, continueWatchingLimit: count * 20, latestLimit: count * 20,
                    onProgress: { await progress.record($0) }
                )
                // Foreground metadata competes with the bulk work, but keeps its
                // production interactive pool. Two readers request the same detail.
                let detailStart = ContinuousClock.now
                let details = try await withThrowingTaskGroup(of: [MediaItem].self) { group in
                    for account in accounts.dropLast(adverse ? 1 : 0) {
                        group.addTask {
                            async let first = account.provider.item(id: "movie-0")
                            async let second = account.provider.item(id: "movie-0")
                            return try await [first, second]
                        }
                    }
                    var result: [MediaItem] = []
                    for try await items in group { result += items }
                    return result
                }
                let detailTime = detailStart.duration(to: .now)
                let content = await home
                let discovered = await navigation
                let elapsed = start.duration(to: .now)
                heartbeat.cancel()
                try await heartbeat.value
                let healthy = count - (adverse ? 1 : 0)
                XCTAssertEqual(discovered.failures.count, adverse ? 1 : 0)
                XCTAssertEqual(content.libraries.count, healthy * (libraries + 1))
                XCTAssertEqual(discovered.libraries.map(\.accountID), content.libraries.map(\.accountID))
                XCTAssertEqual(content.latest.count, healthy * 20)
                XCTAssertEqual(content.continueWatching.count, healthy * 20)
                XCTAssertEqual(details.count, healthy * 2)
                XCTAssertTrue(details.allSatisfy { $0.id == "movie-0" })
                XCTAssertEqual(Set(content.latest.map(\.sourceAccountID)).count, healthy)
                let state = await wire.snapshot()
                XCTAssertEqual(state.unexpected, 0)
                XCTAssertGreaterThan(state.requests, 0)
                return [
                    "servers": count, "libraries": content.libraries.count,
                    "items": content.latest.count + content.continueWatching.count,
                    "failedAccounts": discovered.failures.count, "wireRequests": state.requests,
                    "responseBytes": state.bytes, "peakServerRequests": state.peak,
                    "detailTransfers": state.details, "firstContentMicroseconds": await progress.first,
                    "allContentMicroseconds": elapsed.microseconds, "detailMicroseconds": detailTime.microseconds,
                    "maximumMainActorGapMicroseconds": maximumGap.microseconds,
                    "sampledPeakFootprintBytes": Int(peak),
                ]
            }
        }
    }

    private func withServers<T>(
        count: Int, libraries: Int, overviewBytes: Int, adverse: Bool, delay: Duration = .milliseconds(5),
        operation: ([ResolvedAccount], NetworkHomeWire) async throws -> T
    ) async throws -> T {
        let wire = NetworkHomeWire()
        var servers: [LoopbackHTTPServer] = []
        do {
            var accounts: [ResolvedAccount] = []
            let namespace = UUID().uuidString
            for index in 0..<count {
                let id = "\(namespace)-\(index)"
                let fixture = try NetworkHomeResponses(id: id, libraries: libraries, overviewBytes: overviewBytes)
                let server = try LoopbackHTTPServer { request in
                    await wire.begin(index: index, detail: request.target.contains("/Items/movie-0"))
                    let response = fixture.response(request)
                    do { try await Task.sleep(for: adverse && index == 0 ? .milliseconds(300) : delay) }
                    catch is CancellationError {
                        await wire.end(bytes: 0, unexpected: false)
                        return .init(disconnect: true)
                    } catch {
                        XCTFail("Fixture delay failed: \(type(of: error))")
                    }
                    await wire.end(bytes: response.body.count, unexpected: response.status == 404)
                    return response
                }
                servers.append(server)
                let url = try await server.start()
                if adverse && index == count - 1 { await server.stop() }
                let session = UserSession(
                    server: .init(id: id, name: "Fixture", baseURL: url,
                                  provider: index.isMultiple(of: 2) ? .jellyfin : .emby),
                    userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture-\(index)"
                )
                let provider = JellyfinProvider(
                    session: session, http: URLSessionHTTPClient(),
                    interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive)
                )
                accounts.append(.init(account: Account(id: id, from: session), provider: provider))
            }
            let result = try await operation(accounts, wire)
            for server in servers { await server.stop() }
            return result
        } catch {
            for server in servers { await server.stop() }
            throw error
        }
    }
}

private actor NetworkHomeProgress {
    private let start = ContinuousClock.now
    private(set) var first = 0
    func record(_ progress: HomeAggregator.Progress) {
        if first == 0, !progress.content.latest.isEmpty || !progress.content.continueWatching.isEmpty {
            first = start.duration(to: .now).microseconds
        }
    }
}

private actor NetworkHomeWire {
    struct Snapshot {
        var requests = 0
        var bytes = 0
        var peak = 0
        var details = 0
        var unexpected = 0
        var accounts: Set<Int> = []
    }
    private var state = Snapshot()
    private var active = 0
    func begin(index: Int, detail: Bool) {
        state.requests += 1
        state.accounts.insert(index)
        if detail { state.details += 1 }
        active += 1
        state.peak = max(state.peak, active)
    }
    func end(bytes: Int, unexpected: Bool) {
        state.bytes += bytes
        if unexpected { state.unexpected += 1 }
        active -= 1
    }
    func snapshot() -> Snapshot { state }
}

private struct NetworkHomeResponses: Sendable {
    let id: String
    let views: Data
    let latest: Data
    let resume: Data
    let detail: Data

    init(id: String, libraries: Int, overviewBytes: Int) throws {
        self.id = id
        views = try JSONSerialization.data(withJSONObject: ["Items":
            [["Id": "movies", "Name": "Movies", "CollectionType": "movies"]]
            + (0..<libraries).map { ["Id": "collections-\($0)", "Name": "Collections", "CollectionType": "boxsets"] }
        ])
        let items: [[String: Any]] = (0..<20).map {
            ["Id": "movie-\($0)", "Name": "\(id) movie \($0)", "Type": "Movie",
             "Overview": String(repeating: "x", count: overviewBytes), "RunTimeTicks": 36_000_000_000,
             "DateCreated": "2026-01-01T00:00:00Z",
             "UserData": ["PlaybackPositionTicks": 600_000_000, "LastPlayedDate": "2026-01-01T00:00:00Z"]]
        }
        latest = try JSONSerialization.data(withJSONObject: items)
        resume = try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": items.count])
        detail = try JSONSerialization.data(withJSONObject: items[0])
    }

    func response(_ request: LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response {
        let components = URLComponents(string: "http://localhost" + request.target)
        let path = components?.path ?? ""
        if path.hasSuffix("/System/Info/Public") { return .json(#"{"Id":"\#(id)","ServerName":"Fixture"}"#) }
        if path.hasSuffix("/Views") { return .init(body: views) }
        if path.hasSuffix("/Items/movie-0") { return .init(body: detail) }
        if path.hasSuffix("/Items/Latest") { return .init(body: latest) }
        if path.hasSuffix("/Items/Resume") { return .init(body: resume) }
        if path.hasSuffix("/Shows/NextUp") { return .json(#"{"Items":[],"TotalRecordCount":0}"#) }
        if path.hasSuffix("/Items") {
            if components?.queryItems?.contains(where: { $0.name == "IncludeItemTypes" && $0.value == "BoxSet" }) == true {
                return .json(#"{"Items":[{"Id":"boxset","Name":"Box","Type":"BoxSet"}],"TotalRecordCount":1}"#)
            }
            if components?.queryItems?.contains(where: { $0.name == "Filters" && $0.value == "IsFavorite" }) == true {
                return .json(#"{"Items":[],"TotalRecordCount":0}"#)
            }
        }
        return .json("{}", status: 404)
    }
}

private extension Duration {
    var microseconds: Int {
        Int(components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000)
    }
}
