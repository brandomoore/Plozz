import Foundation
import XCTest
import AetherEngine
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenStreamProbeExecutorTests: XCTestCase {
    func testCombinedAndIndependentSelectionsUseOneControlledCall() async throws {
        for requirements: SupplementalStreamProbeRequirements in [
            .atmos, .hdr10Plus, [.atmos, .hdr10Plus], .streamDetails, []
        ] {
            let reader = ProbeTestReader()
            let calls = ProbeTestCounter()
            let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: reader, formatHint: "matroska", requirements: requirements
            ) { source, details, atmos, hdr, limits, cancellation in
                calls.increment()
                guard case .custom(let received, let hint) = source else {
                    XCTFail("Detail probes must retain the caller's bounded reader")
                    return ProbeTestResults.make()
                }
                XCTAssertTrue(received === reader)
                XCTAssertEqual(hint, "matroska")
                XCTAssertEqual(details.contains(.atmos), requirements.contains(.atmos))
                XCTAssertEqual(details.contains(.hdr10Plus), requirements.contains(.hdr10Plus))
                XCTAssertEqual(limits.maxInputBytes, 8 * 1024 * 1024)
                XCTAssertEqual(limits.maxPackets, 128)
                XCTAssertEqual(limits.maxPacketBytes, 2 * 1024 * 1024)
                XCTAssertGreaterThan(limits.timeBudget, 0)
                XCTAssertLessThanOrEqual(limits.timeBudget, 5)
                let combined = requirements.contains(.hdr10Plus) && requirements.contains(.atmos)
                XCTAssertEqual(hdr.maxPackets, combined ? 4 : 128)
                XCTAssertEqual(atmos.maxPackets, 64)
                if combined {
                    XCTAssertEqual(hdr.maxPackets * 8, 32)
                    XCTAssertEqual(limits.maxPackets - hdr.maxPackets * 8 - atmos.maxPackets, 32)
                }
                XCTAssertEqual(hdr.maxBytes, limits.maxInputBytes)
                XCTAssertEqual(hdr.timeBudget, limits.timeBudget)
                XCTAssertNil(atmos.targetTrackID)
                XCTAssertLessThanOrEqual(atmos.timeBudget, 2)
                XCTAssertFalse(cancellation.isCancelled)
                return ProbeTestResults.make()
            }
            XCTAssertNotNil(result)
            XCTAssertEqual(calls.value, 1)
            XCTAssertEqual(reader.closes.value, 1)
        }
    }

    func testQueuedCancellationSkipsNativeWorkAndEventuallyClosesReader() async {
        let queue = DispatchQueue(label: "probe.test.queued")
        queue.suspend()
        let reader = ProbeTestReader()
        let task = Task {
            await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: reader, requirements: .hdr10Plus, queue: queue
            ) { _, _, _, _, _, _ in
                XCTFail("Cancelled queued work must not enter FFmpeg")
                return ProbeTestResults.make()
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        queue.resume()
        await drain(queue)
        XCTAssertEqual(reader.closes.value, 1)
    }

    func testActiveCancellationDiscardsResultButRetainsNativeSlotAndReader() async {
        let queue = DispatchQueue(label: "probe.test.active")
        let reader = ProbeTestReader()
        let started = expectation(description: "native call entered")
        let finalShutdown = expectation(description: "final shutdown after native return")
        let release = DispatchSemaphore(value: 0)
        let nativeReturned = ProbeTestCounter()
        let laterCalls = ProbeTestCounter()
        let task = Task {
            await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: reader, requirements: [.atmos, .hdr10Plus], queue: queue,
                finalShutdown: {
                    XCTAssertEqual(nativeReturned.value, 1)
                    XCTAssertEqual(reader.closes.value, 1)
                    finalShutdown.fulfill()
                }
            ) { _, _, _, _, _, cancellation in
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                XCTAssertTrue(cancellation.isCancelled)
                nativeReturned.increment()
                return ProbeTestResults.make(carriesHDR10Plus: true)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let cancelledResult = await task.value
        XCTAssertNil(cancelledResult)
        XCTAssertGreaterThan(reader.cancels.value, 0)
        XCTAssertEqual(reader.closes.value, 0)
        let next = Task {
            await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: ProbeTestReader(), requirements: .atmos, queue: queue
            ) { _, _, _, _, _, _ in
                XCTAssertEqual(nativeReturned.value, 1)
                laterCalls.increment()
                return ProbeTestResults.make()
            }
        }
        // The serial slot still contains the first native call, even though its
        // async waiter has already received cancellation.
        XCTAssertEqual(laterCalls.value, 0)
        release.signal()
        let nextResult = await next.value
        XCTAssertNotNil(nextResult)
        await fulfillment(of: [finalShutdown], timeout: 1)
        XCTAssertEqual(laterCalls.value, 1)
    }

    func testDeadlineIncludesQueueWaitAndSkipsExpiredWork() async {
        let queue = DispatchQueue(label: "probe.test.queued-deadline")
        queue.suspend()
        let reader = ProbeTestReader()
        var limits = HDR10PlusProbeLimits()
        limits.wallTimeout = 0.04
        let start = ProcessInfo.processInfo.systemUptime
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, requirements: .hdr10Plus, limits: limits, queue: queue
        ) { _, _, _, _, _, _ in
            XCTFail("Expired queued work must not start")
            return ProbeTestResults.make()
        }
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        queue.resume()
        await drain(queue)
        XCTAssertEqual(reader.closes.value, 1)
    }

    func testAdmissionStaysHeldThroughAsyncFinalShutdownEvenAfterCancellation() async {
        for cancelWaiter in [false, true] {
            let queue = DispatchQueue(label: "probe.test.shutdown-admission")
            let shutdownGate = ProbeTestAsyncGate()
            let shutdownStarted = expectation(description: "async shutdown entered")
            let earlyNativeCall = expectation(description: "second native call before shutdown")
            earlyNativeCall.isInverted = true
            let secondCalls = ProbeTestCounter()
            let first = Task {
                await PlozzigenStreamProbeExecutor.runDetailProbe(
                    reader: ProbeTestReader(), requirements: .hdr10Plus, queue: queue,
                    finalShutdown: {
                        shutdownStarted.fulfill()
                        await shutdownGate.wait()
                    }
                ) { _, _, _, _, _, _ in ProbeTestResults.make() }
            }
            await fulfillment(of: [shutdownStarted], timeout: 1)
            if cancelWaiter {
                first.cancel()
                let result = await first.value
                XCTAssertNil(result)
            }
            let second = Task {
                await PlozzigenStreamProbeExecutor.runDetailProbe(
                    reader: ProbeTestReader(), requirements: .atmos, queue: queue
                ) { _, _, _, _, _, _ in
                    if !shutdownGate.isOpen { earlyNativeCall.fulfill() }
                    XCTAssertTrue(shutdownGate.isOpen, "Final shutdown is part of real-work admission")
                    secondCalls.increment()
                    return ProbeTestResults.make()
                }
            }
            await fulfillment(of: [earlyNativeCall], timeout: 0.1)
            XCTAssertEqual(secondCalls.value, 0)
            shutdownGate.open()
            let firstResult = await first.value
            XCTAssertEqual(firstResult == nil, cancelWaiter)
            let secondResult = await second.value
            XCTAssertNotNil(secondResult)
            XCTAssertEqual(secondCalls.value, 1)
        }
    }

    func testCombinedPacketPartitionPreservesUsefulAtmosCoverageAndHDRFuseHeadroom() {
        for whole in [1, 7, 8, 15, 16, 32, 64, 127, 128, 256] {
            let packets = PlozzigenStreamProbeExecutor.packetBudgets(
                requirements: [.hdr10Plus, .atmos], wholeProbePackets: whole
            )
            XCTAssertLessThanOrEqual(packets.hdr * 8 + packets.atmos, whole)
            XCTAssertLessThanOrEqual(packets.hdr, 4)
            XCTAssertLessThanOrEqual(packets.atmos, 64)
            if whole >= 128 { XCTAssertEqual(packets.atmos, 64) }
            if whole >= 16 {
                XCTAssertGreaterThan(packets.hdr, 0)
                XCTAssertGreaterThan(packets.atmos, 0)
            }
        }
    }

    func testActiveDeadlineCancelsOwnedIOAndRejectsLatePositive() async {
        let reader = ProbeTestReader()
        let release = DispatchSemaphore(value: 0)
        let cleaned = expectation(description: "native worker cleaned")
        var limits = HDR10PlusProbeLimits()
        limits.wallTimeout = 0.04
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, requirements: .hdr10Plus, limits: limits,
            interrupt: {
                reader.cancel()
                release.signal()
            },
            finalShutdown: { cleaned.fulfill() }
        ) { _, _, _, _, _, cancellation in
            _ = release.wait(timeout: .now() + 1)
            XCTAssertTrue(cancellation.isCancelled)
            return ProbeTestResults.make(carriesHDR10Plus: true)
        }
        XCTAssertNil(result)
        await fulfillment(of: [cleaned], timeout: 1)
        XCTAssertEqual(reader.closes.value, 1)
    }

    private final class ProbeTestAsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isOpen: Bool { lock.withLock { opened } }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock {
                    if opened { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let pending = lock.withLock {
                opened = true
                let pending = waiters
                waiters.removeAll()
                return pending
            }
            pending.forEach { $0.resume() }
        }
    }

    func testInvalidLimitsNeverStartNativeWorkAndStillCleanUp() async {
        let reader = ProbeTestReader()
        let shutdowns = ProbeTestCounter()
        var limits = HDR10PlusProbeLimits()
        limits.wallTimeout = .infinity
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, requirements: .hdr10Plus, limits: limits,
            finalShutdown: { shutdowns.increment() }
        ) { _, _, _, _, _, _ in
            XCTFail("Invalid limits must not enter native code")
            return ProbeTestResults.make()
        }
        XCTAssertNil(result)
        XCTAssertEqual(reader.closes.value, 1)
        XCTAssertEqual(shutdowns.value, 1)
    }

    func testEngineErrorsRemainUnknownWithoutRetryOrSecondOpen() async {
        let reader = ProbeTestReader()
        let calls = ProbeTestCounter()
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, requirements: [.atmos, .hdr10Plus]
        ) { _, _, _, _, _, _ in
            calls.increment()
            throw ProbeError.inputLimit
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(reader.closes.value, 1)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

final class ProbeTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ProbeTestReader: IOReader, @unchecked Sendable {
    let closes = ProbeTestCounter()
    let cancels = ProbeTestCounter()
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
    func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    func close() { closes.increment() }
    func cancel() { cancels.increment() }
}

enum ProbeTestResults {
    static func make(
        format: VideoFormat = .hdr10,
        carriesHDR10Plus: Bool = false,
        audioTracks: [TrackInfo] = []
    ) -> SourceProbe {
        SourceProbe(
            url: URL(string: "aether-custom://source")!,
            durationSeconds: 12, videoFormat: format, videoCodecID: 173,
            videoCodecName: "hevc", videoWidth: 64, videoHeight: 64, videoFrameRate: 24,
            isDolbyVision: format == .dolbyVision,
            carriesHDR10PlusMetadata: carriesHDR10Plus,
            audioTracks: audioTracks, subtitleTracks: []
        )
    }

    static func audio(_ id: Int, isDefault: Bool, isAtmos: Bool) -> TrackInfo {
        TrackInfo(
            id: id, name: "Audio", codec: "eac3", language: "en",
            channels: 6, isDefault: isDefault, isAtmos: isAtmos
        )
    }
}
