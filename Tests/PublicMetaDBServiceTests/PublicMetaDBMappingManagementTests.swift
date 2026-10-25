import CoreModels
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let mappingRecord = #"{"id":"map-a","value":"tt0137523","contributor":"author","updated":"2026-10-24T00:00:00Z"}"#
private let mappingCreated = #"{"success":true,"item":{"id":"map-a","tmdb_id":550,"media_type":"movie","id_type":"imdb","id_value":"tt0137523"}}"#
private let noMappingMatches = #"{"results":[],"total":0}"#
private func mappingResponse(_ records: [String]) -> String {
    #"{"tmdb_id":550,"media_type":"movie","mappings":{"imdb":[\#(records.joined(separator: ","))]},"total":\#(records.count)}"#
}

@MainActor
final class PublicMetaDBMappingManagementTests: XCTestCase {
    private func withService(
        _ body: (PublicMetaDBService, RecordingHTTPClient, UUID) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBMappingManagementTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#)
        let service = PublicMetaDBService(
            credentials: MappingCredentials(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        try await body(service, http, XCTUnwrap(service.connectionID))
    }

    private func mapping() throws -> PublicMetaDB.Mapping {
        try .init(content: .init(tmdbID: 550, mediaType: .movie), idType: .imdb, idValue: "tt0137523")
    }

    func testGroupedReadsRetainConflictsAndExactRecordRevision() async throws {
        try await withService { service, http, connection in
            let other = mappingRecord.replacingOccurrences(of: "map-a", with: "map-b")
                .replacingOccurrences(of: "tt0137523", with: "tt9999999")
            http.stub(pathSuffix: "/mappings", json: mappingResponse([mappingRecord, other]))
            let records = try await service.mappingsForManagement(mapping().content, expectedConnectionID: connection)
            XCTAssertEqual(records.map(\.id), ["map-a", "map-b"])
            XCTAssertEqual(records.map(\.value.idValue), ["tt0137523", "tt9999999"])
            XCTAssertEqual(records.first?.value, try mapping())
            XCTAssertEqual(records.first?.contributor, "author")
            XCTAssertEqual(records.first?.updated, "2026-10-24T00:00:00Z")
            XCTAssertFalse(service.communityRatingsEnabled)
            XCTAssertNil(service.playbackConsent)
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(http.sent.contains { $0.body != nil })
        }
    }

    func testIncompleteForeignDuplicateAndUnknownGroupsAreRejected() async throws {
        for response in [
            mappingResponse([mappingRecord]).replacingOccurrences(of: #""total":1"#, with: #""total":2"#),
            mappingResponse([mappingRecord]).replacingOccurrences(of: "550", with: "551"),
            mappingResponse([mappingRecord]).replacingOccurrences(of: "movie", with: "tv"),
            mappingResponse([mappingRecord, mappingRecord]),
            mappingResponse([mappingRecord]).replacingOccurrences(of: "imdb", with: "unknown"),
            mappingResponse([mappingRecord]).replacingOccurrences(of: "tt0137523", with: " ")
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/mappings", json: response)
                do {
                    _ = try await service.mappingsForManagement(mapping().content, expectedConnectionID: connection)
                    XCTFail("Invalid mapping collection accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            }
        }
    }

    func testEpisodeMappingCannotAccidentallyUseItsParentNamespace() async throws {
        try await withService { service, http, connection in
            let count = http.sent.count
            do {
                _ = try await service.mappingsForManagement(
                    .init(tmdbID: 550, mediaType: .tv, season: 1, episode: 1), expectedConnectionID: connection
                )
                XCTFail("Episode mapping was admitted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testReverseLookupKeepsMovieAndShowWithSameNumericIDDistinct() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/lookup", json: #"{"results":[{"tmdb_id":550,"media_type":"tv"},{"tmdb_id":550,"media_type":"movie"}],"total":2}"#)
            let values = try await service.lookupMapping(idType: .imdb, idValue: "tt0137523", expectedConnectionID: connection)
            XCTAssertEqual(values.map(\.mediaType), [.movie, .tv])
            XCTAssertFalse(http.sent.contains { $0.body != nil })
        }
    }

    func testReverseLookupRejectsPartialDuplicateChildAndWrongMediaType() async throws {
        for response in [
            #"{"results":[],"total":1}"#,
            #"{"results":[{"tmdb_id":550,"media_type":"tv"},{"tmdb_id":550,"media_type":"tv"}],"total":2}"#,
            #"{"results":[{"tmdb_id":550,"media_type":"tv","season":1}],"total":1}"#,
            #"{"results":[{"tmdb_id":550,"media_type":"movie"}],"total":1}"#
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/lookup", json: response)
                do {
                    _ = try await service.lookupMapping(
                        idType: .imdb, idValue: "tt0137523", mediaType: .tv, expectedConnectionID: connection
                    )
                    XCTFail("Invalid reverse lookup accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            }
        }
    }

    func testPublishingRechecksBothDirectionsAndReadsExactReturnedID() async throws {
        try await withService { service, http, connection in
            for _ in 0..<3 { http.stub(pathSuffix: "/mappings", json: mappingResponse([])) }
            http.stub(pathSuffix: "/mappings", json: mappingCreated)
            http.stub(pathSuffix: "/mappings", json: mappingResponse([mappingRecord]))
            http.stub(pathSuffix: "/lookup", json: noMappingMatches)
            let review = try await service.reviewMapping(mapping(), expectedConnectionID: connection)
            try await service.submitManagedMapping(review)
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/lookup") }.count, 2)
            let writes = http.sent.filter { $0.body != nil }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?.json?["id_type"] as? String, "imdb")
            XCTAssertEqual(writes.first?.json?["id_value"] as? String, "tt0137523")
            XCTAssertEqual(http.sentPaths.last, "/api/external/mappings")
        }
    }

    func testChangedForwardOrReverseBaselineBlocksPublishing() async throws {
        for changesForward in [false, true] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/mappings", json: mappingResponse([]))
                http.stub(pathSuffix: "/mappings", json: mappingResponse(changesForward ? [mappingRecord] : []))
                http.stub(pathSuffix: "/lookup", json: noMappingMatches)
                http.stub(pathSuffix: "/lookup", json: changesForward ? noMappingMatches :
                    #"{"results":[{"tmdb_id":551,"media_type":"movie"}],"total":1}"#)
                let review = try await service.reviewMapping(mapping(), expectedConnectionID: connection)
                do { try await service.submitManagedMapping(review); XCTFail("Stale mapping review accepted") }
                catch { XCTAssertEqual(error as? AppError, .conflict) }
                XCTAssertFalse(http.sent.contains { $0.body != nil })
            }
        }
    }

    func testUncertainCreationAndWrongExactReadbackNeverSucceedOrRetry() async throws {
        for creationFails in [false, true] {
            try await withService { service, http, connection in
                for _ in 0..<3 { http.stub(pathSuffix: "/mappings", json: mappingResponse([])) }
                http.stub(pathSuffix: "/mappings", json: creationFails ? "{}" : mappingCreated)
                http.stub(pathSuffix: "/mappings", json: mappingResponse([
                    mappingRecord.replacingOccurrences(of: "map-a", with: "unrelated-record")
                ]))
                http.stub(pathSuffix: "/lookup", json: noMappingMatches)
                let review = try await service.reviewMapping(mapping(), expectedConnectionID: connection)
                do { try await service.submitManagedMapping(review); XCTFail("Unconfirmed creation accepted") }
                catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            }
        }
    }

    func testDeletionPreservesOtherRecordsAndReconcilesAnUncertainReply() async throws {
        try await withService { service, http, connection in
            let other = mappingRecord.replacingOccurrences(of: "map-a", with: "map-b")
            http.stub(pathSuffix: "/mappings", json: mappingResponse([mappingRecord, other]))
            http.stub(pathSuffix: "/mappings", json: mappingResponse([mappingRecord, other]))
            http.stub(pathSuffix: "/mappings", json: mappingResponse([other]))
            http.stub(pathSuffix: "/map-a", json: "{}", status: 503)
            let records = try await service.mappingsForManagement(mapping().content, expectedConnectionID: connection)
            try await service.deleteManagedMapping(XCTUnwrap(records.first), expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), [
                "/api/external/mappings", "/api/external/mappings/map-a", "/api/external/mappings"
            ])
        }
    }

    func testStaleRecordAndOwnershipRejectionCannotDelete() async throws {
        for stale in [false, true] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/mappings", json: mappingResponse([mappingRecord]))
                http.stub(pathSuffix: "/mappings", json: mappingResponse([
                    stale ? mappingRecord.replacingOccurrences(of: "tt0137523", with: "tt9999999") : mappingRecord
                ]))
                http.stub(pathSuffix: "/map-a", json: "{}", status: 403)
                let records = try await service.mappingsForManagement(mapping().content, expectedConnectionID: connection)
                do {
                    try await service.deleteManagedMapping(XCTUnwrap(records.first), expectedConnectionID: connection)
                    XCTFail("Stale or unauthorized deletion succeeded")
                } catch {
                    if stale { XCTAssertEqual(error as? AppError, .conflict) }
                    else { XCTAssertEqual(error as? PublicMetaDB.Failure, .blocked) }
                }
                XCTAssertEqual(http.sentPaths.contains("/api/external/mappings/map-a"), !stale)
            }
        }
    }

    func testProfileChangeInvalidatesReviewedMappingBeforeAnyRequest() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/mappings", json: mappingResponse([]))
            http.stub(pathSuffix: "/lookup", json: noMappingMatches)
            let review = try await service.reviewMapping(mapping(), expectedConnectionID: connection)
            service.selectProfile(namespace: "different-profile")
            let count = http.sent.count
            do { try await service.submitManagedMapping(review); XCTFail("Old review used a new profile") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
        }
    }
}

private struct MappingCredentials: PublicMetaDBCredentialStoring {
    func load(namespace: String?) -> PublicMetaDBCredentials? { nil }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {}
    func clear(namespace: String?) throws {}
}
