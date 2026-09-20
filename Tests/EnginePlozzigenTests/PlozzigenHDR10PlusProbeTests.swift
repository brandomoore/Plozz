import Foundation
import XCTest
@testable import EnginePlozzigen

final class PlozzigenHDR10PlusProbeTests: XCTestCase {
    func testDemuxConfirmsOnlyHEVCVideoSEIAndClosesSource() {
        let packet = HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: 4)
        let (source, budget) = makeSource(matroska(packets: [packet]))
        XCTAssertEqual(PlozzigenHDR10PlusProbe.inspect(source: source, budget: budget), true)
        XCTAssertTrue(source.isClosed)
    }

    func testNonVideoOrNonHEVCTrackCannotConfirm() {
        let packet = HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: 4)
        for (type, codec) in [(2, "A_AAC"), (1, "V_MPEG4/ISO/AVC"), (17, "S_TEXT/UTF8")] {
            let (source, budget) = makeSource(matroska(packets: [packet], type: type, codec: codec))
            XCTAssertNil(PlozzigenHDR10PlusProbe.inspect(source: source, budget: budget))
            XCTAssertTrue(source.isClosed)
        }
    }

    func testOrdinaryHDR10AndOversizedPacketsRemainUnknown() {
        let hdr10 = HDR10PlusTestFixture.nal(type: 137, payload: [UInt8](repeating: 42, count: 24))
        let ordinary = HDR10PlusTestFixture.lengthPrefixed(hdr10, width: 4)
        let (source, budget) = makeSource(matroska(packets: [ordinary]))
        XCTAssertNil(PlozzigenHDR10PlusProbe.inspect(source: source, budget: budget))
        XCTAssertTrue(source.isClosed)

        let hdr10Plus = HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: 4)
        var limits = HDR10PlusProbeLimits()
        limits.packetBytes = hdr10Plus.count - 1
        let (oversized, oversizedBudget) = makeSource(matroska(packets: [hdr10Plus]), limits: limits)
        XCTAssertNil(PlozzigenHDR10PlusProbe.inspect(source: oversized, budget: oversizedBudget))
        XCTAssertTrue(oversized.isClosed)
    }

    func testPacketCapDoesNotInspectLaterPositivePacket() {
        let ordinary = HDR10PlusTestFixture.lengthPrefixed([0x02, 1, 0x80], width: 4)
        let positive = HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: 4)
        var limits = HDR10PlusProbeLimits()
        limits.packets = 3
        let data = matroska(packets: [ordinary, ordinary, ordinary, positive])
        let (source, budget) = makeSource(data, limits: limits)
        XCTAssertNil(PlozzigenHDR10PlusProbe.inspect(source: source, budget: budget))
        XCTAssertTrue(source.isClosed)
        limits.packets = 4
        let (fullSource, fullBudget) = makeSource(data, limits: limits)
        XCTAssertEqual(PlozzigenHDR10PlusProbe.inspect(source: fullSource, budget: fullBudget), true)
    }

    func testMalformedContainerByteExhaustionAndCancellationCloseSource() {
        var limits = HDR10PlusProbeLimits()
        limits.networkBytes = 8
        let (source, budget) = makeSource(Data(repeating: 0, count: 10_000), limits: limits)
        XCTAssertNil(PlozzigenHDR10PlusProbe.inspect(source: source, budget: budget))
        XCTAssertLessThanOrEqual(source.bytesRead, 8)
        XCTAssertTrue(source.isClosed)

        let (cancelled, cancelledBudget) = makeSource(Data(repeating: 0, count: 100))
        cancelledBudget.cancel()
        XCTAssertNil(PlozzigenHDR10PlusProbe.inspect(source: cancelled, budget: cancelledBudget))
        XCTAssertEqual(cancelled.bytesRead, 0)
        XCTAssertTrue(cancelled.isClosed)
    }

    func testBudgetDeadlineUsesMonotonicClockAndRejectsInvalidLimits() async {
        let clock = TestClock()
        var limits = HDR10PlusProbeLimits()
        limits.networkBytes = 10
        let budget = HDR10PlusProbeBudget(limits: limits, now: { clock.now })
        XCTAssertEqual(budget.reserve(upTo: 7), 7)
        XCTAssertEqual(budget.reserve(upTo: 7), 3)
        XCTAssertEqual(budget.reserve(upTo: 7), 0)
        clock.advance(5)
        XCTAssertFalse(budget.isActive)
        XCTAssertEqual(budget.reserve(upTo: 1), 0)
        limits.wallTimeout = .infinity
        let invalid = await HDR10PlusProbeExecutor.run(limits: limits) { _ in
            XCTFail("Invalid limits must not start work")
            return true
        }
        XCTAssertNil(invalid)
    }

    func testQueuedCancellationNeverStartsBlockingWork() async {
        let queue = DispatchQueue(label: "hdr10plus.test.queued")
        queue.suspend()
        let starts = TestClock()
        let task = Task {
            await HDR10PlusProbeExecutor.run(queue: queue) { _ in
                starts.advance(1)
                return true
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        queue.resume()
        queue.sync {}
        XCTAssertEqual(starts.now, 0)
    }

    func testWallDeadlineIncludesQueueWaitAndReturnsOnlyPositiveOrUnknown() async {
        let queue = DispatchQueue(label: "hdr10plus.test.deadline")
        queue.suspend()
        var limits = HDR10PlusProbeLimits()
        limits.wallTimeout = 0.04
        let starts = TestClock()
        let started = ProcessInfo.processInfo.systemUptime
        let result = await HDR10PlusProbeExecutor.run(limits: limits, queue: queue) { _ in
            starts.advance(1)
            return true
        }
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        queue.resume()
        queue.sync {}
        XCTAssertEqual(starts.now, 0)
        let negative = await HDR10PlusProbeExecutor.run { _ in false }
        let positive = await HDR10PlusProbeExecutor.run { _ in true }
        XCTAssertNil(negative)
        XCTAssertEqual(positive, true)
    }

    func testActiveDeadlineCancelsIOAndAllowsWorkerCleanup() async {
        var limits = HDR10PlusProbeLimits()
        limits.wallTimeout = 0.04
        let closed = expectation(description: "Worker released blocked source")
        let gate = DispatchSemaphore(value: 0)
        let result = await HDR10PlusProbeExecutor.run(limits: limits) { budget in
            budget.onCancellation { gate.signal() }
            _ = gate.wait(timeout: .now() + 1)
            closed.fulfill()
            return true
        }
        XCTAssertNil(result)
        await fulfillment(of: [closed], timeout: 1)
    }

    func testAVIOSeeksCannotOverflowOrReadAfterCancellation() {
        let (source, budget) = makeSource(Data(repeating: 1, count: 32))
        defer { source.close() }
        let reader = HDR10PlusAVIOReader(source: source, budget: budget)
        XCTAssertEqual(reader.seek(offset: 0, whence: 65_536), 32)
        XCTAssertEqual(reader.seek(offset: -1, whence: SEEK_END), 31)
        XCTAssertEqual(reader.seek(offset: Int64.max, whence: SEEK_CUR), -1)
        XCTAssertEqual(reader.seek(offset: -1, whence: SEEK_SET), -1)
        budget.cancel()
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_SET), -1)
    }

    private func makeSource(
        _ bytes: Data, limits: HDR10PlusProbeLimits = HDR10PlusProbeLimits()
    ) -> (HDR10PlusMemorySource, HDR10PlusProbeBudget) {
        let budget = HDR10PlusProbeBudget(limits: limits)
        return (HDR10PlusMemorySource(bytes: bytes, budget: budget), budget)
    }

    /// Small, generated Matroska container: no binary fixture or media download.
    /// Codec identity and packet boundaries must come from the demuxer, not a
    /// search for a marker anywhere in the container.
    private func matroska(packets: [Data], type: Int = 1, codec: String = "V_MPEGH/ISO/HEVC") -> Data {
        func element(_ id: [UInt8], _ value: Data) -> Data {
            let size = value.count
            let width = (1...8).first { size < (1 << (7 * $0)) - 1 }!
            var encoded = (0..<width).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }
            encoded[0] |= UInt8(1 << (8 - width))
            return Data(id + encoded) + value
        }
        func integer(_ id: [UInt8], _ value: Int) -> Data { element(id, Data([UInt8(value)])) }
        let ebml = integer([0x42, 0x86], 1) + integer([0x42, 0xf7], 1)
            + integer([0x42, 0xf2], 4) + integer([0x42, 0xf3], 8)
            + element([0x42, 0x82], Data("matroska".utf8))
            + integer([0x42, 0x87], 4) + integer([0x42, 0x85], 2)
        let video = integer([0xb0], 16) + integer([0xba], 16)
        let track = integer([0xd7], 1) + integer([0x73, 0xc5], 1) + integer([0x83], type)
            + element([0x86], Data(codec.utf8))
            + element([0x63, 0xa2], HDR10PlusTestFixture.hvcc())
            + element([0xe0], video)
        let tracks = element([0x16, 0x54, 0xae, 0x6b], element([0xae], track))
        var cluster = integer([0xe7], 0)
        for packet in packets {
            cluster += element([0xa3], Data([0x81, 0, 0, 0x80]) + packet)
        }
        let info = element([0x15, 0x49, 0xa9, 0x66],
                           element([0x2a, 0xd7, 0xb1], Data([0x0f, 0x42, 0x40])))
        let segment = info + tracks + element([0x1f, 0x43, 0xb6, 0x75], cluster)
        return element([0x1a, 0x45, 0xdf, 0xa3], ebml) + element([0x18, 0x53, 0x80, 0x67], segment)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class HDR10PlusMemorySource: HDR10PlusRangeSource, @unchecked Sendable {
    let bytes: Data
    let budget: HDR10PlusProbeBudget
    private let lock = NSLock()
    private var closed = false
    private var readCount = 0
    var size: Int64? { Int64(bytes.count) }
    var bytesRead: Int { lock.withLock { readCount } }
    var isClosed: Bool { lock.withLock { closed } }

    init(bytes: Data, budget: HDR10PlusProbeBudget) {
        self.bytes = bytes
        self.budget = budget
    }

    func read(at offset: Int64, count: Int) -> Data? {
        lock.withLock {
            guard !closed, budget.isActive, offset >= 0 else { return nil }
            guard offset < bytes.count else { return Data() }
            let allowed = budget.reserve(upTo: min(count, bytes.count - Int(offset)))
            guard allowed > 0 else { return nil }
            readCount += allowed
            return bytes.subdata(in: Int(offset)..<(Int(offset) + allowed))
        }
    }

    func close() { lock.withLock { closed = true } }
}
