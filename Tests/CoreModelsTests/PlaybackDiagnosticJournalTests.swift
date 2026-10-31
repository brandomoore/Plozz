import Foundation
import XCTest
@testable import CoreModels

final class PlaybackDiagnosticJournalTests: XCTestCase {
    func testServerDecisionSurvivesPersistenceAndOptionalExportWithoutPrivateText() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        var request = PlaybackRequest(
            item: .init(id: "private-item", title: "private-title", kind: .movie),
            streamURL: URL(string: "https://private.test/master.m3u8?token=private-token")!
        )
        request.serverDecision = .init(
            sourceBitrate: 82_000_000, clientMaxBitrate: nil,
            supportsDirectPlay: false, supportsDirectStream: false, supportsTranscoding: true,
            subtitleBurnIn: true,
            transcodeReasons: ["SubtitleCodecNotSupported", "private-token", "SubtitleCodecNotSupported"]
        )
        journal.record(.resolved, session: UUID(), attempt: UUID(),
                       facts: .init(provider: .jellyfin, request: request))
        await journal.flush()
        let restored = PlaybackDiagnosticJournal(url: url)
        let report = await restored.report()
        let evidence = try XCTUnwrap(decode(report).entries.first?.facts.serverDecision)
        XCTAssertEqual(evidence, request.serverDecision)
        XCTAssertEqual(evidence.transcodeReasons, ["SubtitleCodecNotSupported", "Other"])
        let export = await restored.export(scope: DiagnosticExportScope())
        let text = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        XCTAssertTrue(text.contains("\"sourceBitrate\":82000000"))
        XCTAssertTrue(text.contains("SubtitleCodecNotSupported"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("https"))
    }

    func testServerDecisionRejectsUntrustedRestoredReasonsAndBoundsInput() throws {
        let bounded = PlaybackServerDecision(
            sourceBitrate: -1, clientMaxBitrate: Int.max,
            supportsDirectPlay: nil, supportsDirectStream: nil, supportsTranscoding: nil,
            subtitleBurnIn: false, transcodeReasons: Array(repeating: "private-token", count: 100)
        )
        XCTAssertNil(bounded.sourceBitrate)
        XCTAssertNil(bounded.clientMaxBitrate)
        XCTAssertEqual(bounded.transcodeReasons, ["Other"])
        XCTAssertTrue(bounded.isValid)
        let untrusted = try JSONDecoder().decode(PlaybackServerDecision.self, from: Data(
            #"{"subtitleBurnIn":false,"transcodeReasons":["private-token"]}"#.utf8
        ))
        XCTAssertFalse(untrusted.isValid)
    }

