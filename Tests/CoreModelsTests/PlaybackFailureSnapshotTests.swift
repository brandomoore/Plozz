import Foundation
import XCTest
@testable import CoreModels

final class PlaybackFailureSnapshotTests: XCTestCase {
    #if !DEBUG
    func testReleaseRetainsExportableFailureEvidenceWithoutEnablingRawTextLogs() async throws {
        XCTAssertEqual(HandoffDiagnostics.persistentPlaybackLogText(), "")
        let journal = PlaybackDiagnosticJournal(url: try location())
        journal.record(.failed, session: UUID(), attempt: UUID(), facts: .init(provider: .plex),
                       failure: .init(.serverHTTP(503)))
        let exported = await journal.export(scope: DiagnosticExportScope())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as? [String: Any])
        XCTAssertEqual((body["failureSnapshots"] as? [Any])?.count, 1)
    }
    #endif

    func testFailedAttemptSurvivesRetryJournalChurnRestartAndLateNativeEvidence() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        let session = UUID(), failureAttempt = UUID(), retry = UUID()
        let facts = PlaybackDiagnosticJournal.Facts(provider: .jellyfin, engine: .plozzigen)
        journal.record(.requested, session: session, attempt: failureAttempt, facts: facts)
        journal.record(.loading, session: session, attempt: failureAttempt, facts: facts)
        journal.record(.failed, session: session, attempt: failureAttempt, facts: facts,
                       failure: .init(.serverHTTP(503)),
                       pipeline: .init(.init(droppedFrameCount: 7, bufferedSecondsAhead: 0.1)))
        journal.record(.firstFrame, session: session, attempt: retry, facts: facts)
        journal.record(.failureEvidence, session: session, attempt: failureAttempt, facts: facts,
                       evidence: .init(nativeCapture: .captured, nativeErrors: [.init(domain: NSURLErrorDomain, code: -1001)]))
        await journal.flush()
        for _ in 0..<4 {
            for _ in 0..<200 { journal.record(.phaseChanged, session: session, attempt: retry, facts: facts, phase: .playing) }
            await journal.flush()
        }
        let restored = PlaybackDiagnosticJournal(url: url)
        let value = try await contents(restored)
        XCTAssertFalse(value.entries.contains { $0.attempt == failureAttempt })
        let snapshot = try XCTUnwrap(value.failureSnapshots?.first)
        XCTAssertEqual(snapshot.attempt, failureAttempt)
        XCTAssertEqual(snapshot.entries.map(\.event), [.requested, .loading, .failed, .failureEvidence])
        XCTAssertEqual(snapshot.entries.first { $0.event == .failed }?.pipeline?.droppedFrames, 7)
        XCTAssertEqual(snapshot.entries.last?.evidence?.nativeErrors.first?.code, -1001)
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.attempt == failureAttempt && $0.session == session })
    }

    func testRetainsOnlyThreeAttemptsAndKeepsFailureWhenContextIsTrimmed() async throws {
        let journal = PlaybackDiagnosticJournal(url: try location())
        let session = UUID()
        let attempts = (0..<5).map { _ in UUID() }
        for attempt in attempts {
            journal.record(.startupTimedOut, session: session, attempt: attempt, facts: .init(provider: nil))
            journal.record(.failed, session: session, attempt: attempt, facts: .init(provider: nil),
                           failure: .init(.startupTimedOut))
            for _ in 0..<100 {
                journal.record(.phaseChanged, session: session, attempt: attempt, facts: .init(provider: nil), phase: .failed)
            }
            await journal.flush()
        }
        let value = try await contents(journal)
        let snapshots = try XCTUnwrap(value.failureSnapshots)
        XCTAssertEqual(snapshots.map(\.attempt), Array(attempts.suffix(3)))
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.entries.count, 64)
            XCTAssertTrue(snapshot.entries.contains { $0.event == .failed })
            XCTAssertTrue(snapshot.entries.contains { $0.event == .startupTimedOut })
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(snapshot).count, 64 * 1_024)
        }
    }

    func testSnapshotBytesAreBoundedIndependentlyFromRecentEvents() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        let evidence = PlaybackFailureEvidence(
            nativeCapture: .captured,
            nativeErrors: (0..<8).map { .init(domain: NSURLErrorDomain, code: -1000 - $0) }
        )
        for _ in 0..<3 {
            let session = UUID(), attempt = UUID()
            journal.record(.failed, session: session, attempt: attempt, facts: .init(provider: .plex))
            for _ in 0..<100 {
                journal.record(.failureEvidence, session: session, attempt: attempt,
                               facts: .init(provider: .plex), evidence: evidence)
            }
            await journal.flush()
        }
        let value = try await contents(journal)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 384 * 1_024)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(value.entries).count, 128 * 1_024)
        for snapshot in value.failureSnapshots ?? [] {
            XCTAssertLessThanOrEqual(snapshot.entries.count, 64)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(snapshot).count, 64 * 1_024)
            XCTAssertTrue(snapshot.entries.contains { $0.event == .failed })
        }
        let restored = try await contents(PlaybackDiagnosticJournal(url: url))
        XCTAssertEqual(restored.failureSnapshots?.count, 3)
    }

    func testLegacyJournalWithoutSnapshotsOrPipelineStillRestores() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        journal.record(.loading, session: UUID(), attempt: UUID(), facts: .init(provider: .emby))
        await journal.flush()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "failureSnapshots")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let restored = PlaybackDiagnosticJournal(url: url)
        let value = try await contents(restored)
        XCTAssertEqual(value.entries.map(\.event), [.loading])
        XCTAssertNil(value.failureSnapshots)
    }

    func testExpiryAlsoRemovesFrozenFailureEvidence() async throws {
        let url = try location()
        let now = Date()
        let journal = PlaybackDiagnosticJournal(url: url, clock: { now })
        journal.record(.failed, session: UUID(), attempt: UUID(), facts: .init(provider: nil))
        await journal.flush()
        let restored = PlaybackDiagnosticJournal(url: url, clock: { now.addingTimeInterval(48 * 3_600 + 1) })
        let value = try await contents(restored)
        XCTAssertTrue(value.entries.isEmpty)
        XCTAssertTrue(value.failureSnapshots?.isEmpty == true)
    }

    func testExportUsesOneSubmissionScopeAndExcludesPrivateSourceText() async throws {
        let journal = PlaybackDiagnosticJournal(url: try location())
        let session = UUID(), attempt = UUID()
        let request = PlaybackRequest(
            item: .init(id: "PRIVATE-ID", title: "PRIVATE-TITLE", kind: .movie),
            streamURL: try XCTUnwrap(URL(string: "https://PRIVATE-HOST/path?token=SECRET")),
            sourceMetadata: .init(container: "mkv", video: .init(codec: "hevc"))
        )
        journal.record(.failed, session: session, attempt: attempt,
                       facts: .init(provider: .plex, request: request),
                       failure: .init(.serverRefusal("PRIVATE-ERROR-SECRET", reason: .unspecified)),
                       pipeline: .init(.init(bufferedSecondsAhead: 2, audioPipelineDescription: "PRIVATE-AUDIO-SECRET")))
        let scope = DiagnosticExportScope()
        let export = await journal.export(scope: scope)
        let data = try JSONEncoder().encode(export)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["PRIVATE", "SECRET", "https", session.uuidString, attempt.uuidString, "capturedAt", "timestamp"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshot = try XCTUnwrap((object["failureSnapshots"] as? [[String: Any]])?.first)
        let entry = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(snapshot["attempt"] as? String, entry["attempt"] as? String)
        XCTAssertEqual(snapshot["session"] as? String, scope.alias(for: session.uuidString))
        let another = await journal.export(scope: DiagnosticExportScope())
        XCTAssertNotEqual(String(decoding: try JSONEncoder().encode(another), as: UTF8.self), text)
    }

    func testRestoredSnapshotCannotBypassValidation() async throws {
        for corruptKey in ["build", "pipeline"] {
            let url = try location()
            let journal = PlaybackDiagnosticJournal(url: url)
            journal.record(.failed, session: UUID(), attempt: UUID(), facts: .init(provider: nil))
            await journal.flush()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var snapshots = try XCTUnwrap(object["failureSnapshots"] as? [[String: Any]])
            var entries = try XCTUnwrap(snapshots[0]["entries"] as? [[String: Any]])
            entries[0][corruptKey] = corruptKey == "build" ? "PRIVATE-SECRET" : ["bufferedSeconds": -1]
            snapshots[0]["entries"] = entries
            object["failureSnapshots"] = snapshots
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let restored = PlaybackDiagnosticJournal(url: url)
            let export = await restored.export(scope: DiagnosticExportScope())
            let text = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
            XCTAssertTrue(text.contains("invalidJournal"))
            XCTAssertFalse(text.contains("PRIVATE"))
        }
    }

    func testPipelineNormalizesInvalidNumbersAndExcludesFreeText() throws {
        let snapshot = try XCTUnwrap(PlaybackPipelineSnapshot(.init(
            droppedFrameCount: -1, observedFps: .nan, observedBitrate: .infinity,
            bufferedSecondsAhead: -1, audioPipelineDescription: "private token",
            sessionCache: .init(residentBytes: -1, effectiveBudgetBytes: Int64.max)
        )))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertNil(snapshot.droppedFrames)
        XCTAssertNil(snapshot.framesPerSecond)
        XCTAssertNil(snapshot.bitrate)
        XCTAssertNil(snapshot.bufferedSeconds)
        XCTAssertNil(snapshot.cacheBytes)
        XCTAssertNil(snapshot.cacheBudgetBytes)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("private"))
    }

    private func contents(_ journal: PlaybackDiagnosticJournal) async throws -> PlaybackDiagnosticJournal.Journal {
        let report = await journal.report()
        let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
        return try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8))
    }

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FailureSnapshots-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("playback.json")
    }
}
