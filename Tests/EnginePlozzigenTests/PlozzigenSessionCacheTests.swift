@testable import AetherEngine
import CoreModels
import XCTest
@testable import EnginePlozzigen

final class PlozzigenSessionCacheTests: XCTestCase {
    func testPacketProducerReportsItsByteStopAndClearsAfterClose() async throws {
        for memory in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store: any SoftwarePacketStore = memory
                ? SoftwarePacketMemoryFIFO(historyCapBytes: 4096)
                : try SoftwarePacketDiskFIFO(chunkTargetBytes: 4096, retainConsumed: true, parentDirectory: root)
            let source = SoftwarePacketReadAhead(
                video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
                byteBudget: 256, forwardSeconds: 300, initialSourceClock: 0, fifo: store
            ) { _ in
                SoftwareStoredPacket(pts: 0, dts: 0, duration: 40, position: 0,
                    streamIndex: 0, flags: 1, timeBaseNumerator: 1, timeBaseDenominator: 1000,
                    bytes: Data(repeating: 7, count: 200), sideData: [])
            }
            defer { source.close() }
            XCTAssertEqual(source.readAheadStatus?.budgetedBytes, 0)
            XCTAssertEqual(source.readAheadStatus?.byteLimitReached, false)
            source.start()
            let deadline = ContinuousClock.now + .seconds(5)
            while source.readAheadStatus?.byteLimitReached != true, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let status = try XCTUnwrap(source.readAheadStatus)
            XCTAssertTrue(status.byteLimitReached)
            XCTAssertGreaterThanOrEqual(status.budgetedBytes, 256)
            XCTAssertEqual(status.storage, memory ? .memory : .disk)
            XCTAssertEqual(status.targetSeconds, 300)
            source.close()
            XCTAssertNil(source.readAheadStatus)
        }
    }

    func testOnlyActiveCachesPublishIncludingValidZeroUsageAndPlaybackFloor() {
        XCTAssertNil(PlozzigenVideoEngine.sessionCacheTelemetry(.inactive))
        XCTAssertNil(PlozzigenVideoEngine.sessionCacheTelemetry(.nativeRemoteHLS(requestedBudgetBytes: Int.max)))
        for resident in [0, 3_000] {
            XCTAssertEqual(
                PlozzigenVideoEngine.sessionCacheTelemetry(status(resident: resident)),
                EngineSessionCache(residentBytes: Int64(resident), effectiveBudgetBytes: 4_000, targetSeconds: 60)
            )
        }

    }

    func testPacketCacheReportsActualStorageAndLimitsWithoutUsingTheProfileLabel() {
        for storage: SoftwareReadAheadStatus.Storage in [.memory, .disk] {
            let status = SoftwareReadAheadStatus(
                storage: storage, queuedBytes: 90, budgetedBytes: 100,
                byteBudget: 96, targetSeconds: 300, byteLimitReached: true
            )
            XCTAssertEqual(PlozzigenVideoEngine.packetCacheTelemetry(status), EngineSessionCache(
                residentBytes: 100, effectiveBudgetBytes: 96,
                storage: storage == .memory ? .memory : .disk,
                targetSeconds: 300, byteLimitReached: true
            ))
        }
    }

    func testCompletedAndFailedCleanupNeverLookLikeAnActiveCache() {
        for reason: SessionCacheCleanupReason in [.sessionStopped, .sourceChanged, .loadFailed] {
            for result: SessionCacheCleanupResult in [.succeeded, .failed] {
                XCTAssertNil(PlozzigenVideoEngine.sessionCacheTelemetry(
                    status(cleanup: reason, result: result)
                ))
            }
        }
    }

    private func status(
        resident: Int = 0,
        cleanup: SessionCacheCleanupReason? = nil,
        result: SessionCacheCleanupResult = .notRun
    ) -> SessionCacheStatus {
        .init(
            route: .loopbackFMP4, capability: .active, requestedBudgetBytes: 2_000,
            volumeSafetyLimitBytes: 10_000, baseEffectiveBudgetBytes: 2_000,
            playbackSafeFloorBytes: 4_000, effectiveBudgetBytes: 4_000,
            currentResidentBytes: resident, currentForwardBytes: resident,
            forwardWindowSegments: 15, backwardWindowSegments: 5, producerParked: false,
            evictionCount: 0, hardWindowFloorExceeded: true, cleanupReason: cleanup,
            cleanupResult: result, lastFailure: result == .failed ? .cleanupFailed : nil
        )
    }
}
