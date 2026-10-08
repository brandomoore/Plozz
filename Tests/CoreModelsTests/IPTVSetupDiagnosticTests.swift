import CoreModels
import Foundation
import XCTest

final class IPTVSetupDiagnosticTests: XCTestCase {
    func testCampaignRemainsEnabledForTestFlightAndDebugWithoutABuildNumber() {
        for environment in ["testflight", "debug"] {
            XCTAssertTrue(IPTVSetupDiagnostic.isEnabled(environment: environment), environment)
        }
    }

    func testCampaignNeverEnablesProductionOrUnknownReleaseChannels() {
        for environment in ["production", "appstore", "development", "TestFlight", ""] {
            XCTAssertFalse(IPTVSetupDiagnostic.isEnabled(environment: environment), environment)
        }
    }

    func testDisabledDiagnosticsAllocateNoAttemptAndRevocationDiscardsOldAttempts() throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = SetupDiagnosticBuffer()
        XCTAssertNil(diagnostics.begin(source: .playlistURL, authentication: .basic, entry: .addAccount))
        diagnostics.start { buffer.append($0) }
        let old = try XCTUnwrap(diagnostics.begin(source: .playlistURL, authentication: .basic, entry: .addAccount))
        diagnostics.stop()
        diagnostics.start { buffer.append($0) }
        old.advance(to: .playlist)
        old.record(entries: 100_000)
        old.finish(.init(.authentication))
        XCTAssertEqual(buffer.values.count, 1)
        let current = try XCTUnwrap(diagnostics.begin(source: .playlistURL, authentication: .basic, entry: .addAccount))
        current.finish(.init(.authentication))
        XCTAssertEqual(buffer.values.count, 3)
        XCTAssertEqual(buffer.values.last?.outcome, .failed)
    }

    func testLargeImportHasBoundedMarkersAndExactlyOneTerminalResult() throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = SetupDiagnosticBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(source: .playlistFile, authentication: .none, entry: .addAccount))
        for index in 0..<100_000 {
            attempt.advance(to: index.isMultiple(of: 2) ? .playlist : .catalogCommit)
        }
        attempt.record(entries: 100_000, playlistBytes: 50_000_000, skippedEntries: 3)
        attempt.advance(to: .persistence)
        attempt.finish(.init(.storage))
        attempt.finish()
        attempt.finish(.init(.cancelled))
        attempt.advance(to: .playlist)
        XCTAssertEqual(buffer.values.count, IPTVSetupAttempt.maximumStageMarkers + 1)
        let failure = try XCTUnwrap(buffer.values.last)
        XCTAssertEqual(failure.stage, .persistence)
        XCTAssertEqual(failure.entries, 100_000)
        XCTAssertEqual(failure.playlistBytes, 50_000_000)
        XCTAssertEqual(failure.skippedEntries, 3)
        XCTAssertEqual(failure.failure?.reason, .storage)
        XCTAssertGreaterThanOrEqual(failure.elapsedMilliseconds, failure.stageMilliseconds)
    }

    func testRevocationWaitsForInFlightRecordingAndCannotReplayIntoANewSink() async throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = SetupDiagnosticBuffer()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopping = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        diagnostics.start {
            if $0.stage == .authentication {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
            buffer.append($0)
        }
        let attempt = try XCTUnwrap(diagnostics.begin(source: .playlistURL, authentication: .basic, entry: .addAccount))
        let recording = Task.detached { attempt.advance(to: .authentication) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let revoking = Task.detached {
            stopping.signal()
            diagnostics.stop()
            stopped.signal()
        }
        XCTAssertEqual(stopping.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.02), .timedOut)
        release.signal()
        await recording.value
        await revoking.value
        diagnostics.start { buffer.append($0) }
        attempt.finish(.init(.authentication))
        XCTAssertEqual(buffer.values.map(\.outcome), [.started, .started])
    }

    func testAttemptBudgetAndTaskLocalScope() async throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = SetupDiagnosticBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(source: .xtream, authentication: .xtream, entry: .addAccount))
        await IPTVSetupDiagnostics.$current.withValue(attempt) {
            await Task { IPTVSetupDiagnostics.current?.willRequest() }.value
        }
        XCTAssertNil(IPTVSetupDiagnostics.current)
        attempt.finish()
        XCTAssertEqual(buffer.values.last?.requestCount, 1)
        for _ in 1..<IPTVSetupDiagnostics.maximumAttempts {
            XCTAssertNotNil(diagnostics.begin(source: .xtream, authentication: .xtream, entry: .addAccount))
        }
        XCTAssertNil(diagnostics.begin(source: .xtream, authentication: .xtream, entry: .addAccount))
    }

    func testLaterRequestClearsEarlierHTTPAndTransportEvidence() throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = SetupDiagnosticBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(source: .playlistURL, authentication: .url, entry: .addSource))
        attempt.willRequest()
        attempt.received(status: 503, response: .html)
        attempt.recordTransportFailure(.init(.timeout, networkCode: -1001))
        attempt.willRequest()
        attempt.recordTransportFailure(.init(.offline, networkCode: -1009))
        attempt.finish(.init(.network))
        XCTAssertNil(buffer.values.last?.httpStatus)
        XCTAssertNil(buffer.values.last?.response)
        XCTAssertEqual(buffer.values.last?.failure, .init(.offline, networkCode: -1009))
        XCTAssertEqual(buffer.values.last?.requestCount, 2)
    }

    func testContentTypeAndCounterInputsCannotBecomeFreeFormDiagnosticData() throws {
        XCTAssertEqual(IPTVSetupDiagnostic.Response(mimeType: "text/html; private=credential"), .html)
        XCTAssertEqual(IPTVSetupDiagnostic.Response(mimeType: "https://private.test/token"), .other)
        XCTAssertNil(IPTVSetupDiagnostic.Failure(.other, networkCode: Int.max).networkCode)
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = SetupDiagnosticBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(source: .playlistFile, authentication: .none, entry: .addAccount))
        attempt.record(entries: Int.max, playlistBytes: Int.max, skippedEntries: Int.max)
        attempt.record(entries: Int.max, skippedEntries: Int.max)
        attempt.received(status: Int.max, response: .other)
        attempt.finish(.init(.cancelled))
        XCTAssertEqual(buffer.values.last?.entries, IPTVSetupAttempt.maximumCount)
        XCTAssertEqual(buffer.values.last?.skippedEntries, IPTVSetupAttempt.maximumCount)
        XCTAssertNil(buffer.values.last?.httpStatus)
        XCTAssertNil(buffer.values.last?.failure)
        XCTAssertEqual(buffer.values.last?.outcome, .cancelled)
    }
}

private final class SetupDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IPTVSetupDiagnostic] = []
    var values: [IPTVSetupDiagnostic] { lock.withLock { storage } }
    func append(_ diagnostic: IPTVSetupDiagnostic) { lock.withLock { storage.append(diagnostic) } }
}