    func testPersistsCorrelatedLifecycleWithoutPrivateSourceData() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        let session = UUID(), attempt = UUID()
        var request = PlaybackRequest(
            item: .init(id: "private-item", title: "Private title", kind: .movie),
            streamURL: URL(string: "https://private-server.test/video.m3u8?api_key=private-token")!,
            sourceMetadata: .init(container: "mkv", video: .init(codec: "hevc"), audio: .init(codec: "aac"))
        )
        request.streamingSessionID = "private-session"
        request.serverName = "Private server"
        request.streamingOptions = .init(
            quality: try .custom(maximumHeight: 720, bitrateKbps: 2_345), codec: .preferHEVC
        )
        let facts = PlaybackDiagnosticJournal.Facts(provider: .plex, engine: .plozzigen, request: request)
        for event: PlaybackDiagnosticJournal.Event in [.requested, .loading, .firstFrame, .stopped] {
            journal.record(event, session: session, attempt: attempt, facts: facts, elapsed: 1.25)
        }
        journal.record(.failed, session: session, attempt: attempt, facts: facts,
                       failure: .init(.serverRefusal("private-token", reason: .unspecified)))
        await journal.flush()
        let restored = PlaybackDiagnosticJournal(url: url)
        let report = await restored.report()
        let entries = try decode(report).entries
        XCTAssertEqual(entries.count, 5)
        XCTAssertTrue(entries.allSatisfy { $0.session == session && $0.attempt == attempt })
        XCTAssertEqual(entries.first?.elapsedMilliseconds, 1_250)
        XCTAssertEqual(entries.first?.facts.source, .serverHLS)
        XCTAssertEqual(entries.first?.facts.sourceVideo, "hevc")
        XCTAssertEqual(entries.first?.facts.quality, request.streamingOptions?.quality)
        XCTAssertEqual(entries.first?.facts.codecPreference, .preferHEVC)
        XCTAssertEqual(entries.last?.failure?.code, .serverRefusal)
        for privateValue in ["private", "Private", "https", "api_key"] {
            XCTAssertFalse(report.contains(privateValue), privateValue)
        }
        XCTAssertTrue(report.contains("storage=ok"))
    }

    func testNativeFailureEvidenceSurvivesRestartWithoutGuessingTheCause() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        let evidence = PlaybackFailureEvidence(
            route: .nativeHLS, firstFrameReady: false, nativeCapture: .captured,
            nativeErrors: [.init(domain: "CoreMediaErrorDomain", code: -12889)],
            nativeLogErrors: [.init(domain: NSURLErrorDomain, code: -1001)],
            nativeStatus: .failed,
            nativeAccess: .init(
                requests: 3, bytesTransferred: 123_456, stalls: 0, transferMilliseconds: 500,
                startupMilliseconds: nil, observedBitrate: 2_000_000, indicatedBitrate: 4_000_000
            )
        )
        journal.record(
            .failureEvidence, session: UUID(), attempt: UUID(),
            facts: .init(provider: .jellyfin, engine: .native),
            failure: .init(.playback(.init(kind: .unknown, domain: .coreMedia, code: -12889))),
            stage: .opening, evidence: evidence
        )
        await journal.flush()
        let restored = PlaybackDiagnosticJournal(url: url)
        let report = await restored.report()
        let entry = try XCTUnwrap(decode(report).entries.first)
        XCTAssertEqual(entry.stage, .opening)
        XCTAssertEqual(entry.failure?.kind, .unknown)
        XCTAssertEqual(entry.evidence, evidence)
    }

    func testOlderJournalWithoutOptionalEvidenceAndQualityStillRestores() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        journal.record(.failed, session: UUID(), attempt: UUID(), facts: .init(provider: .jellyfin))
        await journal.flush()
        let restored = PlaybackDiagnosticJournal(url: url)
        let report = await restored.report()
        let entry = try XCTUnwrap(decode(report).entries.first)
        XCTAssertNil(entry.stage)
        XCTAssertNil(entry.evidence)
        XCTAssertNil(entry.facts.quality)
        XCTAssertNil(entry.facts.serverDecision)
    }

    func testInvalidNativeEvidenceIsRejectedAtAdmissionAndRestore() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        let bad = PlaybackFailureEvidence(nativeErrors: [.init(domain: "private domain", code: Int.max)])
        journal.record(
            .failureEvidence, session: UUID(), attempt: UUID(), facts: .init(provider: .jellyfin), evidence: bad
        )
        let rejected = await journal.report()
        XCTAssertTrue(rejected.contains("storage=invalidEvidence"))
        XCTAssertTrue(try decode(rejected).entries.isEmpty)
        let entry = PlaybackDiagnosticJournal.Entry(
            timestamp: Date(), build: "62", session: UUID(), attempt: UUID(), event: .failureEvidence,
            facts: .init(provider: .jellyfin), elapsedMilliseconds: 1, route: nil, failure: nil,
            phase: nil, liveFailure: nil, stopReason: nil, stage: .opening, evidence: bad
        )
        try JSONEncoder().encode(PlaybackDiagnosticJournal.Journal(entries: [entry])).write(to: url)
        let restored = PlaybackDiagnosticJournal(url: url)
        let report = await restored.report()
        XCTAssertTrue(report.contains("storage=invalidJournal"))
        XCTAssertTrue(try decode(report).entries.isEmpty)
    }

    func testUnknownNativeCountersStayAbsentRatherThanBecomeSuccess() {
        let counters = PlaybackFailureEvidence.NativeAccess(
            requests: -1, bytesTransferred: Int.max, stalls: nil, transferMilliseconds: -1,
            startupMilliseconds: -1, observedBitrate: -1, indicatedBitrate: 0
        )
        XCTAssertTrue(counters.isValid)
        XCTAssertNil(counters.requests)
        XCTAssertNil(counters.bytesTransferred)
        XCTAssertNil(counters.startupMilliseconds)
        XCTAssertEqual(counters.indicatedBitrate, 0)
    }

    func testUntrustedFormatNamesAndInvalidTimingAreNotStored() async throws {
        let journal = PlaybackDiagnosticJournal(url: try location())
        let request = PlaybackRequest(
            item: .init(id: "1", title: "Title", kind: .movie),
            streamURL: URL(string: "https://example.test/file")!,
            sourceMetadata: .init(
                container: "https://private.test", video: .init(codec: "private-token"),
                audio: .init(codec: String(repeating: "aac", count: 100))
            )
        )
        for elapsed in [Double.nan, .infinity, -1, Double.greatestFiniteMagnitude] {
            journal.record(.failed, session: UUID(), attempt: UUID(),
                           facts: .init(provider: .emby, request: request), elapsed: elapsed)
        }
        await journal.flush()
        let report = await journal.report()
        let entries = try decode(report).entries
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.allSatisfy {
            $0.facts.sourceContainer == nil && $0.facts.sourceVideo == nil && $0.facts.sourceAudio == nil
        })
        XCTAssertEqual(entries.compactMap(\.elapsedMilliseconds), [172_800_000])
        XCTAssertFalse(report.contains("private"))
    }

    func testBoundedConcurrentAdmissionAndCompletedPersistence() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            journal.record(.loading, session: UUID(), attempt: UUID(), facts: .init(provider: .plex))
        }
        await journal.flush()
        let value = try decode(await journal.report())
        XCTAssertEqual(value.entries.count, PlaybackDiagnosticJournal.maximumEntries)
        XCTAssertEqual(value.discarded + value.entries.count, 2_000)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, PlaybackDiagnosticJournal.maximumBytes)
    }

    func testExpiresEvidenceAcrossRestartAndExport() async throws {
        let url = try location()
        let clock = JournalTestClock()
        let first = PlaybackDiagnosticJournal(url: url, clock: { clock.now() })
        first.record(.failed, session: UUID(), attempt: UUID(), facts: .init(provider: .jellyfin))
        await first.flush()
        clock.advance(PlaybackDiagnosticJournal.retention + 1)
        let restored = PlaybackDiagnosticJournal(url: url, clock: { clock.now() })
        let value = try decode(await restored.report())
        XCTAssertTrue(value.entries.isEmpty)
        XCTAssertEqual(value.discarded, 1)
        restored.record(.loading, session: UUID(), attempt: UUID(), facts: .init(provider: .plex))
        await restored.flush()
        clock.advance(PlaybackDiagnosticJournal.retention + 1)
        let expired = try decode(await restored.report())
        XCTAssertTrue(expired.entries.isEmpty)
    }

    func testMalformedAndOversizedFilesAreRejectedWithoutExportingContents() async throws {
        for data in [Data("private corrupt content".utf8),
                     Data(repeating: 65, count: PlaybackDiagnosticJournal.maximumBytes + 1)] {
            let url = try location()
            try data.write(to: url)
            let journal = PlaybackDiagnosticJournal(url: url)
            let report = await journal.report()
            XCTAssertFalse(report.contains("private"))
            XCTAssertFalse(report.contains("storage=ok"))
            XCTAssertTrue(try decode(report).entries.isEmpty)
        }
    }

    func testStorageFailureIsExplicitAndDoesNotLoseInMemoryEvidence() async throws {
        let directory = try location()
        try Data("not a directory".utf8).write(to: directory)
        let journal = PlaybackDiagnosticJournal(url: directory.appendingPathComponent("journal.json"))
        journal.record(.failed, session: UUID(), attempt: UUID(), facts: .init(provider: .plex))
        await journal.flush()
        let report = await journal.report()
        XCTAssertTrue(report.contains("storage=writeFailed"))
        XCTAssertEqual(try decode(report).entries.count, 1)
    }

    func testFlushCancelsDelayedWriteRatherThanRecreatingRemovedDirectory() async throws {
        let url = try location()
        let journal = PlaybackDiagnosticJournal(url: url)
        journal.record(.stopped, session: UUID(), attempt: UUID(), facts: .init(provider: .plex))
        await journal.flush()
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("playback.json")
    }

    private func decode(_ report: String) throws -> PlaybackDiagnosticJournal.Journal {
        let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
        return try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8))
    }
}

private final class JournalTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
