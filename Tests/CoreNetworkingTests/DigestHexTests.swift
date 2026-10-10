import CoreNetworking
import CryptoKit
import Foundation
import XCTest

final class DigestHexTests: XCTestCase {
    func testEveryByteMatchesLegacyLowercaseFormatting() {
        let bytes = Array(UInt8.min...UInt8.max)
        XCTAssertEqual(DigestHex.encode(bytes), bytes.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(DigestHex.encode([0, 1, 15, 16, 255]), "00010f10ff")
        XCTAssertEqual(DigestHex.encode([UInt8]()), "")
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(
            DigestHex.encode(SHA256.hash(data: Data())),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            DigestHex.encode(SHA256.hash(data: Data("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
