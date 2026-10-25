import CoreModels
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let watchJSON = #"{"id":"watch-a","tmdb_id":550,"media_type":"movie","watched_at":null,"updated":"2026-10-24T00:00:00Z"}"#
private let resumeJSON = #"{"id":"resume-a","tmdb_id":550,"media_type":"movie","position_ms":20000,"runtime_ms":100000,"updated":"2026-10-24T00:00:00Z"}"#
private let droppedJSON = #"{"id":"drop-a","tmdb_id":550,"media_type":"tv","updated":"2026-10-24T00:00:00Z"}"#
private func historyPage(_ records: [String]) -> String {
    #"{"items":[\#(records.joined(separator: ","))],"total":\#(records.count),"page":1,"perPage":500,"totalPages":\#(records.isEmpty ? 0 : 1)}"#
}
private func decoded<Value: Decodable>(_ json: String, _: Value.Type = Value.self) throws -> Value {
    try PublicMetaDBClient.decoder().decode(Value.self, from: Data(json.utf8))
}

@MainActor
final class PublicMetaDBHistoryManagementTests: XCTestCase {
    private func withService(
        _ body: (PublicMetaDBService, RecordingHTTPClient, UUID) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBHistoryManagementTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: historyPage([]))
        let service = PublicMetaDBService(
            credentials: HistoryCredentials(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        try await body(service, http, XCTUnwrap(service.connectionID))
    }

    func testUnknownDatePlayIsAnExplicitAdditionalPlayWithReadback() async throws {
        try await withService { service, http, connection in
            let existing = watchJSON.replacingOccurrences(of: "watch-a", with: "earlier-watch")
            http.stub(pathSuffix: "/watched", json: historyPage([existing]))
            http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(watchJSON)}"#)
            http.stub(pathSuffix: "/watched", json: historyPage([existing, watchJSON]))
            try await service.addHistoryPlay(.init(tmdbID: 550, mediaType: .movie), at: .unknown, expectedConnectionID: connection)
            let writes = http.sent.filter { $0.body != nil }
            XCTAssertEqual(writes.count, 1)
            XCTAssertTrue(writes[0].json?["watched_at"] is NSNull)
            XCTAssertFalse(writes[0].queryItems.contains(where: { $0.name == "dedupe" }))
            XCTAssertNil(service.playbackConsent)
            XCTAssertNil(service.watchlistSelection)
        }
    }

