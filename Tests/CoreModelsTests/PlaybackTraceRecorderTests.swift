import XCTest
@testable import CoreModels

final class PlaybackTraceRecorderTests: XCTestCase {
    func testAppendsWithoutReplacingFileAndRestoresAcrossRecorderRecreation() throws {
        let directory = try location()
        var recorder: PlaybackTraceRecorder? = make(directory)
        recorder?.append("first")
        XCTAssertTrue(try XCTUnwrap(recorder?.snapshot()).contains("first"))
        let path = directory.appendingPathComponent("playback-trace.log")
        let inode = try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
        recorder?.append("second")
        XCTAssertTrue(try XCTUnwrap(recorder?.snapshot()).contains("second"))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber, inode
        )
        recorder = nil
        let restored = make(directory)
        restored.append("third")
        let text = restored.snapshot()
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "first")?.lowerBound),
                          try XCTUnwrap(text.range(of: "second")?.lowerBound))
        XCTAssertTrue(text.contains("third"))
    }

    func testRotationRetainsFourBoundedSegmentsInChronologicalOrder() throws {
        let directory = try location()
        let recorder = make(directory, segmentBytes: 128)
        for index in 0..<12 {
            recorder.append("entry-\(index) " + String(repeating: "x", count: 70))
            _ = recorder.snapshot()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 4)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 128) }
        let text = recorder.snapshot()
        XCTAssertFalse(text.contains("entry-7 "))
        var previous = text.startIndex
        for index in 8..<12 {
            let range = try XCTUnwrap(text.range(of: "entry-\(index) "))
            XCTAssertGreaterThanOrEqual(range.lowerBound, previous)
            previous = range.upperBound
        }
    }

    func testFailureSnapshotStopsAtFailureAndSurvivesSuccessfulRetryAndRotation() throws {
        let directory = try location()
        let recorder = make(directory, segmentBytes: 256)
        recorder.append("first-attempt-start")
        recorder.append("failed-attempt", failure: true)
        recorder.append("successful-retry")
        _ = recorder.snapshot()
        let failure = directory.appendingPathComponent("playback-failure.log")
        let captured = try Data(contentsOf: failure)
        XCTAssertTrue(String(decoding: captured, as: UTF8.self).contains("first-attempt-start"))
        XCTAssertTrue(String(decoding: captured, as: UTF8.self).contains("failed-attempt"))
        XCTAssertFalse(String(decoding: captured, as: UTF8.self).contains("successful-retry"))
        for _ in 0..<30 {
            recorder.append(String(repeating: "p", count: 100))
            _ = recorder.snapshot()
        }
        XCTAssertEqual(try Data(contentsOf: failure), captured)
        XCTAssertFalse(recorder.snapshot().contains("failed-attempt"))
    }

    func testFailureRetentionIsBoundedAndSurvivesReopen() throws {
        let directory = try location()
        for index in 0..<5 {
            let recorder = make(directory, segmentBytes: 128, failureBytes: 128)
            recorder.append("failure-\(index)", failure: true)
            _ = recorder.snapshot()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("playback-failure") }
        XCTAssertEqual(files.count, 3)
        for (index, name) in ["playback-failure.log", "playback-failure.1.log", "playback-failure.2.log"].enumerated() {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(data.count, 128)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("failure-\(4 - index)\n"))
        }
    }

    func testLargeUnicodeRecordIsBoundedValidUTF8AndEndsAtLineBoundary() throws {
        let directory = try location()
        let recorder = make(directory, segmentBytes: 128)
        recorder.append(String(repeating: "\u{1F3AC}", count: 100))
        let text = recorder.snapshot()
        XCTAssertTrue(text.hasSuffix(" [truncated]\n"))
        let data = try Data(contentsOf: directory.appendingPathComponent("playback-trace.log"))
        XCTAssertNotNil(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(data.count, 128)
    }

    func testExportStaysSmallWhileDiskRetainsMoreThanOldLimit() throws {
        let directory = try location()
        let recorder = make(directory)
        for index in 0..<100 {
            recorder.append("row-\(index) " + String(repeating: "x", count: 1_000))
            _ = recorder.snapshot()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("playback-trace.log"))
        XCTAssertGreaterThan(data.count, 64 * 1_024)
        let exported = recorder.snapshot()
        XCTAssertLessThanOrEqual(exported.utf8.count, 64 * 1_024)
        XCTAssertTrue(exported.contains("row-99 "))
        XCTAssertFalse(exported.contains("row-0 "))
        let expected = Set(data.split(separator: 10).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(exported.split(separator: "\n").count > 50)
        XCTAssertTrue(exported.split(separator: "\n").allSatisfy { line in
            expected.contains(String(line))
        })
    }

    func testConcurrentAppendsRemainWholeAndAllAreRetainedWithinBudget() throws {
        let recorder = make(try location())
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            recorder.append("concurrent-\(index)")
        }
        let lines = recorder.snapshot().split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        for index in 0..<100 {
            XCTAssertEqual(lines.filter { $0.hasSuffix("concurrent-\(index)") }.count, 1)
        }
    }

    func testStorageErrorsAreReportedWithoutThrowingOnCaller() throws {
        let root = try location()
        let file = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        let issues = Issues()
        let recorder = PlaybackTraceRecorder(directory: file, report: { issues.append($0) })
        recorder.append("unwritable")
        _ = recorder.snapshot()
        XCTAssertTrue(issues.values.contains(.writeFailed))
        let unavailable = PlaybackTraceRecorder(directory: nil, report: { issues.append($0) })
        unavailable.append("no-location")
        XCTAssertEqual(unavailable.snapshot(), "")
        XCTAssertTrue(issues.values.contains(.locationUnavailable))
    }

    func testOverflowIsReportedAndFailureTakesPriorityOverRoutineNoise() throws {
        let directory = try location()
        let issues = Issues()
        let worker = DispatchQueue(label: "PlaybackTraceTests.blocked")
        let release = DispatchSemaphore(value: 0)
        worker.async { _ = release.wait(timeout: .now() + 10) }
        let recorder = PlaybackTraceRecorder(directory: directory, queue: worker, report: { issues.append($0) })
        for index in 0..<600 { recorder.append("noise-\(index)") }
        recorder.append("failure-after-overflow", failure: true)
        release.signal()
        let text = recorder.snapshot()
        XCTAssertTrue(issues.values.contains(.queueOverflow))
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, 512)
        let failure = try String(contentsOf: directory.appendingPathComponent("playback-failure.log"), encoding: .utf8)
        XCTAssertTrue(failure.hasSuffix("failure-after-overflow\n"))
    }

    func testProductionDiskLimitsUnderSustainedLargeRecords() throws {
        let directory = try location()
        let recorder = make(directory)
        for batch in 0..<40 {
            for index in 0..<10 {
                recorder.append("batch-\(batch)-\(index) " + String(repeating: "x", count: 15_900))
            }
            if batch % 8 == 0 { recorder.append("failure-\(batch)", failure: true) }
            _ = recorder.snapshot()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 7)
        var total = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let isFailure = file.lastPathComponent.hasPrefix("playback-failure")
            XCTAssertLessThanOrEqual(data.count, isFailure ? 512 * 1_024 : 1_024 * 1_024)
            XCTAssertNotNil(String(data: data, encoding: .utf8))
            XCTAssertEqual(data.last, 10)
            total += data.count
        }
        XCTAssertLessThanOrEqual(total, 5_632 * 1_024)
        XCTAssertGreaterThan(total, 4 * 1_024 * 1_024)
    }

    func testTypedFailureBoundaryCapturesOnlyFailureEvents() async throws {
        let recorder = make(try location())
        let journal = PlaybackDiagnosticJournal(url: nil, onFailure: { entry in
            recorder.append(HandoffDiagnostics.playbackFailureLine(entry), failure: true, attempt: entry.attempt)
        })
        let session = UUID(), attempt = UUID()
        let facts = PlaybackDiagnosticJournal.Facts(provider: nil)
        for event: PlaybackDiagnosticJournal.Event in [.requested, .failed, .loaded, .firstFrame] {
            journal.record(event, session: session, attempt: attempt, facts: facts,
                           failure: event == .failed ? .init(.serverHTTP(503)) : nil)
        }
        let text = recorder.snapshot()
        XCTAssertTrue(text.contains("event=failed session=\(session) attempt=\(attempt)"))
        XCTAssertTrue(text.contains("code=serverHTTP"))
        XCTAssertTrue(text.contains("httpStatus=503"))
        XCTAssertFalse(text.contains("loaded"))
        XCTAssertFalse(text.contains("firstFrame"))
    }

    func testTimeoutAndTypedFailureShareOneSnapshotPerAttempt() throws {
        let directory = try location()
        let recorder = make(directory)
        let attempt = UUID()
        recorder.append("startupTimedOut", failure: true, attempt: attempt)
        recorder.append("typedFailure", failure: true, attempt: attempt)
        _ = recorder.snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("playback-failure.1.log").path))
        let text = try String(contentsOf: directory.appendingPathComponent("playback-failure.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("startupTimedOut"))
        XCTAssertTrue(text.contains("typedFailure"))
        recorder.append("retryFailed", failure: true, attempt: UUID())
        _ = recorder.snapshot()
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("playback-failure.1.log"), encoding: .utf8), text
        )
    }

    private func make(
        _ directory: URL, segmentBytes: Int = PlaybackTraceRecorder.segmentBytes,
        failureBytes: Int = PlaybackTraceRecorder.failureBytes
    ) -> PlaybackTraceRecorder {
        PlaybackTraceRecorder(directory: directory, segmentBytes: segmentBytes, failureBytes: failureBytes) {
            XCTFail("Unexpected storage issue: \($0)")
        }
    }

    private func location() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackTraceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private final class Issues: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [PlaybackTraceRecorder.StorageIssue] = []
        func append(_ value: PlaybackTraceRecorder.StorageIssue) { lock.withLock { stored.append(value) } }
        var values: [PlaybackTraceRecorder.StorageIssue] { lock.withLock { stored } }
    }
}
