import CoreModels
import XCTest
@testable import CoreUI

final class CollectionCoverArtworkTests: XCTestCase {
    private actor Requests {
        var ids: [String] = []
        func measure(_ item: MediaItem) -> Double? {
            ids.append(item.id)
            return item.id == "missing" ? nil : 16.0 / 9
        }

    }

    func testMissingServerDimensionsUseOnlyTheBoundedInitialCoverSample() async throws {
        let requests = Requests()
        let items = (0..<30).map { MediaItem(id: "\($0)", title: "Collection", kind: .collection) }
        let prepared = try await CollectionCoverArtwork.preparing(items) { await requests.measure($0) }
        let ids = await requests.ids
        XCTAssertEqual(Set(ids), Set((0..<9).map(String.init)))
        XCTAssertEqual(prepared.map(\.id), items.map(\.id))
        XCTAssertEqual(prepared.prefix(9).compactMap(\.primaryImageAspectRatio).count, 9)
        XCTAssertTrue(prepared.dropFirst(9).allSatisfy { $0.primaryImageAspectRatio == nil })
        XCTAssertEqual(CollectionCoverLayout.auto.style(for: prepared), .landscape)
    }

    func testKnownDimensionsAndMixedMediaDoNotStartArtworkRequests() async throws {
        let requests = Requests()
        let item = MediaItem(id: "known", title: "Collection", kind: .collection, primaryImageAspectRatio: 2.0 / 3)
        let known = try await CollectionCoverArtwork.preparing([item]) { await requests.measure($0) }
        let mixed = [item, MediaItem(id: "movie", title: "Movie", kind: .movie)]
        let untouched = try await CollectionCoverArtwork.preparing(mixed) { await requests.measure($0) }
        XCTAssertEqual(known, [item])
        XCTAssertEqual(untouched, mixed)
        let ids = await requests.ids
        XCTAssertTrue(ids.isEmpty)
    }

    func testMissingArtworkRemainsUnknownAndCancellationCannotPublishAGroup() async throws {
        let requests = Requests()
        let items = [MediaItem(id: "missing", title: "Collection", kind: .collection)]
        let prepared = try await CollectionCoverArtwork.preparing(items) { await requests.measure($0) }
        XCTAssertNil(prepared.first?.primaryImageAspectRatio)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CollectionCoverArtwork.preparing(items) { await requests.measure($0) }
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled layout work must not publish")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLandscapeCollectionUsesWidePrimaryBeforeBackgroundWithoutChangingMoviePolicy() {
        let cover = URL(string: "https://art.example/cover")!
        let backdrop = URL(string: "https://art.example/backdrop")!
        var item = MediaItem(
            id: "collection", title: "Collection", kind: .collection,
            posterURL: cover, primaryImageAspectRatio: 16.0 / 9, backdropURL: backdrop
        )
        XCTAssertEqual(CardArtworkPolicy.standard.references(for: item, style: .landscape).first, .remote(cover))
        item.primaryImageAspectRatio = 2.0 / 3
        XCTAssertEqual(CardArtworkPolicy.standard.references(for: item, style: .landscape).first, .remote(backdrop))
        item.kind = .movie
        item.primaryImageAspectRatio = 16.0 / 9
        XCTAssertEqual(CardArtworkPolicy.standard.references(for: item, style: .landscape).first, .remote(backdrop))
    }
}
