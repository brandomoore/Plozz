import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import XCTest
@testable import TestSupportPerformance

/// Read-only, opt-in measurement. Authenticated responses and media identities stay in memory.
@MainActor
final class JellyfinHomePerformanceTests: XCTestCase {
    func testPerformanceLiveHome() async throws {
        try PerformanceProbe.requireEnabled()
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_JELLYFIN_HOME_BROKER"] else {
            throw XCTSkip("An explicitly authorized internal Jellyfin broker is required.")
        }
        let broker = try XCTUnwrap(URL(string: address))
        guard broker.scheme == "http", broker.host == "127.0.0.1", broker.port != nil,
              broker.user == nil, broker.password == nil, broker.query == nil, broker.fragment == nil else {
            throw ProbeError.invalidConfiguration
        }
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: broker, timeoutInterval: 10)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProbeError.invalidConfiguration
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard ["http", "https"].contains(configuration.baseURL.scheme),
              configuration.baseURL.host != nil, configuration.baseURL.user == nil,
              configuration.baseURL.password == nil, configuration.baseURL.query == nil,
              !configuration.token.isEmpty else { throw ProbeError.invalidConfiguration }
        let session = UserSession(
            server: .init(id: configuration.serverID, name: "Internal measurement",
                          baseURL: configuration.baseURL, provider: .jellyfin),
            userID: configuration.userID, userName: configuration.username,
            deviceID: configuration.deviceID, accessToken: configuration.token
        )
        try await PerformanceProbe.measure(self, scenario: "home-jellyfin-live") {
            let http = CountingHTTP()
            let provider = JellyfinProvider(session: session, http: http)
            let accounts = [ResolvedAccount(account: Account(id: "measurement", from: session), provider: provider)]
            let visibility = HomeLibraryVisibilityModel(store: MemoryVisibility())
            let cold = try await self.load(accounts, visibility: visibility, http: http, navigation: true)
            let warm = try await self.load(accounts, visibility: visibility, http: http, navigation: false)
            XCTAssertEqual(cold.rows, warm.rows)
            XCTAssertEqual(cold.libraries, warm.libraries)
            return [
                "coldRequests": cold.http.requests, "warmRequests": warm.http.requests,
                "coldBytes": cold.http.bytes, "warmBytes": warm.http.bytes,
                "coldViewsRequests": cold.http.views, "warmViewsRequests": warm.http.views,
                "coldDuplicateRequests": cold.http.duplicates, "warmDuplicateRequests": warm.http.duplicates,
                "coldFirstRowMicroseconds": cold.firstRow, "warmFirstRowMicroseconds": warm.firstRow,
                "coldAllRowsMicroseconds": cold.complete, "warmAllRowsMicroseconds": warm.complete,
                "libraries": warm.libraries, "rows": warm.rows, "items": warm.items
            ]
        }
    }

    private func load(
        _ accounts: [ResolvedAccount], visibility: HomeLibraryVisibilityModel, http: CountingHTTP,
        navigation: Bool
    ) async throws -> Measurement {
        await http.reset()
        let clock = ProgressClock()
        let navigationTask = navigation ? Task {
            await HomeAggregator().libraryDiscovery(from: accounts)
        } : nil
        await visibility.prepareServerDefaults(accounts: accounts)
        XCTAssertTrue(visibility.serverMatchFailures.isEmpty)
        let content = await HomeAggregator().unmergedContent(
            from: accounts, watchlistLimit: 100, visibility: visibility.visibility,
            onProgress: { await clock.record($0) }
        )
        if let discovered = await navigationTask?.value {
            XCTAssertTrue(discovered.failures.isEmpty)
        }
        let timing = await clock.result()
        XCTAssertEqual(timing.failures, 0)
        XCTAssertTrue(content.serverRows.allSatisfy { $0.failure == nil && !$0.isLoading })
        XCTAssertFalse(content.libraries.isEmpty)
        XCTAssertGreaterThan(timing.first, 0, "A completed nonempty content row must be observed.")
        let items = content.continueWatching.count + content.latest.count + content.watchlist.count
            + content.serverRows.reduce(0) { $0 + $1.items.count }
        XCTAssertGreaterThan(items, 0)
        return Measurement(
            http: await http.snapshot(), firstRow: timing.first, complete: timing.complete,
            libraries: content.libraries.count, rows: content.serverRows.count, items: items
        )
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
    }

    private enum ProbeError: Error { case invalidConfiguration }

    private struct MemoryVisibility: HomeLibraryVisibilityStoring {
        func load() -> HomeLibraryVisibility { .default }
        func save(_ visibility: HomeLibraryVisibility) {}
    }

    private struct Measurement {
        let http: CountingHTTP.Snapshot
        let firstRow: Int
        let complete: Int
        let libraries: Int
        let rows: Int
        let items: Int
    }
}

private actor ProgressClock {
    private let start = ContinuousClock.now
    private var first = 0
    private var failures = 0

    func record(_ progress: HomeAggregator.Progress) {
        failures = max(failures, progress.failures.count)
        let content = progress.content
        if first == 0, !content.continueWatching.isEmpty || !content.latest.isEmpty
            || !content.watchlist.isEmpty || content.serverRows.contains(where: { !$0.items.isEmpty }) {
            first = elapsed()
        }
    }

    func result() -> (first: Int, complete: Int, failures: Int) { (first, elapsed(), failures) }

    private func elapsed() -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000_000 + duration.attoseconds / 1_000_000_000_000)
    }
}

private actor CountingHTTP: HTTPClient {
    struct Snapshot {
        var requests = 0
        var bytes = 0
        var views = 0
        var duplicates = 0
    }
    private let wrapped = URLSessionHTTPClient()
    private var counters = Snapshot()
    private var requests = Set<String>()

    func reset() { counters = Snapshot(); requests = [] }
    func snapshot() -> Snapshot { counters }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        counters.requests += 1
        if endpoint.path.hasSuffix("/Views") { counters.views += 1 }
        let key = endpoint.path + endpoint.queryItems.map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        if !requests.insert(key).inserted { counters.duplicates += 1 }
        let result = try await wrapped.send(endpoint, baseURL: baseURL)
        counters.bytes += result.0.count
        return result
    }
}
