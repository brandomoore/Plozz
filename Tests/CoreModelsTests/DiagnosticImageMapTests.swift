#if DEBUG && canImport(MachO)
import Foundation
import MachO
import XCTest
@testable import CoreModels

final class DiagnosticImageMapTests: XCTestCase {
    func testSnapshotMapsTheCurrentExecutableAndContainsOnlyImageBasenames() throws {
        let snapshot = DiagnosticImageMap.collect(.preparing)
        XCTAssertEqual(snapshot.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(snapshot.phase, "preparing")
        let header = try XCTUnwrap(_dyld_get_image_header(0))
        let address = UInt64(UInt(bitPattern: header))
        let executable = try XCTUnwrap(snapshot.images.first { $0.headerAddress == address })
        XCTAssertTrue(executable.segments.contains { $0.address <= address && address - $0.address < $0.size })
        XCTAssertTrue(snapshot.images.allSatisfy { !($0.name?.contains("/") ?? false) })
        XCTAssertTrue(snapshot.images.allSatisfy { !$0.segments.isEmpty })
        XCTAssertEqual(Set(snapshot.images.map(\.headerAddress)).count, snapshot.images.count)
    }

    func testExportRoundTripsAddressesAndThrowsOnInvalidDestination() throws {
        let snapshot = DiagnosticImageMap.collect(.finished)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove owned diagnostic fixture: \(error)") }
        }
        let file = directory.appendingPathComponent("images.json")
        try DiagnosticImageMap.write(snapshot, to: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DiagnosticImageMap.Snapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(restored.processIdentifier, snapshot.processIdentifier)
        XCTAssertEqual(restored.images.map(\.uuid), snapshot.images.map(\.uuid))
        XCTAssertEqual(restored.images.map(\.headerAddress), snapshot.images.map(\.headerAddress))
        XCTAssertEqual(restored.images.flatMap(\.segments).map(\.address), snapshot.images.flatMap(\.segments).map(\.address))
        XCTAssertThrowsError(try DiagnosticImageMap.write(snapshot, to: file.appendingPathComponent("invalid.json")))
    }

    func testMalformedImageCommandsAreRejected() {
        var header = mach_header_64()
        header.magic = MH_MAGIC_64
        header.ncmds = 1
        header.sizeofcmds = 0
        withUnsafePointer(to: &header) { pointer in
            pointer.withMemoryRebound(to: mach_header.self, capacity: 1) {
                XCTAssertNil(DiagnosticImageMap.image($0, slide: 0))
            }
        }
    }
}
#endif
