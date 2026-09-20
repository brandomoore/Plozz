import Foundation
import XCTest
@testable import EnginePlozzigen

final class HDR10PlusHEVCParserTests: XCTestCase {
    func testKnownMetadataInPrefixAndSuffixAnnexBSEI() {
        for suffix in [false, true] {
            for startCode in [[UInt8](arrayLiteral: 0, 0, 1), [0, 0, 0, 1]] {
                XCTAssertTrue(contains(Data(startCode + HDR10PlusTestFixture.nal(suffix: suffix))))
            }
        }
    }

    func testEveryHVCCLengthSizeIsHonoredWithoutAnnexBFallback() {
        for width in 1...4 {
            let packet = HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: width)
            XCTAssertTrue(contains(packet, configuration: HDR10PlusTestFixture.hvcc(width: width)))
            XCTAssertFalse(contains(packet, configuration: HDR10PlusTestFixture.hvcc(width: width % 4 + 1)))
            XCTAssertFalse(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal()),
                                    configuration: HDR10PlusTestFixture.hvcc(width: width)))
        }
        XCTAssertFalse(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal()), configuration: Data([1])))
        var truncatedArrays = HDR10PlusTestFixture.hvcc()
        truncatedArrays[22] = 1
        XCTAssertFalse(contains(HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: 4),
                                configuration: truncatedArrays))
    }

    func testOrdinaryHDR10AndUnrelatedNALMarkersAreNotEvidence() {
        let marker = HDR10PlusTestFixture.registeredPayload
        XCTAssertFalse(contains(Data([0, 0, 1, 0x02, 1] + marker)))
        XCTAssertFalse(contains(Data(marker)))
        XCTAssertFalse(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal(type: 5))))
        let masteringDisplay = [UInt8](repeating: 42, count: 24)
        XCTAssertFalse(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal(type: 137, payload: masteringDisplay))))
    }

    func testProviderApplicationAndVersionMustMatch() {
        for index in 0..<7 {
            var mismatch = HDR10PlusTestFixture.registeredPayload
            mismatch[index] = 0x7f
            XCTAssertFalse(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal(payload: mismatch))))
        }
        for version: UInt8 in [0, 1] {
            var valid = HDR10PlusTestFixture.registeredPayload
            valid[6] = version
            XCTAssertTrue(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal(payload: valid))))
        }
    }

    func testTruncatedNALSEIAndMetadataNeverConfirm() {
        let valid = [UInt8](HDR10PlusTestFixture.lengthPrefixed(HDR10PlusTestFixture.nal(), width: 4))
        for length in 0..<valid.count {
            XCTAssertFalse(contains(Data(valid.prefix(length)), configuration: HDR10PlusTestFixture.hvcc()))
        }
        for length in 0..<HDR10PlusTestFixture.registeredPayload.count {
            let payload = Array(HDR10PlusTestFixture.registeredPayload.prefix(length))
            XCTAssertFalse(contains(Data([0, 0, 1] + HDR10PlusTestFixture.nal(payload: payload))))
        }
        XCTAssertFalse(contains(Data([0xff, 0xff, 0xff, 0xff, 0x4e, 1]),
                                configuration: HDR10PlusTestFixture.hvcc()))
        XCTAssertFalse(contains(Data(valid + [0, 0, 0, 100, 0x4e, 1]),
                                configuration: HDR10PlusTestFixture.hvcc()))
        XCTAssertFalse(contains(Data([0, 0, 1, 0x4e, 1, 4, 0xff])))
        XCTAssertFalse(contains(Data([0, 0, 1, 0x4e, 1, 0xff])))
    }

    func testEscapedRBSPAndMalformedEmulationPrevention() {
        let valid = HDR10PlusTestFixture.nal()
        XCTAssertTrue(valid.windows(ofCount: 3).contains([0, 0, 3]))
        XCTAssertTrue(contains(Data([0, 0, 1] + valid)))
        for bad: [UInt8] in [[0, 0, 3], [0, 0, 3, 4], [0, 0, 2]] {
            let nal = [UInt8](arrayLiteral: 0x4e, 1) + bad + [0x80]
            XCTAssertFalse(contains(HDR10PlusTestFixture.lengthPrefixed(nal, width: 4),
                                    configuration: HDR10PlusTestFixture.hvcc()))
        }
    }

    func testInvalidHeadersTrailingBytesAndCancelledParserAreUnknown() {
        var nal = HDR10PlusTestFixture.nal()
        nal[0] |= 0x80
        XCTAssertFalse(contains(Data([0, 0, 1] + nal)))
        nal = HDR10PlusTestFixture.nal()
        nal[1] = 0
        XCTAssertFalse(contains(Data([0, 0, 1] + nal)))
        nal = HDR10PlusTestFixture.nal() + [0x12]
        XCTAssertFalse(contains(Data([0, 0, 1] + nal)))
        XCTAssertFalse(HDR10PlusHEVCParser.containsHDR10Plus(
            in: Data([0, 0, 1] + HDR10PlusTestFixture.nal()),
            configuration: nil, isActive: { false }, validate: { _ in true }
        ))
    }

    func testMultipleMessagesAndExtendedSEIFields() {
        let other = HDR10PlusTestFixture.sei(type: 260, payload: [9])
        let hdr = HDR10PlusTestFixture.sei(type: 4, payload: HDR10PlusTestFixture.registeredPayload)
        let rbsp = other + hdr + [0x80]
        let nal = [UInt8](arrayLiteral: 0x4e, 1) + HDR10PlusTestFixture.escape(rbsp)
        XCTAssertTrue(contains(Data([0, 0, 1] + nal)))
        let largeUnregistered = HDR10PlusTestFixture.sei(type: 5, payload: [UInt8](repeating: 5, count: 260))
        XCTAssertTrue(contains(Data([0, 0, 1, 0x4e, 1]
            + HDR10PlusTestFixture.escape(largeUnregistered + hdr + [0x80]))))
    }

    private func contains(_ packet: Data, configuration: Data? = nil) -> Bool {
        HDR10PlusHEVCParser.containsHDR10Plus(
            in: packet, configuration: configuration, validate: PlozzigenHDR10PlusProbe.validateMetadata
        )
    }
}

