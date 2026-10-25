import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let animeFirst = #"{"id":"chunk-a","tmdb_season":1,"tmdb_episode_start":1,"tmdb_episode_end":12}"#
private let animeSpecial = #"{"id":"chunk-b","tmdb_season":0,"tmdb_episode_start":1,"tmdb_episode_end":1,"chunk_tmdb_id":200}"#
private func animeGroup(
    _ chunks: [String], id: String = "group-a", season: Int = 2, source: String = "user"
) -> String {
    #"{"pmdb_id":"\#(id)","season_number":\#(season),"season_name":"Arc","source":"\#(source)","contributor":"author","votes":0,"recommended":true,"chunks":[\#(chunks.joined(separator: ","))]}"#
}
private func animeResponse(_ groups: [String], total: Int) -> String {
    #"{"tmdb_id":100,"seasons":[\#(groups.joined(separator: ","))],"total":\#(total)}"#
}

@MainActor
final class PublicMetaDBAnimeManagementTests: XCTestCase {
    private func withService(
        transport: ((RecordingHTTPClient) -> any HTTPClient)? = nil,
        _ body: (PublicMetaDBService, RecordingHTTPClient, UUID) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBAnimeManagementTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#)
        let service = PublicMetaDBService(
            credentials: AnimeCredentials(), http: transport?(http) ?? http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        try await body(service, http, XCTUnwrap(service.connectionID))
    }

    private func mapping() throws -> PublicMetaDB.AnimeMapping {
        try .init(tmdbID: 100, seasonNumber: 2, seasonName: "Arc", chunks: [
            .init(tmdbSeason: 1, tmdbEpisodeStart: 1, tmdbEpisodeEnd: 12),
            .init(tmdbSeason: 0, tmdbEpisodeStart: 1, tmdbEpisodeEnd: 1, chunkTmdbID: 200)
        ])
    }

    func testCompleteReadsCountChunksNotGroupsAndPreserveCrossShowSpecials() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([animeGroup([animeFirst, animeSpecial])], total: 2))
            let result = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            XCTAssertEqual(result.seasons.count, 1)
            XCTAssertEqual(result.total, 2)
            XCTAssertEqual(result.seasons.first?.seasonNumber, 2)
            XCTAssertEqual(result.seasons.first?.chunks.last?.value.tmdbSeason, 0)
            XCTAssertEqual(result.seasons.first?.chunks.last?.value.chunkTmdbID, 200)
            XCTAssertFalse(http.sent.contains { $0.body != nil })
            XCTAssertNil(service.playbackConsent)
            XCTAssertNil(service.watchlistSelection)
        }
    }

    func testInvalidCollectionsCannotAuthorizeEditing() async throws {
        for response in [
            animeResponse([animeGroup([animeFirst, animeSpecial])], total: 1),
            animeResponse([animeGroup([animeFirst, animeFirst])], total: 2),
            animeResponse([animeGroup([animeFirst]), animeGroup([animeSpecial])], total: 2),
            animeResponse([animeGroup([])], total: 0),
            animeResponse([animeGroup([animeFirst], source: "unknown")], total: 1),
            animeResponse([animeGroup([animeFirst], season: 0)], total: 1),
            animeResponse([animeGroup([animeFirst])], total: 1).replacingOccurrences(of: #""tmdb_id":100"#, with: #""tmdb_id":999"#)
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/anime-seasons", json: response)
                do {
                    _ = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
                    XCTFail("Invalid mapping collection accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            }
        }
    }

    func testReplacementVerifiesReturnedIDsAndSupportsReadbackChunkReordering() async throws {
        try await withService { service, http, connection in
            let before = animeResponse([], total: 0)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: #"{"success":true,"tmdb_id":100,"season_number":2,"season_name":"Arc","chunks":[\#(animeFirst),\#(animeSpecial)]}"#)
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([animeGroup([animeSpecial, animeFirst])], total: 2))
            let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            try await service.replaceManagedAnimeMapping(mapping(), observed: observed, expectedConnectionID: connection)
            let writes = http.sent.filter { $0.body != nil }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?.json?["season_number"] as? Int, 2)
            let chunks = try XCTUnwrap(writes.first?.json?["chunks"] as? [[String: Any]])
            XCTAssertEqual(chunks.last?["tmdb_season"] as? Int, 0)
            XCTAssertEqual(chunks.last?["chunk_tmdb_id"] as? Int, 200)
        }
    }

    func testChangedReviewBlocksReplacementBeforeWriting() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([], total: 0))
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([animeGroup([animeFirst])], total: 1))
            let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            do {
                try await service.replaceManagedAnimeMapping(mapping(), observed: observed, expectedConnectionID: connection)
                XCTFail("Stale replacement accepted")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertFalse(http.sent.contains { $0.body != nil })
        }
    }

    func testCachedOrWrongGroupReadbackCannotConfirmReplacement() async throws {
        for after in [
            animeResponse([], total: 0),
            animeResponse([animeGroup([animeFirst, animeSpecial], season: 3)], total: 2),
            animeResponse([animeGroup([animeFirst, animeSpecial], source: "community")], total: 2),
            animeResponse([animeGroup([animeFirst, animeSpecial.replacingOccurrences(of: "200", with: "201")])], total: 2)
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/anime-seasons", json: animeResponse([], total: 0))
                http.stub(pathSuffix: "/anime-seasons", json: animeResponse([], total: 0))
                http.stub(pathSuffix: "/anime-seasons", json: #"{"success":true,"tmdb_id":100,"season_number":2,"season_name":"Arc","chunks":[\#(animeFirst),\#(animeSpecial)]}"#)
                http.stub(pathSuffix: "/anime-seasons", json: after)
                let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
                do {
                    try await service.replaceManagedAnimeMapping(mapping(), observed: observed, expectedConnectionID: connection)
                    XCTFail("Unconfirmed replacement accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            }
        }
    }

    func testWholeSeasonDeletionConfirmsCountAndPreservesCommunityGroup() async throws {
        try await withService { service, http, connection in
            let community = animeGroup(
                [animeFirst.replacingOccurrences(of: "chunk-a", with: "community-chunk")], id: "community", source: "community"
            )
            let before = animeResponse([animeGroup([animeFirst, animeSpecial]), community], total: 3)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: #"{"success":true,"deleted":2}"#)
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([community], total: 1))
            let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            try await service.deleteManagedAnimeSeason(seasonNumber: 2, observed: observed, expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/anime-seasons") }.count, 4)
        }
    }

    func testWholeDeletionRejectsPartialWrongSeasonAndUnchangedReadback() async throws {
        for (beforeGroup, afterGroups, total) in [
            (animeGroup([animeFirst, animeSpecial]), [animeGroup([animeSpecial])], 1),
            (animeGroup([animeFirst, animeSpecial], season: 3), [], 0),
            (animeGroup([animeFirst, animeSpecial], source: "community"), [], 0),
            (animeGroup([animeFirst, animeSpecial]), [animeGroup([animeFirst, animeSpecial])], 2)
        ] {
            try await withService { service, http, connection in
                let before = animeResponse([beforeGroup], total: 2)
                http.stub(pathSuffix: "/anime-seasons", json: before)
                http.stub(pathSuffix: "/anime-seasons", json: before)
                http.stub(pathSuffix: "/anime-seasons", json: #"{"success":true,"deleted":2}"#)
                http.stub(pathSuffix: "/anime-seasons", json: animeResponse(afterGroups, total: total))
                let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
                do {
                    try await service.deleteManagedAnimeSeason(seasonNumber: 2, observed: observed, expectedConnectionID: connection)
                    XCTFail("Wrong deletion accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            }
        }
    }

    func testMissingUnboundedOrUncertainDeleteCountCannotBeGuessedFromContributor() async throws {
        for reply in ["{}", #"{"success":true}"#, #"{"success":true,"deleted":-1}"#, #"{"success":true,"deleted":9223372036854775807}"#] {
            try await withService { service, http, connection in
                let before = animeResponse([animeGroup([animeFirst, animeSpecial])], total: 2)
                http.stub(pathSuffix: "/anime-seasons", json: before)
                http.stub(pathSuffix: "/anime-seasons", json: before)
                http.stub(pathSuffix: "/anime-seasons", json: reply)
                http.stub(pathSuffix: "/anime-seasons", json: animeResponse([], total: 0))
                let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
                do {
                    try await service.deleteManagedAnimeSeason(seasonNumber: 2, observed: observed, expectedConnectionID: connection)
                    XCTFail("Unknown or invalid count accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            }
        }
    }

    func testExactChunkDeletionPreservesSiblingAndWholeGroupRouteIsNotUsed() async throws {
        try await withService { service, http, connection in
            let before = animeResponse([animeGroup([animeFirst, animeSpecial])], total: 2)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([animeGroup([animeSpecial])], total: 1))
            http.stub(pathSuffix: "/chunk-a", json: #"{"success":true}"#)
            let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            let chunk = try XCTUnwrap(observed.seasons.first?.chunks.first)
            try await service.deleteManagedAnimeChunk(chunk, tmdbID: 100, expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), [
                "/api/external/anime-seasons", "/api/external/anime-seasons/chunk-a", "/api/external/anime-seasons"
            ])
        }
    }

    func testDisconnectBeforeReplacementOrDeletionNeverSendsAWrite() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/anime-seasons", json: animeResponse([animeGroup([animeFirst])], total: 1))
            let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            service.selectProfile(namespace: "different-profile")
            let count = http.sent.count
            do {
                try await service.replaceManagedAnimeMapping(mapping(), observed: observed, expectedConnectionID: connection)
                XCTFail("Disconnected replacement admitted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            do {
                try await service.deleteManagedAnimeSeason(seasonNumber: 2, observed: observed, expectedConnectionID: connection)
                XCTFail("Disconnected deletion admitted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testWholeAndChunkDeletesCannotOverlapAnInFlightReplacement() async throws {
        let barrier = AnimeMutationBarrier()
        try await withService(transport: { PausingAnimeHTTP(recording: $0, barrier: barrier) }) { service, http, connection in
            let before = animeResponse([animeGroup([animeFirst, animeSpecial])], total: 2)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            http.stub(pathSuffix: "/anime-seasons", json: #"{"success":true,"tmdb_id":100,"season_number":2,"season_name":"Arc","chunks":[\#(animeFirst),\#(animeSpecial)]}"#)
            http.stub(pathSuffix: "/anime-seasons", json: before)
            let observed = try await service.animeMappingsForManagement(tmdbID: 100, expectedConnectionID: connection)
            let input = try mapping()
            let started = expectation(description: "Replacement preflight suspended")
            await barrier.arm(started)
            let replacement = Task {
                try await service.replaceManagedAnimeMapping(input, observed: observed, expectedConnectionID: connection)
            }
            await fulfillment(of: [started], timeout: 2)
            let count = http.sent.count
            do {
                try await service.deleteManagedAnimeSeason(seasonNumber: 2, observed: observed, expectedConnectionID: connection)
                XCTFail("Whole deletion overlapped replacement")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            do {
                try await service.deleteManagedAnimeChunk(
                    XCTUnwrap(observed.seasons.first?.chunks.first), tmdbID: 100, expectedConnectionID: connection
                )
                XCTFail("Chunk deletion overlapped replacement")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertEqual(http.sent.count, count)
            await barrier.release()
            try await replacement.value
            XCTAssertTrue(service.activeAnimeMutations.isEmpty)
        }
    }
}

private struct AnimeCredentials: PublicMetaDBCredentialStoring {
    func load(namespace: String?) -> PublicMetaDBCredentials? { nil }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {}
    func clear(namespace: String?) throws {}
}

private actor AnimeMutationBarrier {
    private var started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ expectation: XCTestExpectation) { started = expectation }
    func waitIfArmed() async {
        guard let started else { return }
        self.started = nil
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct PausingAnimeHTTP: HTTPClient {
    let recording: RecordingHTTPClient
    let barrier: AnimeMutationBarrier
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        if endpoint.path.hasSuffix("/anime-seasons") { await barrier.waitIfArmed() }
        return try await recording.sendRaw(endpoint, baseURL: baseURL)
    }
}
