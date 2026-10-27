import XCTest
@testable import CoreModels

final class CollectionCoverLayoutTests: XCTestCase {
    private func covers(_ ratios: [Double?]) -> [MediaItem] {
        ratios.enumerated().map {
            MediaItem(id: "\($0.offset)", title: "Collection", kind: .collection, primaryImageAspectRatio: $0.element)
        }
    }

    func testAutoUsesOneMajorityShapeWithConservativeMixedAndUnknownFallbacks() {
        for (ratios, expected) in [
            ([16.0 / 9, 16.0 / 9, nil], LibrarySection.Style.landscape),
            ([2.0 / 3, 16.0 / 9], .poster),
            ([1, 1, 16.0 / 9], .poster),
            ([nil, nil], .poster),
            ([0, -1, .nan, .infinity], .poster),
            ([1.33], .landscape),
            ([1.32], .poster),
            ([], .poster)
        ] as [([Double?], LibrarySection.Style)] {
            XCTAssertEqual(CollectionCoverLayout.auto.style(for: covers(ratios)), expected)
        }
        let bounded = covers(Array(repeating: 16.0 / 9, count: 9) + Array(repeating: 2.0 / 3, count: 100))
        XCTAssertEqual(CollectionCoverLayout.auto.style(for: bounded), .landscape)
        XCTAssertEqual(CollectionCoverLayout.poster.style(for: bounded), .poster)
        XCTAssertEqual(CollectionCoverLayout.landscape.style(for: covers([nil])), .landscape)
    }

    func testCollectionCoverResolutionDoesNotChangeMemberRowsOrProviderIdentity() {
        let items = covers([16.0 / 9, 16.0 / 9])
        let section = LibrarySection(id: "recent", title: "Recently Added", items: items)
        XCTAssertEqual(section.resolvingCollectionCovers().style, .landscape)
        XCTAssertEqual(section.resolvingCollectionCovers().items, items)
        for kind: MediaItemKind in [.movie, .series, .episode, .playlist, .folder] {
            var member = items[0]
            member.kind = kind
            let row = LibrarySection(id: "row", title: "Row", items: [member])
            XCTAssertEqual(row.resolvingCollectionCovers(.landscape), row)
            let mixed = LibrarySection(id: "mixed", title: "Mixed", items: [items[0], member])
            XCTAssertEqual(mixed.resolvingCollectionCovers(.landscape), mixed)
        }
    }

    func testCoverRatioSurvivesCacheRoundTripAndOlderItemsRemainCompatible() throws {
        let item = try XCTUnwrap(covers([16.0 / 9]).first)
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).primaryImageAspectRatio, 16.0 / 9)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        body.removeValue(forKey: "primaryImageAspectRatio")
        let old = try JSONSerialization.data(withJSONObject: body)
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: old).primaryImageAspectRatio)
    }
}
