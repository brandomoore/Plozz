import Foundation
import XCTest
@testable import CoreModels

final class PerformanceDiagnosticsTests: XCTestCase {
    func testConsentOffDoesNotReadClockOrRetainOperations() {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        for _ in 0..<10_000 {
            XCTAssertNil(diagnostics.begin(.homeLoad, metrics: .init(items: Int.max)))
        }
        XCTAssertNil(diagnostics.snapshot())
        XCTAssertNil(diagnostics.beginHomeObservation())
        XCTAssertEqual(clock.reads, 0)
    }

    func testIncompleteOperationIncludesMonotonicStartElapsedThreadAndOverlap() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        clock.advance(milliseconds: 10)
        let first = try XCTUnwrap(diagnostics.begin(.homeLoad, provider: .plex, metrics: .init(accounts: 2)))
        clock.advance(milliseconds: 20)
        let second = try XCTUnwrap(diagnostics.begin(.serverRequest, metrics: .init(requests: 1)))
        clock.advance(milliseconds: 1_000)
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.elapsedMilliseconds, 1_030)
        XCTAssertEqual(snapshot.maxActive, 2)
        XCTAssertEqual(snapshot.active.map(\.startedMilliseconds), [10, 30])
        XCTAssertEqual(snapshot.active.map(\.elapsedMilliseconds), [1_020, 1_000])
        XCTAssertEqual(snapshot.active.map(\.activeAtStart), [1, 2])
        XCTAssertEqual(snapshot.active.first?.startedOnMain, Thread.isMainThread)
        XCTAssertEqual(snapshot.active.first?.provider, .plex)
        XCTAssertEqual(snapshot.active.first?.metrics.accounts, 2)
        XCTAssertTrue(snapshot.active.allSatisfy { $0.outcome == nil })
        XCTAssertTrue(snapshot.recent.isEmpty)
        XCTAssertTrue(snapshot.slow.isEmpty)
        first.finish(.succeeded)
        second.finish(.cancelled)
    }

    func testActiveAndCompletedStorageAreBoundedAndFastFloodPreservesSlowEvidence() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        let active = (0..<PerformanceDiagnostics.maximumActive).compactMap { _ in diagnostics.begin(.homeLoad) }
        XCTAssertEqual(active.count, 32)
        for _ in 0..<10_000 { XCTAssertNil(diagnostics.begin(.serverRequest)) }
        XCTAssertEqual(diagnostics.snapshot()?.dropped, 10_000)
        clock.advance(milliseconds: 250)
        active.forEach { $0.finish(.succeeded) }
        for _ in 0..<10_000 { diagnostics.begin(.serverRequest)?.finish(.succeeded) }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertTrue(snapshot.active.isEmpty)
        XCTAssertEqual(snapshot.recent.count, PerformanceDiagnostics.maximumRecent)
        XCTAssertEqual(snapshot.slow.count, PerformanceDiagnostics.maximumSlow)
        XCTAssertTrue(snapshot.slow.allSatisfy { $0.operation == .homeLoad && $0.elapsedMilliseconds == 250 })
        XCTAssertTrue(snapshot.recent.allSatisfy { $0.operation == .serverRequest && $0.elapsedMilliseconds == 0 })
        XCTAssertEqual(snapshot.dropped, 20_000)
        XCTAssertEqual(snapshot.maxActive, 32)
    }

    func testConcurrentAdmissionFinishAndSnapshotRemainBounded() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        DispatchQueue.concurrentPerform(iterations: 5_000) { _ in
            let span = diagnostics.begin(.serverDecode, metrics: .init(bytes: 4_096))
            span?.finish(.succeeded)
            span?.finish(.failed)
            if let snapshot = diagnostics.snapshot() {
                XCTAssertLessThanOrEqual(snapshot.active.count, PerformanceDiagnostics.maximumActive)
                XCTAssertLessThanOrEqual(snapshot.recent.count, PerformanceDiagnostics.maximumRecent)
                XCTAssertLessThanOrEqual(snapshot.slow.count, PerformanceDiagnostics.maximumSlow)
                XCTAssertTrue((snapshot.recent + snapshot.slow).allSatisfy { $0.outcome == .succeeded })
            }
        }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertTrue(snapshot.active.isEmpty)
        XCTAssertEqual(snapshot.dropped + snapshot.recent.count + snapshot.slow.count, 5_000)
        XCTAssertLessThanOrEqual(snapshot.maxActive, 32)
    }

    func testStopClearsStateAndFencesOldSpansAcrossRestartAndIDReuse() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        let old = try XCTUnwrap(diagnostics.begin(.homeLoad, provider: .plex, metrics: .init(items: 8)))
        diagnostics.stop()
        XCTAssertNil(diagnostics.snapshot())
        old.finish(.failed, networkCode: -1001)
        XCTAssertNil(diagnostics.snapshot())
        diagnostics.start()
        let current = try XCTUnwrap(diagnostics.begin(.playlistImport, provider: .iptv))
        old.finish(.failed)
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.active.count, 1)
        XCTAssertEqual(snapshot.active.first?.operation, .playlistImport)
        XCTAssertTrue(snapshot.recent.isEmpty)
        XCTAssertTrue(snapshot.slow.isEmpty)
        XCTAssertEqual(snapshot.maxActive, 1)
        XCTAssertEqual(snapshot.dropped, 0)
        current.finish(.cancelled)
        XCTAssertEqual(diagnostics.snapshot()?.recent.first?.outcome, .cancelled)
        diagnostics.stop()
        diagnostics.stop()
        diagnostics.start()
        XCTAssertEqual(diagnostics.snapshot()?.maxActive, 0)
    }

    func testStartIsIdempotentAndFinishOnlyWinsOnceWithMergedMetrics() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        let span = try XCTUnwrap(diagnostics.begin(
            .serverRequest, metrics: .init(items: 4, bytes: 512, rows: 2, credits: 8, accounts: 1, requests: 1)
        ))
        clock.advance(milliseconds: 12)
        diagnostics.start()
        span.finish(.failed, metrics: .init(items: 10, requests: 2), httpStatus: 503, networkCode: -1001)
        let readsAfterFinish = clock.reads
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            span.finish(.succeeded, metrics: .init(items: 99), httpStatus: 200)
        }
        XCTAssertEqual(clock.reads, readsAfterFinish)
        let record = try XCTUnwrap(diagnostics.snapshot()?.recent.first)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.elapsedMilliseconds, 12)
        XCTAssertEqual(record.metrics, .init(items: 10, bytes: 512, rows: 2, credits: 8, accounts: 1, requests: 2))
        XCTAssertEqual(record.httpStatus, 503)
        XCTAssertEqual(record.networkCode, -1001)
        XCTAssertEqual(diagnostics.snapshot()?.recent.count, 1)
    }

    func testSnapshotGenerationFenceIsNeverSerializedAndRejectsRestartedConsent() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertTrue(diagnostics.isCurrent(snapshot))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), [
            "schema", "elapsedMilliseconds", "maxActive", "dropped", "active", "recent", "slow",
            "homeRecent", "homeSlow", "homeDropped", "homeUI", "homeUIDropped"
        ])
        diagnostics.stop()
        XCTAssertFalse(diagnostics.isCurrent(snapshot))
        diagnostics.start()
        XCTAssertFalse(diagnostics.isCurrent(snapshot))
        XCTAssertTrue(diagnostics.isCurrent(try XCTUnwrap(diagnostics.snapshot())))
        let other = PerformanceDiagnostics()
        other.start()
        XCTAssertFalse(other.isCurrent(snapshot))
    }

    func testEventSnapshotRequiresTimestampWithinCurrentConsentSession() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() }, wallClock: { clock.date() })
        let beforeStart = clock.date()
        clock.advance(milliseconds: 1_000)
        diagnostics.start()
        let atStart = clock.date()
        clock.advance(milliseconds: 1_000)
        let span = try XCTUnwrap(diagnostics.begin(.homeLoad))
        let duringSession = clock.date()
        clock.advance(milliseconds: 1_000)

        XCTAssertNil(diagnostics.snapshot(forEventAt: beforeStart))
        XCTAssertNotNil(diagnostics.snapshot(forEventAt: atStart))
        XCTAssertEqual(diagnostics.snapshot(forEventAt: duringSession)?.active.count, 1)
        XCTAssertNotNil(diagnostics.snapshot(forEventAt: clock.date()))
        XCTAssertNil(diagnostics.snapshot(forEventAt: clock.date().addingTimeInterval(1)))
        XCTAssertNil(diagnostics.snapshot(forEventAt: Date(timeIntervalSince1970: .nan)))
        XCTAssertNil(diagnostics.snapshot(forEventAt: Date(timeIntervalSince1970: .infinity)))
        diagnostics.start()
        XCTAssertNotNil(diagnostics.snapshot(forEventAt: atStart))

        diagnostics.stop()
        XCTAssertNil(diagnostics.snapshot(forEventAt: duringSession))
        clock.advance(milliseconds: 1_000)
        diagnostics.start()
        XCTAssertNil(diagnostics.snapshot(forEventAt: duringSession))
        XCTAssertNotNil(diagnostics.snapshot(forEventAt: clock.date()))
        span.finish(.failed)
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).recent.isEmpty)
    }

    func testConcurrentFinishesHaveOneOutcomeAndCompletion() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        let span = try XCTUnwrap(diagnostics.begin(.playlistFetch))
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            span.finish(index.isMultiple(of: 2) ? .cancelled : .failed)
        }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertTrue(snapshot.active.isEmpty)
        XCTAssertEqual(snapshot.recent.count + snapshot.slow.count, 1)
        XCTAssertEqual(snapshot.dropped, 0)
    }

    func testTaskLocalProviderIsInheritedButExplicitProviderWins() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        PerformanceDiagnostics.$provider.withValue(.plex) {
            diagnostics.begin(.homeFetch)?.finish(.succeeded)
            diagnostics.begin(.serverDecode, provider: .jellyfin)?.finish(.succeeded)
        }
        diagnostics.begin(.homePublish)?.finish(.succeeded)
        let records = try XCTUnwrap(diagnostics.snapshot()).recent
        XCTAssertEqual(records.first { $0.operation == .homeFetch }?.provider, .plex)
        XCTAssertEqual(records.first { $0.operation == .serverDecode }?.provider, .jellyfin)
        XCTAssertNil(records.first { $0.operation == .homePublish }?.provider)
        XCTAssertNil(PerformanceDiagnostics.provider)
    }

    func testInvalidMetricsAndCodesAreDroppedAndTimeSaturates() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        let span = try XCTUnwrap(diagnostics.begin(
            .homeMerge, metrics: .init(items: -1, bytes: Int.max, rows: 2)
        ))
        clock.advance(milliseconds: PerformanceDiagnostics.maximumMilliseconds + 1_000)
        span.finish(
            .cancelled, metrics: .init(rows: -1, credits: Int.max, accounts: -5, requests: 0),
            httpStatus: 600, networkCode: Int.min
        )
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        let record = try XCTUnwrap(snapshot.slow.first)
        XCTAssertEqual(snapshot.elapsedMilliseconds, PerformanceDiagnostics.maximumMilliseconds)
        XCTAssertEqual(record.elapsedMilliseconds, PerformanceDiagnostics.maximumMilliseconds)
        XCTAssertEqual(record.metrics, .init(rows: 2, requests: 0))
        XCTAssertNil(record.httpStatus)
        XCTAssertNil(record.networkCode)
        XCTAssertEqual(record.outcome, .cancelled)
    }

    func testWorkerStartIsNotReportedAsMainThreadWork() throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        let finished = expectation(description: "Worker operation")
        DispatchQueue.global().async {
            diagnostics.begin(.shareScan)?.finish(.succeeded)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertFalse(try XCTUnwrap((snapshot.recent + snapshot.slow).first).startedOnMain)
    }

    func testConcurrentConsentChangesCannotRestoreStoppedRecords() {
        let diagnostics = PerformanceDiagnostics()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            diagnostics.start()
            let span = diagnostics.begin(.liveTVRefresh)
            diagnostics.stop()
            diagnostics.start()
            span?.finish(.failed)
        }
        diagnostics.stop()
        XCTAssertNil(diagnostics.snapshot())
        diagnostics.start()
        XCTAssertEqual(diagnostics.snapshot()?.active.count, 0)
        XCTAssertEqual(diagnostics.snapshot()?.recent.count, 0)
        XCTAssertEqual(diagnostics.snapshot()?.slow.count, 0)
        XCTAssertEqual(diagnostics.snapshot()?.dropped, 0)
    }

    func testHomeAdmissionAndCompletionEvidenceSurviveFastAndSlowNetworkFloods() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        let requests = (0..<32).compactMap { _ in diagnostics.begin(.serverRequest) }
        XCTAssertEqual(requests.count, 28)
        let load = try XCTUnwrap(diagnostics.begin(.homeLoad))
        let publish = try XCTUnwrap(diagnostics.begin(.homePublish, metrics: .init(items: 800, rows: 40)))
        publish.finish(.succeeded)
        clock.advance(milliseconds: 300)
        load.finish(.succeeded)
        requests.forEach { $0.finish(.succeeded) }
        for _ in 0..<1_000 {
            diagnostics.begin(.serverDecode)?.finish(.succeeded)
            let request = diagnostics.begin(.serverRequest)
            clock.advance(milliseconds: 300)
            request?.finish(.succeeded)
        }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.homeRecent.map(\.operation), [.homePublish])
        XCTAssertEqual(snapshot.homeRecent.first?.metrics.rows, 40)
        XCTAssertEqual(snapshot.homeSlow.map(\.operation), [.homeLoad])
        XCTAssertFalse((snapshot.recent + snapshot.slow).contains { $0.operation.isHomePresentation })
        XCTAssertEqual(snapshot.homeDropped, 0)
    }

    func testReservedHomeHistoryIsBoundedAndClearedOnOptOut() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        for _ in 0..<100 {
            diagnostics.begin(.homePublish)?.finish(.succeeded)
            let merge = diagnostics.begin(.homeMerge)
            clock.advance(milliseconds: 300)
            merge?.finish(.succeeded)
        }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.homeRecent.count, 16)
        XCTAssertEqual(snapshot.homeSlow.count, 16)
        XCTAssertEqual(snapshot.homeDropped, 168)
        diagnostics.stop()
        diagnostics.start()
        XCTAssertEqual(diagnostics.snapshot()?.homeRecent.count, 0)
        XCTAssertEqual(diagnostics.snapshot()?.homeSlow.count, 0)
        XCTAssertEqual(diagnostics.snapshot()?.homeDropped, 0)
    }

    func testHomeWindowsAreBoundedSeparateFromNetworkTrafficAndFencedByOwnerAndConsent() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        let observation = try XCTUnwrap(diagnostics.beginHomeObservation())
        var metrics = PerformanceDiagnostics.HomeUIMetrics()
        metrics.samples = 10
        metrics.loadingSamples = 10
        for _ in 0..<100 {
            clock.advance(milliseconds: 1_000)
            XCTAssertTrue(observation.record(metrics))
        }
        for _ in 0..<1_000 { diagnostics.begin(.serverDecode)?.finish(.succeeded) }
        let snapshot = try XCTUnwrap(diagnostics.snapshot())
        XCTAssertEqual(snapshot.homeUI.count, 60)
        XCTAssertEqual(snapshot.homeUIDropped, 40)
        XCTAssertEqual(snapshot.homeUI.first?.startedMilliseconds, 40_000)
        XCTAssertEqual(snapshot.homeUI.last?.elapsedMilliseconds, 1_000)
        XCTAssertEqual(snapshot.homeUI.last?.metrics, metrics)
        let replacement = try XCTUnwrap(diagnostics.beginHomeObservation())
        XCTAssertFalse(observation.isCurrent)
        XCTAssertFalse(observation.record(metrics))
        observation.stop()
        XCTAssertTrue(replacement.isCurrent)
        replacement.stop()
        XCTAssertFalse(replacement.record(metrics))
        let oldConsent = try XCTUnwrap(diagnostics.beginHomeObservation())
        diagnostics.stop()
        diagnostics.start()
        let newConsent = try XCTUnwrap(diagnostics.beginHomeObservation())
        XCTAssertFalse(oldConsent.isCurrent)
        XCTAssertFalse(oldConsent.record(metrics))
        oldConsent.stop()
        XCTAssertTrue(newConsent.isCurrent)
        XCTAssertEqual(diagnostics.snapshot()?.homeUI.count, 0)
        XCTAssertEqual(diagnostics.snapshot()?.homeUIDropped, 0)
    }

    func testInvalidHomeWindowsAreRejectedWithoutReadingTheClock() throws {
        let clock = DiagnosticsClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        let observation = try XCTUnwrap(diagnostics.beginHomeObservation())
        var metrics = PerformanceDiagnostics.HomeUIMetrics()
        let reads = clock.reads
        XCTAssertFalse(observation.record(metrics))
        metrics.samples = 1
        metrics.scrollingSamples = 2
        XCTAssertFalse(observation.record(metrics))
        metrics.scrollingSamples = 0
        metrics.heightChanges = Int.max
        XCTAssertFalse(observation.record(metrics))
        XCTAssertEqual(clock.reads, reads)
        metrics.heightChanges = 0
        metrics.maximumDelayMilliseconds = 10
        XCTAssertFalse(observation.record(metrics), "Delay cannot exceed the observation window")
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).homeUI.isEmpty)
    }
}

private final class DiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    func now() -> UInt64 {
        lock.withLock {
            readCount += 1
            return value
        }
    }
    func date() -> Date {
        lock.withLock { Date(timeIntervalSince1970: 1_700_000_000 + Double(value) / 1_000_000_000) }
    }
    func advance(milliseconds: Int) {
        lock.withLock { value += UInt64(milliseconds) * 1_000_000 }
    }
}