enum HDR10PlusTestFixture {
    static var registeredPayload: [UInt8] {
        var bits: [UInt8] = []
        func append(_ value: Int, _ width: Int) {
            for shift in (0..<width).reversed() { bits.append(UInt8((value >> shift) & 1)) }
        }
        append(1, 8) // application_version
        append(1, 2) // num_windows
        append(4_000_000, 27)
        append(0, 1) // targeted_system_display_actual_peak_luminance_flag
        for _ in 0..<3 { append(50_000, 17) }
        append(20_000, 17) // average_maxrgb
        append(0, 4) // num_distribution_maxrgb_percentiles
        append(0, 10) // fraction_bright_pixels
        append(0, 1) // mastering_display_actual_peak_luminance_flag
        append(0, 1) // tone_mapping_flag
        append(0, 1) // color_saturation_mapping_flag
        while bits.count % 8 != 0 { bits.append(0) }
        let body = stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<(start + 8)].reduce(UInt8(0)) { ($0 << 1) | $1 }
        }
        return [0xb5, 0, 0x3c, 0, 1, 4] + body
    }

    static func nal(suffix: Bool = false, type: Int = 4, payload: [UInt8] = registeredPayload) -> [UInt8] {
        [suffix ? 0x50 : 0x4e, 1] + escape(sei(type: type, payload: payload) + [0x80])
    }

    static func sei(type: Int, payload: [UInt8]) -> [UInt8] {
        func extended(_ value: Int) -> [UInt8] {
            [UInt8](repeating: 255, count: value / 255) + [UInt8(value % 255)]
        }
        return extended(type) + extended(payload.count) + payload
    }

    static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                output.append(3)
                zeros = 0
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    static func hvcc(width: Int = 4) -> Data {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[21] = 0xfc | UInt8(width - 1)
        return Data(bytes)
    }

    static func lengthPrefixed(_ nal: [UInt8], width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: nal.count >> ($0 * 8)) } + nal)
    }
}

private extension Array where Element == UInt8 {
    func windows(ofCount count: Int) -> [[UInt8]] {
        guard self.count >= count else { return [] }
        return (0...(self.count - count)).map { Array(self[$0..<($0 + count)]) }
    }
}
