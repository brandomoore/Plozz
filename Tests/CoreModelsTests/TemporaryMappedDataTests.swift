import CoreModels
import Foundation
import XCTest

final class TemporaryMappedDataTests: XCTestCase {
    func testChunkedWriterPreservesBytesAfterClosingAndLeavesNoNamedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try TemporaryMappedData.Writer(maximumBytes: 6, in: directory)
        try writer.append(Data("abc".utf8))
        try writer.append(Data("def".utf8))
        XCTAssertEqual(writer.count, 6)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let mapped = try writer.finish()
        XCTAssertEqual(mapped, Data("abcdef".utf8))
        XCTAssertThrowsError(try writer.append(Data("g".utf8)))
        XCTAssertThrowsError(try writer.finish())
        XCTAssertEqual(mapped, Data("abcdef".utf8), "A finished writer cannot mutate its immutable mapping.")
    }

    func testRejectedChunkDoesNotExtendWriterPastBudget() throws {
        let writer = try TemporaryMappedData.Writer(maximumBytes: 3)
        try writer.append(Data("ab".utf8))
        XCTAssertThrowsError(try writer.append(Data("cd".utf8)))
        XCTAssertEqual(writer.count, 2)
        XCTAssertEqual(try writer.finish(), Data("ab".utf8))
        XCTAssertEqual(try TemporaryMappedData.store(Data()), Data())
    }
}
