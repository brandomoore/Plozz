import CoreModels
import Foundation
@testable import ProviderShare
import XCTest
import os

final class ShareStreamProbeCacheTests: XCTestCase {
    private let credentialRevision = CredentialRevision()

    private func locator(revision: String = "one") throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: "share", sourceID: "source",
            credentialRevision: credentialRevision,
            relativePath: "movie.mkv",
            representation: RemoteFileRepresentation(
                size: 4096,
                identity: RemoteFileIdentity(kind: .strongETag, value: "\"\(revision)\""),
                consistency: .changeDetecting),
            formatHint: .init(container: "mkv"))
    }

    func testIndependentCoverageMergesPositiveFactsAndReusesCombinedRequest() async throws {
        let cache = ShareStreamProbeCache()
        let locator = try locator()
        let calls = Requests()
        let audio = await cache.facts(for: locator, requirements: .atmos) { requirements in
            await calls.record(requirements)
            return .init(audioTrackID: 4, audioCodec: "eac3", audioChannels: 6, audioIsAtmos: true)
        }
        let video = await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus, .streamDetails]) { requirements in
            await calls.record(requirements)
            return .init(videoRangeType: "HDR10Plus", audioIsAtmos: false)
        }
        let repeated = await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
            XCTFail("Both independent scans were already completed")
            return nil
        }
        let requests = await calls.values
        XCTAssertEqual(requests, [.atmos, .hdr10Plus])
        XCTAssertTrue(audio?.audioIsAtmos == true)
        XCTAssertEqual(video, repeated)
        XCTAssertEqual(video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(video?.audioTrackID, 4)
        XCTAssertTrue(video?.audioIsAtmos == true)
    }

    func testVideoCoverageDoesNotConsumeLaterAtmosScanOrDemoteDolbyVision() async throws {
        let cache = ShareStreamProbeCache()
        let locator = try locator()
        _ = await cache.facts(for: locator, requirements: .hdr10Plus) { _ in
            .init(videoRangeType: "DOVI")
        }
        let calls = Requests()
        let facts = await cache.facts(for: locator, requirements: [.hdr10Plus, .atmos]) { requirements in
            await calls.record(requirements)
            return .init(
                videoRangeType: "HDR10Plus", audioTrackID: 1, audioIsAtmos: true,
                carriesHDR10PlusMetadata: true)
        }
        let requests = await calls.values
        XCTAssertEqual(requests, [.atmos])
        XCTAssertEqual(facts?.videoRangeType, "DOVI")
        XCTAssertEqual(facts?.carriesHDR10PlusMetadata, true)
        XCTAssertTrue(facts?.audioIsAtmos == true)
    }

    func testBoundedUnknownOnlyCompletesRequestedCoverage() async throws {
        let cache = ShareStreamProbeCache()
        let locator = try locator()
        let unknown = await cache.facts(for: locator, requirements: .atmos) { _ in nil }
        let calls = Requests()
        let video = await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { requirements in
            await calls.record(requirements)
            return .init(videoRangeType: "HDR10Plus")
        }
        let requests = await calls.values
        XCTAssertNil(unknown)
        XCTAssertEqual(requests, [.hdr10Plus])
        XCTAssertEqual(video?.videoRangeType, "HDR10Plus")
        XCTAssertFalse(video?.audioIsAtmos ?? true, "Unknown is not a positive Atmos confirmation")
    }

    func testLastCancelledWaiterCancelsLoaderWithoutCachingPositiveOrUnknown() async throws {
        for result in [nil, ProbedStreamFacts(videoRangeType: "DOVI", audioIsAtmos: true)] {
            let cache = ShareStreamProbeCache()
            let locator = try locator()
            let gate = ProbeGate()
            let cancelled = expectation(description: "Underlying probe cancelled")
            let first = Task {
                await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
                    await withTaskCancellationHandler {
                        await gate.wait()
                        return result
                    } onCancel: {
                        cancelled.fulfill()
                    }
                }
            }
            await gate.waitUntilStarted()
            let originalLoader = await cache.pendingTask(for: locator)
            XCTAssertNotNil(originalLoader)
            first.cancel()
            await fulfillment(of: [cancelled], timeout: 2)
            let abandoned = await first.value
            XCTAssertNil(abandoned)
            let cached = await cache.completedFacts(for: locator)
            XCTAssertNil(cached)

            // A replacement can complete before an uncooperative cancelled
            // loader drains. The old flight must not overwrite the new proof.
            let retry = await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
                .init(videoRangeType: "HDR10Plus")
            }
            XCTAssertEqual(retry?.videoRangeType, "HDR10Plus")
            await gate.open()
            await originalLoader?.value
            let repeated = await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
                XCTFail("The live replacement request should be cached")
                return nil
            }
            XCTAssertEqual(repeated?.videoRangeType, "HDR10Plus")
            XCTAssertFalse(repeated?.audioIsAtmos ?? true)
        }
    }

    func testOneCancelledWaiterDoesNotCancelAnotherCoalescedConsumer() async throws {
        let cache = ShareStreamProbeCache()
        let locator = try locator()
        let gate = ProbeGate()
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        let first = Task {
            await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                    return .init(videoRangeType: "HDR10Plus", audioIsAtmos: true)
                } onCancel: {
                    cancellation.withLock { $0 = true }
                }
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
                XCTFail("The second consumer must share the existing loader")
                return nil
            }
        }
        await waitForWaiters(2, in: cache)
        first.cancel()
        let abandoned = await first.value
        XCTAssertNil(abandoned)
        await gate.open()
        let live = await second.value
        XCTAssertFalse(cancellation.withLock { $0 })
        XCTAssertEqual(live?.videoRangeType, "HDR10Plus")
        XCTAssertTrue(live?.audioIsAtmos == true)
        let cached = await cache.completedFacts(for: locator)
        XCTAssertEqual(cached, live)
    }

    func testCancelledHDRScanRetainsCompletedAudioButLeavesHDRRetryable() async throws {
        let cache = ShareStreamProbeCache()
        let locator = try locator()
        _ = await cache.facts(for: locator, requirements: .atmos) { _ in .init(audioIsAtmos: true) }
        let gate = ProbeGate()
        let cancelled = expectation(description: "HDR loader cancelled")
        let scan = Task {
            await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                    return nil
                } onCancel: {
                    cancelled.fulfill()
                }
            }
        }
        await gate.waitUntilStarted()
        let originalLoader = await cache.pendingTask(for: locator)
        scan.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        _ = await scan.value
        await gate.open()
        await originalLoader?.value
        let calls = Requests()
        let retry = await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { requirements in
            await calls.record(requirements)
            return .init(videoRangeType: "HDR10Plus")
        }
        let requests = await calls.values
        XCTAssertEqual(requests, [.hdr10Plus])
        XCTAssertTrue(retry?.audioIsAtmos == true)
        XCTAssertEqual(retry?.videoRangeType, "HDR10Plus")
    }

    func testCoalescedConsumerRequestsOnlyRemainingCoverageAfterFirstScan() async throws {
        let cache = ShareStreamProbeCache()
        let locator = try locator()
        let gate = ProbeGate()
        let first = Task {
            await cache.facts(for: locator, requirements: .atmos) { _ in
                await gate.wait()
                return .init(audioIsAtmos: true)
            }
        }
        await gate.waitUntilStarted()
        let calls = Requests()
        let second = Task {
            await cache.facts(for: locator, requirements: [.atmos, .hdr10Plus]) { requirements in
                await calls.record(requirements)
                return .init(videoRangeType: "HDR10Plus")
            }
        }
        await waitForWaiters(2, in: cache)
        await gate.open()
        _ = await first.value
        let facts = await second.value
        let requests = await calls.values
        XCTAssertEqual(requests, [.hdr10Plus])
        XCTAssertTrue(facts?.audioIsAtmos == true)
        XCTAssertEqual(facts?.videoRangeType, "HDR10Plus")
    }

    func testRepresentationRevisionInvalidatesCoverageAndPositiveFacts() async throws {
        let cache = ShareStreamProbeCache()
        let first = try locator(revision: "one")
        let replacement = try locator(revision: "two")
        _ = await cache.facts(for: first, requirements: [.atmos, .hdr10Plus]) { _ in
            .init(videoRangeType: "DOVI", audioIsAtmos: true)
        }
        let cachedReplacement = await cache.completedFacts(for: replacement)
        XCTAssertNil(cachedReplacement)
        let calls = Requests()
        let facts = await cache.facts(for: replacement, requirements: [.atmos, .hdr10Plus]) { requirements in
            await calls.record(requirements)
            return .init(videoRangeType: "SDR")
        }
        let requests = await calls.values
        XCTAssertEqual(requests, [[.atmos, .hdr10Plus]])
        XCTAssertEqual(facts?.videoRangeType, "SDR")
        XCTAssertFalse(facts?.audioIsAtmos ?? true)
    }

    private func waitForWaiters(_ count: Int, in cache: ShareStreamProbeCache) async {
        for _ in 0..<10_000 {
            if await cache.pendingWaiterCount == count { return }
            await Task.yield()
        }
        XCTFail("Probe consumers did not reach their deterministic gate")
    }

    private actor Requests {
        var values: [SupplementalStreamProbeRequirements] = []
        func record(_ requirements: SupplementalStreamProbeRequirements) { values.append(requirements) }
    }

    private actor ProbeGate {
        private var started = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }
}
