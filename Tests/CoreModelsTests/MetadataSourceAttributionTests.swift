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

    func testAppLegalCreditsCoverDiscoveryCatalogs() throws {
        for title in ["TMDB", "TheTVDB", "OMDb & AniList", "TVmaze"] {
            let entry = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == title })
            XCTAssertTrue(entry.detail.contains("Discovery"), title)
            XCTAssertFalse(entry.detail.contains("Featured"), title)
        }
    }

    func testTVmazeAppLegalCreditIncludesSourceAndShareAlikeLicense() throws {
        let entry = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "TVmaze" })
        XCTAssertTrue(entry.detail.contains("https://www.tvmaze.com"))
        XCTAssertTrue(entry.detail.contains("https://creativecommons.org/licenses/by-sa/4.0/"))
        XCTAssertTrue(entry.detail.contains("filters and combines"))
        XCTAssertTrue(entry.licenses.contains { $0.label == "CC BY-SA 4.0" })
    }

    func testAppCreditsCoverEveryExternalMetadataSource() {
        let credits = PlozzAttributions.entries.map { "\($0.title) \($0.detail)" }.joined(separator: "\n")
        for source in MetadataSourceAttribution.all {
            XCTAssertTrue(credits.contains(source.name), "Missing app-wide credit for \(source.name)")
        }
        XCTAssertEqual(
            Set(PlozzAttributions.entries.map(\.id)).count,
            PlozzAttributions.entries.count
        )
    }

    func testMetadataNoticesPreserveDataAndImageLicenseBoundaries() throws {
        let tvmaze = try XCTUnwrap(MetadataSourceAttribution.for(.tvmaze))
        XCTAssertTrue(tvmaze.notice.contains("https://creativecommons.org/licenses/by-sa/4.0/"))
        for source in [MetadataSource.wikidata, .wikipedia] {
            let credit = try XCTUnwrap(MetadataSourceAttribution.for(source))
            XCTAssertTrue(credit.notice.contains("copyright"))
            XCTAssertTrue(credit.notice.contains("license"))
        }
    }
}
