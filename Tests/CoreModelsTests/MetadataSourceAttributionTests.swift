import XCTest
@testable import CoreModels

/// Locks the Step 6 attribution lookup: required credits are present, internal
/// sources have none, and `all` is ordered with required credits first.
final class MetadataSourceAttributionTests: XCTestCase {
    func testRequiredSourcesPresentAndFlagged() {
        let tvdb = MetadataSourceAttribution.for(.tvdb)
        XCTAssertNotNil(tvdb)
        XCTAssertTrue(tvdb?.isRequired == true)
        XCTAssertEqual(tvdb?.name, "TheTVDB")
        XCTAssertFalse(tvdb?.notice.isEmpty ?? true)

        let tmdb = MetadataSourceAttribution.for(.tmdb)
        XCTAssertTrue(tmdb?.isRequired == true)
    }

    func testInternalSourcesHaveNoAttribution() {
        for source in [MetadataSource.server, .filename, .localNFO, .embedded, .localArtwork, .generated, .legacyUnknown] {
            XCTAssertNil(MetadataSourceAttribution.for(source), "\(source.rawValue) should not have third-party attribution")
        }
    }

    func testAllListsExternalSourcesRequiredFirst() {
        let all = MetadataSourceAttribution.all
        XCTAssertFalse(all.isEmpty)
        // TheTVDB + TMDB (the required ones) lead the list.
        XCTAssertEqual(all.first?.source, .tvdb)
        XCTAssertEqual(all[1].source, .tmdb)
        // Every entry has non-empty display copy.
        for entry in all {
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.notice.isEmpty)
        }
    }

    func testKnownExternalSourcesAreCovered() {
        for source in [MetadataSource.anilist, .mal, .tvmaze, .kitsu, .omdb, .wikidata, .wikipedia, .musicbrainz, .deezer] {
            XCTAssertNotNil(MetadataSourceAttribution.for(source), "missing attribution for \(source.rawValue)")
        }
    }

    func testAppLegalCreditsCoverFeaturedDiscoveryCatalogs() throws {
        for title in ["TMDB", "TheTVDB", "OMDb & AniList", "TVmaze"] {
            let entry = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == title })
            XCTAssertTrue(entry.detail.contains("Featured discovery"), title)
        }
    }

    func testTVmazeAppLegalCreditIncludesSourceAndShareAlikeLicense() throws {
        let entry = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "TVmaze" })
        XCTAssertTrue(entry.detail.contains("https://www.tvmaze.com"))
        XCTAssertTrue(entry.detail.contains("https://creativecommons.org/licenses/by-sa/4.0/"))
        XCTAssertTrue(entry.detail.contains("filters and combines"))
        XCTAssertTrue(entry.licenses.contains { $0.label == "CC BY-SA 4.0" })
    }
}
