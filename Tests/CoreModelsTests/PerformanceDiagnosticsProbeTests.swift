import Foundation
@testable import CoreModels
@testable import TestSupportPerformance
import XCTest

@MainActor
final class PerformanceDiagnosticsProbeTests: XCTestCase {
    func testPerformancePlaybackJournalDisabled() async throws {
        try await measurePlaybackJournal(enabled: false)
    }

    func testPerformancePlaybackJournalEnabled() async throws {
        try await measurePlaybackJournal(enabled: true)
    }

    private func measurePlaybackJournal(enabled: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        let scenario = enabled ? "playback-journal-enabled" : "playback-journal-disabled"
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("journal.json")
            let journal = enabled ? PlaybackDiagnosticJournal(url: url) : nil
            let facts = PlaybackDiagnosticJournal.Facts(provider: .plex, engine: .plozzigen)
            let events: [PlaybackDiagnosticJournal.Event] = [
                .requested, .resolved, .loading, .loaded, .firstFrame,
                .failed, .compatibilityRetry, .releaseStarted, .releaseFinished, .stopped
            ]
            var notifications = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<1_000 {
                let session = UUID(), attempt = UUID()
                for event in events {
                    notifications += 1
                    journal?.record(event, session: session, attempt: attempt, facts: facts, elapsed: 2)
                }
            }
            let enqueueMicroseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000)
            var retained = 0, discarded = 0, bytes = 0
            if let journal {
                await journal.flush()
                let data = try Data(contentsOf: url)
                let completed = try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: data)
                retained = completed.entries.count
                discarded = completed.discarded
                bytes = data.count
                XCTAssertEqual(retained + discarded, notifications)
                XCTAssertGreaterThan(retained, 0)
                XCTAssertLessThanOrEqual(retained, PlaybackDiagnosticJournal.maximumEntries)
                XCTAssertLessThanOrEqual(bytes, PlaybackDiagnosticJournal.maximumBytes)
            }
            XCTAssertEqual(notifications, 10_000)
            return ["notifications": notifications, "retained": retained, "discarded": discarded,
                    "persistedBytes": bytes, "enqueueMicroseconds": enqueueMicroseconds]
        }
    }

    func testPerformanceDisabledOperations() async throws {
        try await measureOperations(enabled: false, scenario: "diagnostics-disabled")
    }

    func testPerformanceEnabledOperations() async throws {
        try await measureOperations(enabled: true, scenario: "diagnostics-enabled")
    }

    private func measureOperations(enabled: Bool, scenario: String) async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let diagnostics = PerformanceDiagnostics()
            if enabled { diagnostics.start() }
            defer { diagnostics.stop() }
            var accepted = 0
            for _ in 0..<10_000 {
                if let span = diagnostics.begin(.serverRequest, provider: .plex, metrics: .init(requests: 1)) {
                    accepted += 1
                    span.finish(.succeeded, metrics: .init(bytes: 4_096), httpStatus: 200)
                }
            }
            let snapshot = diagnostics.snapshot()
            let retained = (snapshot?.recent.count ?? 0) + (snapshot?.slow.count ?? 0)
            XCTAssertEqual(accepted, enabled ? 10_000 : 0)
            XCTAssertEqual(snapshot?.active.count ?? 0, 0)
            XCTAssertLessThanOrEqual(retained, PerformanceDiagnostics.maximumRecent + PerformanceDiagnostics.maximumSlow)
            XCTAssertEqual((snapshot?.dropped ?? 0) + retained, accepted)
            return ["attempts": 10_000, "accepted": accepted, "retained": retained, "dropped": snapshot?.dropped ?? 0]
        }
    }

    func testPerformanceSnapshotSerialization() async throws {
        try PerformanceProbe.requireEnabled()
        // Full fixed reservoirs, no sleeps or background work in the fixture.
        let clock = SnapshotProbeClock()
        let diagnostics = PerformanceDiagnostics(uptime: { clock.now() })
        diagnostics.start()
        defer { diagnostics.stop() }
        for _ in 0..<PerformanceDiagnostics.maximumRecent {
            diagnostics.begin(.serverRequest, provider: .plex)?.finish(.succeeded, httpStatus: 200)
            diagnostics.begin(.homePublish)?.finish(.succeeded)
        }
        let home = try XCTUnwrap(diagnostics.beginHomeObservation())
        var metrics = PerformanceDiagnostics.HomeUIMetrics()
        metrics.samples = 1
        for _ in 0..<PerformanceDiagnostics.maximumHomeUI {
            clock.advance()
            XCTAssertTrue(home.record(metrics))
        }
        home.stop()
        for _ in 0..<PerformanceDiagnostics.maximumSlow {
            let span = diagnostics.begin(.homeMerge, provider: .jellyfin, metrics: .init(items: 100))
            clock.advance()
            span?.finish(.succeeded)
        }
        let active = (0..<PerformanceDiagnostics.maximumActive).compactMap { _ in
            diagnostics.begin(.homeLoad, provider: .plex, metrics: .init(accounts: 4))
        }
        defer { active.forEach { $0.finish(.cancelled) } }
        try await PerformanceProbe.measure(self, scenario: "diagnostics-snapshot") {
            var serializedBytes = 0
            var records = 0
            for _ in 0..<100 {
                let snapshot = try XCTUnwrap(diagnostics.snapshot())
                let data = try JSONEncoder().encode(snapshot)
                let context = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertNotNil(context)
                serializedBytes += data.count
                records += snapshot.active.count + snapshot.recent.count + snapshot.slow.count
                    + snapshot.homeRecent.count + snapshot.homeSlow.count + snapshot.homeUI.count
            }
            XCTAssertEqual(records, 15_600)
            XCTAssertGreaterThan(serializedBytes, 0)
            return ["snapshots": 100, "records": records, "serializedBytes": serializedBytes]
        }
    }
}

private final class SnapshotProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func now() -> UInt64 { lock.withLock { value } }
    func advance() { lock.withLock { value += 250_000_000 } }
}