    func testCreationCannotReuseAnExistingRecordOrAcknowledgeMissingReadback() async throws {
        for after in [historyPage([]), historyPage([watchJSON])] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/watched", json: historyPage([watchJSON]))
                http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(watchJSON)}"#)
                http.stub(pathSuffix: "/watched", json: after)
                do {
                    try await service.addHistoryPlay(.init(tmdbID: 550, mediaType: .movie), at: .unknown, expectedConnectionID: connection)
                    XCTFail("Existing or absent play acknowledged")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            }
        }
    }

    func testUncertainCreationIsNotBlindlyRepeated() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/watched", json: historyPage([]))
            http.stub(pathSuffix: "/watched", json: "{}", status: 503)
            do {
                try await service.addHistoryPlay(.init(tmdbID: 550, mediaType: .movie), at: .unknown, expectedConnectionID: connection)
                XCTFail("Uncertain play acknowledged")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        }
    }

    func testDateEditTargetsExactPlayAndPreservesOtherPlays() async throws {
        try await withService { service, http, connection in
            let record: PublicMetaDB.Record<PublicMetaDB.Watch> = try decoded(watchJSON)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let changed = watchJSON.replacingOccurrences(of: #""watched_at":null"#, with: #""watched_at":"2023-11-14T22:13:20Z""#)
            let other = watchJSON.replacingOccurrences(of: "watch-a", with: "other-play")
            http.stub(pathSuffix: "/watched", json: historyPage([watchJSON, other]))
            http.stub(pathSuffix: "/watched", json: historyPage([changed, other]))
            http.stub(pathSuffix: "/watch-a", json: #"{"success":true,"item":\#(changed)}"#)
            try await service.changeHistoryDate(record, to: .known(date), expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), [
                "/api/external/watched", "/api/external/watched/watch-a", "/api/external/watched"
            ])
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        }
    }

    func testUnchangedDateDoesNotWrite() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/watched", json: historyPage([watchJSON]))
            try await service.changeHistoryDate(try decoded(watchJSON), to: .unknown, expectedConnectionID: connection)
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testConcurrentDateChangeBlocksRemovalAndEdit() async throws {
        try await withService { service, http, connection in
            let record: PublicMetaDB.Record<PublicMetaDB.Watch> = try decoded(watchJSON)
            http.stub(pathSuffix: "/watched", json: historyPage([
                watchJSON.replacingOccurrences(of: "2026-10-24", with: "2026-10-25")
            ]))
            do { try await service.deleteHistoryPlay(record, expectedConnectionID: connection); XCTFail("Stale deletion") }
            catch { XCTAssertEqual(error as? AppError, .conflict) }
            do {
                try await service.changeHistoryDate(record, to: .known(Date()), expectedConnectionID: connection)
                XCTFail("Stale edit")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertFalse(http.sentPaths.contains("/api/external/watched/watch-a"))
        }
    }

    func testUncertainExactDeletionRequiresCompleteAbsenceAndLeavesOtherPlays() async throws {
        try await withService { service, http, connection in
            let other = watchJSON.replacingOccurrences(of: "watch-a", with: "other-play")
            http.stub(pathSuffix: "/watched", json: historyPage([watchJSON, other]))
            http.stub(pathSuffix: "/watched", json: historyPage([other]))
            http.stub(pathSuffix: "/watch-a", json: "{}", status: 503)
            try await service.deleteHistoryPlay(try decoded(watchJSON), expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/watch-a") }.count, 1)
            XCTAssertFalse(http.sentPaths.contains("/api/external/watched/other-play"))
        }
    }

    func testUnfilteredHistoryCannotAuthorizeDeletion() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/watched", json: historyPage([
                watchJSON.replacingOccurrences(of: "550", with: "999")
            ]))
            do { try await service.deleteHistoryPlay(try decoded(watchJSON), expectedConnectionID: connection); XCTFail("Wrong title") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            XCTAssertFalse(http.sentPaths.contains("/api/external/watched/watch-a"))
        }
    }

    func testNewerResumeIsNeverClearedFromAnOldScreen() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/resume", json: historyPage([
                resumeJSON.replacingOccurrences(of: "20000", with: "30000")
            ]))
            do { try await service.clearHistoryResume(try decoded(resumeJSON), expectedConnectionID: connection); XCTFail("Newer resume removed") }
            catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertFalse(http.sentPaths.contains("/api/external/resume/resume-a"))
        }
    }

    func testResumeClearRequiresAbsenceNotReplacementProgress() async throws {
        for replaced in [false, true] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/resume", json: historyPage([resumeJSON]))
                http.stub(pathSuffix: "/resume", json: historyPage(
                    replaced ? [resumeJSON.replacingOccurrences(of: "resume-a", with: "resume-b")] : []
                ))
                http.stub(pathSuffix: "/resume-a", json: #"{"success":true}"#)
                do {
                    try await service.clearHistoryResume(try decoded(resumeJSON), expectedConnectionID: connection)
                    XCTAssertFalse(replaced)
                } catch {
                    XCTAssertTrue(replaced)
                    XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite)
                }
                XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/resume-a") }.count, 1)
            }
        }
    }

    func testUndropUsesObservedTitleAndConfirmsAbsenceWithoutTouchingHistory() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/dropped", json: historyPage([droppedJSON]))
            http.stub(pathSuffix: "/dropped", json: historyPage([]))
            http.stub(pathSuffix: "/550/tv", json: #"{"success":true}"#)
            try await service.restoreDroppedTitle(try decoded(droppedJSON), expectedConnectionID: connection)
            XCTAssertTrue(http.sentPaths.contains("/api/external/dropped/550/tv"))
            XCTAssertFalse(http.sentPaths.contains(where: { $0.contains("/watched") || $0.contains("/resume") }))
        }
    }

    func testStaleConnectionAndImplicitCurrentDateNeverDispatch() async throws {
        try await withService { service, http, connection in
            let count = http.sent.count
            do { try await service.deleteHistoryPlay(try decoded(watchJSON), expectedConnectionID: UUID()); XCTFail("Stale grant") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            do {
                try await service.addHistoryPlay(.init(tmdbID: 550, mediaType: .movie), at: .now, expectedConnectionID: connection)
                XCTFail("Implicit date admitted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testDropShowConfirmsReadbackIncludingALostReplyWithoutWritingHistory() async throws {
        for losesReply in [false, true] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/dropped", json: historyPage([]))
                http.stub(pathSuffix: "/dropped", json: losesReply ? "{}" : #"{"success":true}"#, status: losesReply ? 503 : 200)
                http.stub(pathSuffix: "/dropped", json: historyPage([droppedJSON]))
                try await service.dropTitle(.init(tmdbID: 550, mediaType: .tv), expectedConnectionID: connection)
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
                XCTAssertFalse(http.sentPaths.contains { $0.contains("/watched") || $0.contains("/resume") })
            }
        }
    }

    func testAlreadyDroppedShowDoesNotWriteAgain() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/dropped", json: historyPage([droppedJSON]))
            try await service.dropTitle(.init(tmdbID: 550, mediaType: .tv), expectedConnectionID: connection)
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testDropWithoutIndependentReadbackRemainsUnconfirmed() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/dropped", json: historyPage([]))
            http.stub(pathSuffix: "/dropped", json: #"{"success":true}"#)
            http.stub(pathSuffix: "/dropped", json: historyPage([]))
            do {
                try await service.dropTitle(.init(tmdbID: 550, mediaType: .tv), expectedConnectionID: connection)
                XCTFail("Unconfirmed drop reported success")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        }
    }

    func testDroppingMoviesOrChildrenAndStaleConnectionNeverDispatches() async throws {
        try await withService { service, http, connection in
            let before = http.sent.count
            for content in [
                try PublicMetaDB.Content(tmdbID: 550, mediaType: .movie),
                try .init(tmdbID: 550, mediaType: .tv, season: 1),
                try .init(tmdbID: 550, mediaType: .tv, season: 1, episode: 2)
            ] {
                do {
                    try await service.dropTitle(content, expectedConnectionID: connection)
                    XCTFail("Unsupported drop")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
                do {
                    try await service.client?.drop(content)
                    XCTFail("Unsupported direct drop")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
            }
            do {
                try await service.dropTitle(.init(tmdbID: 550, mediaType: .tv), expectedConnectionID: UUID())
                XCTFail("Stale drop")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, before)
        }
    }

    func testMultiplePlayDeletionPreservesUnselectedAndNewerPlays() async throws {
        try await withService { service, http, connection in
            let second = watchJSON.replacingOccurrences(of: "watch-a", with: "watch-b")
            let newer = watchJSON.replacingOccurrences(of: "watch-a", with: "newer-play")
            for records in [
                [watchJSON, second, newer], [watchJSON, second, newer],
                [second, newer], [second, newer], [newer]
            ] {
                http.stub(pathSuffix: "/watched", json: historyPage(records))
            }
            http.stub(pathSuffix: "/watch-a", json: #"{"success":true}"#)
            http.stub(pathSuffix: "/watch-b", json: #"{"success":true}"#)
            try await service.deleteHistoryPlays(
                [try decoded(watchJSON), try decoded(second)], expectedConnectionID: connection
            )
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/watch-a") || $0.hasSuffix("/watch-b") }, [
                "/api/external/watched/watch-a", "/api/external/watched/watch-b"
            ])
            XCTAssertFalse(http.sentPaths.contains("/api/external/watched/newer-play"))
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
            XCTAssertNil(service.playbackConsent)
        }
    }

    func testMultipleDeletionChecksEverySelectedPlayBeforeStarting() async throws {
        try await withService { service, http, connection in
            let second = watchJSON.replacingOccurrences(of: "watch-a", with: "watch-b")
            let changed = second.replacingOccurrences(of: "2026-10-24", with: "2026-10-25")
            http.stub(pathSuffix: "/watched", json: historyPage([watchJSON, changed]))
            do {
                try await service.deleteHistoryPlays(
                    [try decoded(watchJSON), try decoded(second)], expectedConnectionID: connection
                )
                XCTFail("Stale later record should block the whole selection")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertFalse(http.sentPaths.contains(where: { $0.contains("/watched/") }))
        }
    }

    func testMultipleDeletionStopsAndReportsPartialConfirmationWithoutRetry() async throws {
        try await withService { service, http, connection in
            let second = watchJSON.replacingOccurrences(of: "watch-a", with: "watch-b")
            let third = watchJSON.replacingOccurrences(of: "watch-a", with: "watch-c")
            for records in [
                [watchJSON, second, third], [watchJSON, second, third],
                [second, third], [second, third], [second, third]
            ] {
                http.stub(pathSuffix: "/watched", json: historyPage(records))
            }
            http.stub(pathSuffix: "/watch-a", json: #"{"success":true}"#)
            http.stub(pathSuffix: "/watch-b", json: "{}", status: 503)
            do {
                try await service.deleteHistoryPlays(
                    [try decoded(watchJSON), try decoded(second), try decoded(third)], expectedConnectionID: connection
                )
                XCTFail("Unconfirmed second deletion should stop the selection")
            } catch {
                let failure = try XCTUnwrap(error as? PublicMetaDB.HistoryDeletionFailure)
                XCTAssertEqual(failure.confirmedIDs, ["watch-a"])
                XCTAssertEqual(failure.stoppedRecordID, "watch-b")
                XCTAssertEqual(failure.remainingIDs, ["watch-c"])
                XCTAssertEqual(failure.cause as? PublicMetaDB.Failure, .uncertainWrite)
            }
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/watch-b") }.count, 1)
            XCTAssertFalse(http.sentPaths.contains("/api/external/watched/watch-c"))
        }
    }

    func testMultipleDeletionRejectsEmptyDuplicateAndOversizedSelectionsBeforeIO() async throws {
        try await withService { service, http, connection in
            let record: PublicMetaDB.Record<PublicMetaDB.Watch> = try decoded(watchJSON)
            let large: [PublicMetaDB.Record<PublicMetaDB.Watch>] = try (0..<51).map {
                try decoded(watchJSON.replacingOccurrences(of: "watch-a", with: "watch-\($0)"))
            }
            let count = http.sent.count
            for selection in [[], [record, record], large] {
                do {
                    try await service.deleteHistoryPlays(selection, expectedConnectionID: connection)
                    XCTFail("Invalid selection")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
            }
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testFiftyPlaySelectionIsAdmittedForFreshPreflight() async throws {
        try await withService { service, http, connection in
            let records: [PublicMetaDB.Record<PublicMetaDB.Watch>] = try (0..<50).map {
                try decoded(watchJSON.replacingOccurrences(of: "watch-a", with: "watch-\($0)"))
            }
            http.stub(pathSuffix: "/watched", json: historyPage([]))
            do {
                try await service.deleteHistoryPlays(records, expectedConnectionID: connection)
                XCTFail("Missing observed records should fail preflight")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertEqual(http.sentPaths.suffix(1), ["/api/external/watched"])
            XCTAssertFalse(http.sentPaths.contains(where: { $0.contains("/watched/") }))
        }
    }

    func testCancelledMultipleDeletionNeverStartsAndStaleConnectionDoesNotDispatch() async throws {
        try await withService { service, http, connection in
            let record: PublicMetaDB.Record<PublicMetaDB.Watch> = try decoded(watchJSON)
            let count = http.sent.count
            let operation = Task {
                try await service.deleteHistoryPlays([record], expectedConnectionID: connection)
            }
            operation.cancel()
            do { try await operation.value; XCTFail("Cancelled removal succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            do {
                try await service.deleteHistoryPlays([record], expectedConnectionID: UUID())
                XCTFail("Stale connection admitted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
        }
    }
}

private final class HistoryCredentials: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: PublicMetaDBCredentials?
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { saved } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws { lock.withLock { saved = credentials } }
    func clear(namespace: String?) throws { lock.withLock { saved = nil } }
}
