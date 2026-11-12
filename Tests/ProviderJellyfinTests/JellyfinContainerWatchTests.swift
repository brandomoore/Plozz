import XCTest
import Foundation
@testable import CoreModels
import CoreNetworking
@testable import ProviderJellyfin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class JellyfinContainerWatchTests: XCTestCase {
    func testAcknowledgedContainerWriteRepairsEpisodesForBothBackendsAndActions() async throws {
        for backend in [ProviderKind.jellyfin, .emby] {
            for kind in [MediaItemKind.season, .series] {
                for played in [false, true] {
                    let http = ContainerWatchHTTP(played: !played)
                    let provider: any WatchStateProviding = provider(http, kind: backend)
                    try await provider.setPlayed(
                        played, itemID: kind == .season ? "season" : "series",
                        kind: kind, capturedAt: .distantPast
                    )
                    let states = await http.states
                    for index in 0..<3 {
                        let included = kind == .series || index < 2
                        XCTAssertEqual(states[index].played, included ? played : !played)
                        XCTAssertEqual(states[index].ticks, included ? 0 : 300)
                    }
                }
            }
        }
    }

    func testNativeCascadeUsesCompleteShortPagesWithoutLeafWrites() async throws {
        let http = ContainerWatchHTTP(count: 205, nativeCascade: true)
        try await provider(http).setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
        let states = await http.states
        let leafWrites = await http.leafWrites
        let offsets = await http.offsets
        XCTAssertEqual(states.count, 205)
        XCTAssertTrue(states.allSatisfy { $0.played && $0.ticks == 0 })
        XCTAssertTrue(leafWrites.isEmpty)
        XCTAssertEqual(offsets, [0, 80, 160])
    }

    func testListSummaryCannotConfirmUnchangedIndividualEpisodes() async throws {
        let http = ContainerWatchHTTP(listPlayed: true)
        try await provider(http).setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
        let states = await http.states
        let writes = await http.leafWrites
        XCTAssertTrue(states.allSatisfy { $0.played && $0.ticks == 0 })
        XCTAssertEqual(writes.count, 3)
    }

    func testPartialFailureThrowsAndRetryRepairsOnlyUnfinishedLeaves() async throws {
        let http = ContainerWatchHTTP(failOnceOn: "episode1")
        let provider = provider(http)
        do {
            try await provider.setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
            XCTFail("Partial container delivery must remain retryable")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        try await provider.setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
        let writes = await http.leafWrites
        let states = await http.states
        XCTAssertEqual(writes.filter { $0 == "episode0" }.count, 1)
        XCTAssertTrue(states.allSatisfy { $0.played && $0.ticks == 0 })
    }

    func testAcknowledgedButUnchangedLeavesAreNotSuccessfulDelivery() async throws {
        let http = ContainerWatchHTTP(ignoreLeafWrites: true)
        do {
            try await provider(http).setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
            XCTFail("An HTTP acknowledgement is not proof of episode state")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testUnrelatedEpisodeFailsBeforeAnyWrite() async throws {
        let http = ContainerWatchHTTP(foreignEpisode: true)
        do {
            try await provider(http).setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
            XCTFail("Foreign episode must not be mutated")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let writes = await http.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testAuthorizationRevokedAfterContainerWritePreventsLeafFallback() async throws {
        let http = ContainerWatchHTTP()
        let authorization = WatchMutationDeliveryAuthorization {
            if await http.writeCount > 0 { throw AppError.cancelled }
        }
        do {
            try await WatchMutationDeliveryAuthorization.$current.withValue(authorization) {
                try await provider(http).setPlayed(true, itemID: "series", kind: .series, capturedAt: .distantPast)
            }
            XCTFail("Revoked authorization must stop delivery")
        } catch {
            XCTAssertEqual(error as? AppError, .cancelled)
        }
        let writes = await http.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testKnownLeafDoesNotReadContainerMetadata() async throws {
        let http = ContainerWatchHTTP()
        try await provider(http).setPlayed(true, itemID: "episode0", kind: .episode, capturedAt: .distantPast)
        let offsets = await http.offsets
        let writes = await http.writeCount
        XCTAssertTrue(offsets.isEmpty)
        XCTAssertEqual(writes, 1)
    }

    private func provider(_ http: ContainerWatchHTTP, kind: ProviderKind = .jellyfin) -> JellyfinProvider {
        JellyfinProvider(session: UserSession(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "http://localhost")!, provider: kind),
            userID: "user", userName: "Fixture", deviceID: "device", accessToken: "fixture"
        ), http: http)
    }
}

private actor ContainerWatchHTTP: HTTPClient {
    struct State {
        var played: Bool
        var ticks: Int
    }
    private(set) var states: [State]
    private(set) var leafWrites: [String] = []
    private(set) var offsets: [Int] = []
    private(set) var writeCount = 0
    private let nativeCascade: Bool
    private let ignoreLeafWrites: Bool
    private let foreignEpisode: Bool
    private let listPlayed: Bool?
    private var failOnceOn: String?

    init(
        count: Int = 3, played: Bool = false, nativeCascade: Bool = false,
        failOnceOn: String? = nil, ignoreLeafWrites: Bool = false, foreignEpisode: Bool = false,
        listPlayed: Bool? = nil
    ) {
        states = Array(repeating: State(played: played, ticks: 300), count: count)
        self.nativeCascade = nativeCascade
        self.failOnceOn = failOnceOn
        self.ignoreLeafWrites = ignoreLeafWrites
        self.foreignEpisode = foreignEpisode
        self.listPlayed = listPlayed
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let path = endpoint.path
        var body: [String: Any] = [:]
        if endpoint.method == .get, path == "/Users/user/Items" {
            func query(_ name: String) -> String? { endpoint.queryItems.first { $0.name == name }?.value }
            guard query("Recursive") == "true", query("IncludeItemTypes") == "Episode",
                  let offset = query("StartIndex").flatMap(Int.init),
                  let limit = query("Limit").flatMap(Int.init) else { throw AppError.invalidResponse }
            offsets.append(offset)
            let indices = states.indices.filter { query("ParentId") == "series" || $0 < 2 }
            let page = indices.dropFirst(offset).prefix(min(limit, 80))
            body = ["Items": page.map { index -> [String: Any] in
                ["Id": "episode\(index)", "Type": "Episode",
                 "SeriesId": foreignEpisode ? "foreign" : "series",
                 "SeasonId": index < 2 ? "season" : "other-season",
                 "UserData": listPlayed.map { ["Played": $0, "PlaybackPositionTicks": 0] } ?? userData(index)]
            }, "TotalRecordCount": indices.count]
        } else if path.contains("/PlayedItems/") {
            writeCount += 1
            let id = String(path.split(separator: "/").last!)
            let played = endpoint.method == .post
            if id == "series" || id == "season" {
                if nativeCascade {
                    for index in states.indices where id == "series" || index < 2 {
                        states[index] = State(played: played, ticks: 0)
                    }
                }
            } else if let index = Int(id.replacingOccurrences(of: "episode", with: "")) {
                if failOnceOn == id {
                    failOnceOn = nil
                    throw AppError.serverUnreachable
                }
                leafWrites.append(id)
                if !ignoreLeafWrites { states[index].played = played }
            } else { throw AppError.invalidResponse }
        } else if path.hasSuffix("/UserData") {
            writeCount += 1
            guard let component = path.split(separator: "/").first(where: { $0.hasPrefix("episode") }),
                  let index = Int(component.dropFirst("episode".count)),
                  let data = endpoint.body,
                  let update = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ticks = update["PlaybackPositionTicks"] as? Int else { throw AppError.invalidResponse }
            if !ignoreLeafWrites { states[index].ticks = ticks }
        } else if endpoint.method == .get,
                  let id = path.split(separator: "/").last,
                  let index = Int(id.dropFirst("episode".count)) {
            body = ["Id": String(id), "Type": "Episode", "UserData": userData(index),
                    "SeriesId": "series", "SeasonId": index < 2 ? "season" : "other-season"]
        } else { throw AppError.invalidResponse }
        return (
            try JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    private func userData(_ index: Int) -> [String: Any] {
        ["Played": states[index].played, "PlaybackPositionTicks": states[index].ticks]
    }
}
