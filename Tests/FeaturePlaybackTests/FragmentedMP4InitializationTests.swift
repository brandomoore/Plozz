import Foundation
import XCTest
@testable import FeaturePlayback

final class FragmentedMP4InitializationTests: XCTestCase {
    func testRemovesOnlyEmptyDependenciesAndPreservesOtherPayloads() throws {
        let original = MP4InitializationFixture.make()
        let expected = MP4InitializationFixture.make(dependencies: nil)
        XCTAssertEqual(try FragmentedMP4Initialization.removingEmptySampleDependencies(from: original), expected)
        XCTAssertEqual(original.count - expected.count, 12)
    }

    func testHealthyNonfragmentedAndPopulatedTablesAreUnchanged() throws {
        let cases: [Data] = [
            MP4InitializationFixture.make(dependencies: nil),
            MP4InitializationFixture.make(dependencies: Data([0, 0, 0, 0, 1])),
            MP4InitializationFixture.make(dependencies: Data([0, 0, 0, 1])),
            MP4InitializationFixture.make(sampleCount: 1),
            MP4InitializationFixture.make(fragmented: false),
            MP4InitializationFixture.box("free", Data([1, 2, 3]))
        ]
        for data in cases {
            XCTAssertNil(try FragmentedMP4Initialization.removingEmptySampleDependencies(from: data))
        }
    }

    func testExtendedAndToEndContainerSizesRemainValidAndUnchangedSiblingsStayExact() throws {
        for encoding in [MP4InitializationFixture.Length.extended, .toEnd] {
            let original = MP4InitializationFixture.make(length: encoding)
            let expected = MP4InitializationFixture.make(dependencies: nil, length: encoding)
            XCTAssertEqual(try FragmentedMP4Initialization.removingEmptySampleDependencies(from: original), expected)
            XCTAssertNil(try FragmentedMP4Initialization.removingEmptySampleDependencies(from: expected))
        }
    }

    func testMalformedAndOversizedBoxesThrowWithoutReadingPastBounds() {
        let extendedHeader = Data([0, 0, 0, 1]) + Data("moov".utf8)
        let malformedMovie = MP4InitializationFixture.box("ftyp", Data())
            + MP4InitializationFixture.box("moov", Data([1]))
        let cases: [Data] = [
            Data([0, 0, 0]),
            Data([0, 0, 0, 7]) + Data("moov".utf8),
            Data([0, 0, 0, 40]) + Data("moov".utf8),
            extendedHeader,
            extendedHeader + Data(repeating: 255, count: 8),
            malformedMovie,
            Data(repeating: 0, count: 1_048_577)
        ]
        for data in cases {
            XCTAssertThrowsError(try FragmentedMP4Initialization.removingEmptySampleDependencies(from: data))
        }
    }
}

enum MP4InitializationFixture {
    enum Length { case normal, extended, toEnd }

    static func box(_ type: String, _ payload: Data, length: Length = .normal) -> Data {
        let size = UInt64(payload.count + (length == .extended ? 16 : 8))
        func bytes(_ value: UInt64, count: Int) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) })
        }
        let prefix = bytes(length == .extended ? 1 : length == .toEnd ? 0 : size, count: 4)
        return prefix + Data(type.utf8) + (length == .extended ? bytes(size, count: 8) : Data()) + payload
    }

    static func make(
        dependencies: Data? = Data(repeating: 0, count: 4), sampleCount: UInt8 = 0,
        fragmented: Bool = true, length: Length = .normal
    ) -> Data {
        let format = box("stsd", box("hvc1", box("hvcC", Data([1, 2, 3]))
            + box("colr", Data([4, 5, 6])) + box("dvcC", Data([7, 8]))))
        var size = Data(repeating: 0, count: 12)
        size[11] = sampleCount
        let table = format + box("stsz", size) + (dependencies.map { box("sdtp", $0) } ?? Data())
            + box("stts", Data(repeating: 0, count: 8)) + box("free", Data([9, 10, 11]))
        let track = box("trak", box("edts", Data([12, 13]))
            + box("mdia", box("minf", box("stbl", table, length: length), length: length), length: length),
            length: length)
        let unchangedAudio = box("trak", box("mdia", box("minf",
            box("stbl", box("stsd", box("mp4a", Data([14, 15]))), length: .toEnd)), length: .toEnd))
        return box("ftyp", Data("isom".utf8)) + box("moov",
            (fragmented ? box("mvex", Data()) : Data()) + unchangedAudio + track, length: length)
    }
}
