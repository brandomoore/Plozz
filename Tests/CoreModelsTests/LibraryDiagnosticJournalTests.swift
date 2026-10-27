import Foundation
import XCTest
@testable import CoreModels

final class LibraryDiagnosticJournalTests: XCTestCase {
    func testLibraryDecodeAndPagingEvidenceSurvivesWithoutErrorDescriptionsOrPrivateKeys() throws {
        let journal = LibraryDiagnosticJournal()
        journal.record(diagnostic())
        let export = journal.export(scope: DiagnosticExportScope())
        let body = try object(export)
        let entry = try XCTUnwrap((body["entries"] as? [[String: Any]])?.first)
        let facts = try XCTUnwrap(entry["facts"] as? [String: Any])
        let failure = try XCTUnwrap((facts["failures"] as? [[String: Any]])?.first)
        let response = try XCTUnwrap((failure["responses"] as? [[String: Any]])?.first)
        let page = try XCTUnwrap((failure["paging"] as? [[String: Any]])?.first)
        XCTAssertEqual(facts["provider"] as? String, "plex")
        XCTAssertEqual(facts["operation"] as? String, "libraryBrowse")
        XCTAssertEqual(failure["section"] as? String, "collections")
        XCTAssertEqual(failure["reason"] as? String, "unknown")
        XCTAssertEqual(response["route"] as? String, "collectionCandidates")
        XCTAssertEqual(response["reason"] as? String, "wrongType")
        XCTAssertEqual(response["expected"] as? String, "array")
        XCTAssertEqual(response["path"] as? String, "MediaContainer.<field>")
        XCTAssertEqual(page["reason"] as? String, "emptyID")
        XCTAssertEqual(page["rows"] as? Int, 3)
        XCTAssertEqual((failure["transport"] as? [[String: Any]])?.first?["urlErrorCode"] as? Int, -1001)
        XCTAssertEqual((failure["http"] as? [[String: Any]])?.first?["httpStatus"] as? Int, 502)
        let text = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        for value in ["private", "PRIVATE", "secret", "192.168", "timestamp"] {
            XCTAssertFalse(text.contains(value), value)
        }
        let next = try object(journal.export(scope: DiagnosticExportScope()))
        let nextRecord = (next["entries"] as? [[String: Any]])?.first?["record"] as? String
        XCTAssertNotEqual(entry["record"] as? String, nextRecord)
    }

    func testEmptyAndCancelledFailuresDoNotBecomeFailureRecords() async throws {
        let journal = LibraryDiagnosticJournal()
        journal.record(.init(provider: .jellyfin, failures: []))
        journal.record(.init(provider: .jellyfin, failures: [
            .init(section: .continueWatching, error: .cancelled)
        ]))
        let failure = diagnostic()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            journal.record(failure)
        }
        await task.value
        let body = try object(journal.export(scope: DiagnosticExportScope()))
        XCTAssertEqual((body["entries"] as? [Any])?.count, 0)
    }

    func testLibraryHistoryAndPerRecordFailuresAreBoundedWithExplicitOmissions() throws {
        let journal = LibraryDiagnosticJournal()
        for _ in 0..<40 { journal.record(diagnostic()) }
        let failures = Array(repeating: diagnostic().failures[0], count: 12)
        journal.record(.init(provider: .plex, failures: failures))
        let body = try object(journal.export(scope: DiagnosticExportScope()))
        let entries = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 32)
        XCTAssertEqual(body["dropped"] as? Int, 9)
        let facts = try XCTUnwrap(entries.last?["facts"] as? [String: Any])
        XCTAssertEqual((facts["failures"] as? [Any])?.count, 8)
        XCTAssertEqual(facts["omittedFailures"] as? Int, 4)
    }

    func testSharedTechnicalBufferExpiresOldEvidenceAndPreservesNewestValues() {
        let clock = DiagnosticBufferClock()
        let buffer = DiagnosticRecordBuffer<Int>(clock: { clock.read() })
        for value in 0..<36 { buffer.append(value) }
        XCTAssertEqual(buffer.snapshot().entries.map(\.value), Array(4..<36))
        XCTAssertEqual(buffer.snapshot().dropped, 4)
        clock.advance(48 * 3_600 + 1)
        XCTAssertTrue(buffer.snapshot().entries.isEmpty)
        XCTAssertEqual(buffer.snapshot().dropped, 36)
        buffer.append(99)
        XCTAssertEqual(buffer.snapshot().entries.map(\.value), [99])
        XCTAssertEqual(buffer.snapshot().dropped, 36)
    }

    private func diagnostic() -> LibraryLoadDiagnostic {
        let error = DecodingError.typeMismatch([String].self, .init(
            codingPath: [DiagnosticFieldKey("MediaContainer"), DiagnosticFieldKey("private-user-key")],
            debugDescription: "PRIVATE https://private.test?token=secret"
        ))
        return .init(provider: .plex, operation: .libraryBrowse, failures: [
            .init(
                section: .collections, error: .unknown("PRIVATE 192.168.1.5 private-account secret"),
                responses: [.init(route: .collectionCandidates, httpStatus: 200, bytes: 512,
                                  payload: .object, error: error)],
                paging: [.init(stage: .collectionCandidates, reason: .emptyID, start: 0, rows: 3, total: 4)],
                transport: [.init(route: .collectionCandidates, urlErrorCode: -1001)],
                http: [.init(route: .collectionCandidates, httpStatus: 502)]
            )
        ])
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}

private struct DiagnosticFieldKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private final class DiagnosticBufferClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func read() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
