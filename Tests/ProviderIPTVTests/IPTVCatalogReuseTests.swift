import CoreModels
import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVCatalogReuseTests: XCTestCase {
    func testRepeatedImportsPreserveFirstParentAndClearPriorBindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 3, count: 32)
        let url = root.appendingPathComponent("catalog.sqlite")
        do {
            let catalog = try IPTVCatalog(url: url, key: key)
            for generation in 0..<3 {
                try catalog.beginImport()
                let original = IPTVRecord(
                    item: MediaItem(id: "series:one", title: "Original \(generation)", kind: .series, libraryID: "series"),
                    streamURL: URL(string: "https://provider.test/first")
                )
                var duplicate = original
                duplicate.item.title = "Ignored"
                try catalog.insert(original, overwrite: false, into: .incoming)
                for _ in 0..<20 { try catalog.insert(duplicate, overwrite: false, into: .incoming) }
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: "live:one", title: "Old", kind: .video, libraryID: "live"),
                    parentID: "old-parent", streamURL: URL(string: "https://provider.test/old"), isLive: true
                ), into: .incoming)
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: "live:one", title: "New", kind: .video, libraryID: "live"), isLive: true
                ), into: .incoming)
                try catalog.commitImport(library: nil, scope: "playlist")
                catalog.discardImport()
                XCTAssertEqual(try catalog.count(where: "1 = 1"), 2)
                XCTAssertEqual(try catalog.record("series:one").item.title, "Original \(generation)")
                let live = try catalog.record("live:one")
                XCTAssertEqual(live.item.title, "New")
                XCTAssertNil(live.parentID)
                XCTAssertNil(live.streamURL)
            }
        }
        let reopened = try IPTVCatalog(url: url, key: key)
        XCTAssertEqual(try reopened.count(where: "1 = 1"), 2)
        XCTAssertEqual(try reopened.record("series:one").item.title, "Original 2")
    }
}
