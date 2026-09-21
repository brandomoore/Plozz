import Foundation
import XCTest
import AetherEngine
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenHDR10PlusProbeTests: XCTestCase {
    func testCombinedProbeKeepsDecodingPastTwelveNonJOCAudioPackets() async throws {
        let bytes = HDR10PlusTestFixture.interleavedHDR10PlusWithJOCOnAudioPacket13
        let (headerReader, headerSource, headerBudget) = makeReader(bytes)
        let headerResult = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: headerReader, formatHint: "matroska",
            requirements: .streamDetails, budget: headerBudget
        )
        let header = try XCTUnwrap(headerResult)
        XCTAssertEqual(header.videoFormat, .hdr10)
        XCTAssertFalse(header.carriesHDR10PlusMetadata)
        let unresolvedAudio = try XCTUnwrap(header.audioTracks.first { $0.isDefault })
        XCTAssertEqual(unresolvedAudio.codec, "eac3")
        XCTAssertFalse(unresolvedAudio.isAtmos)
        XCTAssertTrue(headerSource.isClosed)

        let (reader, source, budget) = makeReader(bytes)
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, formatHint: "matroska",
            requirements: [.hdr10Plus, .atmos], budget: budget
        )
        let probe = try XCTUnwrap(result)
        XCTAssertTrue(probe.carriesHDR10PlusMetadata)
        XCTAssertEqual(probe.videoFormat, .hdr10Plus)
        let confirmedAudio = try XCTUnwrap(probe.audioTracks.first { $0.isDefault })
        XCTAssertEqual(confirmedAudio.id, unresolvedAudio.id)
        XCTAssertTrue(confirmedAudio.isAtmos, "JOC on packet 13 must not be cut off by a 12-frame allocation")
        XCTAssertTrue(source.isClosed)
        XCTAssertLessThanOrEqual(source.bytesRead, 8 * 1024 * 1024)
    }

    func testInconclusiveHDRScanCannotStarveRealInterleavedJOCConfirmation() async throws {
        let bytes = HDR10PlusTestFixture.interleavedHDR10WithLateJOC
        let (headerReader, headerSource, headerBudget) = makeReader(bytes)
        let headerResult = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: headerReader, formatHint: "matroska",
            requirements: .streamDetails, budget: headerBudget
        )
        let header = try XCTUnwrap(headerResult)
        XCTAssertEqual(header.videoFormat, .hdr10)
        let unresolvedAudio = try XCTUnwrap(header.audioTracks.first { $0.isDefault })
        XCTAssertEqual(unresolvedAudio.codec, "eac3")
        XCTAssertFalse(unresolvedAudio.isAtmos, "Fixture must require the explicit Atmos decode pass")
        XCTAssertTrue(headerSource.isClosed)

        let (reader, source, budget) = makeReader(bytes)
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, formatHint: "matroska",
            requirements: [.hdr10Plus, .atmos], budget: budget
        )
        let probe = try XCTUnwrap(result, "Ordinary HDR10 must not consume Atmos's whole-probe headroom")
        XCTAssertFalse(probe.carriesHDR10PlusMetadata)
        XCTAssertEqual(probe.videoFormat, .hdr10)
        XCTAssertEqual(probe.videoWidth, 64)
        let confirmedAudio = try XCTUnwrap(probe.audioTracks.first { $0.isDefault })
        XCTAssertEqual(confirmedAudio.id, unresolvedAudio.id)
        XCTAssertEqual(confirmedAudio.codec, "eac3")
        XCTAssertTrue(confirmedAudio.isAtmos, "The actual EAC3 decoder must confirm the synthetic JOC flag")
        XCTAssertTrue(source.isClosed)
        XCTAssertLessThanOrEqual(source.bytesRead, 8 * 1024 * 1024)
    }

    func testPublicCombinedProbeUsesSyntheticPositiveAndNegativeFixtures() async throws {
        for requirements: SupplementalStreamProbeRequirements in [.hdr10Plus, [.hdr10Plus, .atmos]] {
            let (reader, source, budget) = makeReader(HDR10PlusTestFixture.positive)
            let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: reader, formatHint: "mp4", requirements: requirements, budget: budget
            )
            let probe = try XCTUnwrap(result)
            XCTAssertTrue(probe.carriesHDR10PlusMetadata)
            XCTAssertEqual(probe.videoFormat, .hdr10Plus)
            XCTAssertEqual(probe.videoWidth, 64)
            XCTAssertTrue(source.isClosed)
        }
        for (data, requirements) in [
            (HDR10PlusTestFixture.plain, SupplementalStreamProbeRequirements.hdr10Plus),
            (HDR10PlusTestFixture.positive, SupplementalStreamProbeRequirements.atmos)
        ] {
            let (reader, source, budget) = makeReader(data)
            let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: reader, formatHint: "mp4", requirements: requirements, budget: budget
            )
            let probe = try XCTUnwrap(result)
            XCTAssertFalse(probe.carriesHDR10PlusMetadata)
            XCTAssertEqual(probe.videoFormat, .hdr10)
            XCTAssertTrue(source.isClosed)
        }
    }

    func testEngineInputAndPacketInspectionLimitsCannotPublishLatePositive() async {
        for kind in 0..<3 {
            var limits = HDR10PlusProbeLimits()
            switch kind {
            case 0: limits.networkBytes = 8
            case 1: limits.packetBytes = 1
            default: limits.packets = 1
            }
            let bytes = kind == 2 ? HDR10PlusTestFixture.plain : HDR10PlusTestFixture.positive
            let (reader, source, budget) = makeReader(bytes, limits: limits)
            let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
                reader: reader, formatHint: "mp4", requirements: .hdr10Plus,
                limits: limits, budget: budget
            )
            if kind == 2 {
                // Reaching the per-pass packet cap is unknown, not a negative.
                XCTAssertEqual(result?.carriesHDR10PlusMetadata, false)
            } else {
                XCTAssertNil(result)
            }
            XCTAssertLessThanOrEqual(source.bytesRead, limits.networkBytes)
            XCTAssertTrue(source.isClosed)
        }
    }

    func testMalformedInputClosesSource() async {
        let (reader, source, budget) = makeReader(Data(repeating: 0, count: 100))
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, requirements: .hdr10Plus, budget: budget
        )
        XCTAssertNil(result)
        XCTAssertTrue(source.isClosed)
    }

    func testBudgetUsesMonotonicClockAndNeverResetsAcrossReads() {
        let clock = ProbeTestClock()
        var limits = HDR10PlusProbeLimits()
        limits.networkBytes = 10
        let budget = HDR10PlusProbeBudget(limits: limits, now: { clock.now })
        XCTAssertEqual(budget.reserve(upTo: 7), 7)
        XCTAssertEqual(budget.reserve(upTo: 7), 3)
        XCTAssertEqual(budget.reserve(upTo: 7), 0)
        clock.advance(5)
        XCTAssertFalse(budget.isActive)
        XCTAssertEqual(budget.reserve(upTo: 1), 0)
    }

    func testReaderSeeksCannotOverflowOrReadAfterCancellation() {
        let (reader, source, _) = makeReader(Data(repeating: 1, count: 32))
        XCTAssertFalse(reader.discImageProbeEnabled)
        XCTAssertEqual(reader.seek(offset: 0, whence: 65_536), 32)
        XCTAssertEqual(reader.seek(offset: -1, whence: SEEK_END), 31)
        XCTAssertEqual(reader.seek(offset: Int64.max, whence: SEEK_CUR), -1)
        XCTAssertEqual(reader.seek(offset: -1, whence: SEEK_SET), -1)
        reader.cancel()
        XCTAssertEqual(reader.seek(offset: 0, whence: SEEK_SET), -1)
        var byte: UInt8 = 0
        XCTAssertEqual(reader.read(&byte, size: 1), -1)
        XCTAssertTrue(source.isClosed)
    }

    func testFailedTransportCannotPublishBufferedPositive() async {
        let (reader, _, budget) = makeReader(Data())
        let result = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: reader, requirements: .hdr10Plus, budget: budget
        ) { _, _, _, _, _, _ in
            // Model a recovered demuxer that still has a positive buffered packet.
            budget.cancel()
            return ProbeTestResults.make(carriesHDR10Plus: true)
        }
        XCTAssertNil(result)
    }

    private func makeReader(
        _ bytes: Data, limits: HDR10PlusProbeLimits = .init()
    ) -> (HDR10PlusAVIOReader, HDR10PlusMemorySource, HDR10PlusProbeBudget) {
        let budget = HDR10PlusProbeBudget(limits: limits)
        let source = HDR10PlusMemorySource(bytes: bytes, budget: budget)
        return (HDR10PlusAVIOReader(source: source, budget: budget), source, budget)
    }
}

private final class ProbeTestClock: @unchecked Sendable {
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
