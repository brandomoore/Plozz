import Foundation
import XCTest
@testable import CoreModels

final class IOTimingDiagnosticsTests: XCTestCase {
    private func record() -> IOTimingDiagnostics.Record {
        IOTimingDiagnostics.Record(
            label: .homeHeroWrite, startUnix: 1_800_000_000,
            start: 2_000_000_000, duration: 12_500_000,
            mainThread: true, succeeded: true,
            metrics: .init(items: 6, bytes: 4096)
        )
    }

    func testLineContainsOnlyFixedLabelAndNumericMeasurements() {
        XCTAssertEqual(
            record().line(dropped: 3),
            "PLZIO label=home.hero.write startUnix=1800000000.000 startUptimeMs=2000.000 ms=12.500 main=1 success=1 items=6 bytes=4096 dropped=3"
        )
    }

    func testMinimumDurationIncludesBoundaryAndSuppressesFastWork() {
        XCTAssertTrue(IOTimingDiagnostics.meetsThreshold(duration: 0, minimum: 0))
        XCTAssertFalse(IOTimingDiagnostics.meetsThreshold(duration: 999_999, minimum: 1_000_000))
        XCTAssertTrue(IOTimingDiagnostics.meetsThreshold(duration: 1_000_000, minimum: 1_000_000))
        XCTAssertTrue(IOTimingDiagnostics.meetsThreshold(duration: 1_000_001, minimum: 1_000_000))
    }

    func testDisabledMeasurementPreservesResultWithoutCollectingMetrics() throws {
        guard !IOTimingDiagnostics.isEnabled else {
            throw XCTSkip("Run without PLZIO to verify the disabled fast path.")
        }
        var calls = 0
        let callerWasMain = Thread.isMainThread
        let result = IOTimingDiagnostics.measure(.homeModelLoad, metrics: { _ in
            XCTFail("Disabled diagnostics must not collect counts.")
            return .init()
        }) {
            calls += 1
            XCTAssertEqual(Thread.isMainThread, callerWasMain)
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, 1)
    }

    func testMeasurementPreservesThrownErrorAndExecutesOnce() {
        enum Expected: Error { case failure }
        var calls = 0
        XCTAssertThrowsError(try IOTimingDiagnostics.measure(.identityModelSave) {
            calls += 1
            throw Expected.failure
        }) { error in
            XCTAssertTrue(error is Expected)
        }
        XCTAssertEqual(calls, 1)
    }

    func testOutputRunsOffMainAndDropsInsteadOfWaitingForSlowSink() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Diagnostic sink finished")
        let output = IOTimingDiagnostics.Output(capacity: 1) { line in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(line.hasPrefix("PLZIO label=home.hero.write "))
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            finished.fulfill()
        }
        defer { release.signal() }
        XCTAssertTrue(output.enqueue(record()))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(output.enqueue(record()))
        release.signal()
        wait(for: [finished], timeout: 2)
    }
}
