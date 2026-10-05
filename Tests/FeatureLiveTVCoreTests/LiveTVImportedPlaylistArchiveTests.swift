import CoreModels
import CryptoKit
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVImportedPlaylistArchiveTests: XCTestCase {
    func testChunkedArchiveRestoresRelativeURLsAndRejectsTruncation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.sealed")
        let key = SymmetricKey(size: .bits256)
        let chunks = [
            Data("#EXTM3U\n#EXTINF:-1,First\nlive/first\n".utf8),
            Data("#EXTINF:-1,Last\nlive/last\n".utf8)
        ]
        var index = 0
        let result = try LiveTVImportedPlaylistArchive.write(
            to: file, key: key, context: "fixture", baseURL: URL(string: "https://example.test/")
        ) {
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            return chunks[index]
        }
        XCTAssertEqual(result.channels.count, 2)
        var restored = Data()
        try LiveTVImportedPlaylistArchive.read(from: file, key: key, context: "fixture") { data, base in
            XCTAssertEqual(base?.absoluteString, "https://example.test/")
            restored.append(data)
        }
        XCTAssertEqual(restored, chunks.reduce(Data(), +))
        let sealed = try Data(contentsOf: file)
        XCTAssertNil(sealed.range(of: chunks[0]))
        XCTAssertThrowsError(try LiveTVImportedPlaylistArchive.read(
            from: file, key: key, context: "another-source", consume: { _, _ in }
        ))
        try sealed.dropLast(1).write(to: file)
        XCTAssertThrowsError(try LiveTVImportedPlaylistArchive.read(
            from: file, key: key, context: "fixture", consume: { _, _ in }
        ))
    }

    func testLegacyArchiveRemainsReadableAndFailedReplacementKeepsOriginal() throws {
        struct Legacy: Codable { let data: Data; let baseURL: URL? }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.sealed")
        let key = SymmetricKey(size: .bits256)
        let data = Data("#EXTM3U\n#EXTINF:-1,Fixture\nhttps://example.test/live\n".utf8)
        let legacy = try AES.GCM.seal(
            JSONEncoder().encode(Legacy(data: data, baseURL: nil)),
            using: key, authenticating: Data("fixture".utf8)
        )
        let original = try XCTUnwrap(legacy.combined)
        try original.write(to: file)
        var restored = Data()
        try LiveTVImportedPlaylistArchive.read(from: file, key: key, context: "fixture") { bytes, _ in
            restored.append(bytes)
        }
        XCTAssertEqual(restored, data)
        XCTAssertThrowsError(try LiveTVImportedPlaylistArchive.write(
            to: file, key: key, context: "fixture", baseURL: nil, next: { nil }
        ))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
