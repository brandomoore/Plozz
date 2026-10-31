import Foundation
import XCTest
@testable import CoreModels

final class SettingsSearchTests: XCTestCase {
    private let index = SettingsSearchIndex(
        entries: SettingsSearchCatalog.entries, locale: Locale(identifier: "en_US")
    )

    func testPlainLanguageAndPlayerTerminologyFindEquivalentControls() {
        let queries = [
            "make subtitles bigger": "subtitle-size",
            "captions hard to read": "subtitle-size",
            "streaming cache": "read-ahead",
            "landscape lock": "player-orientation",
            "background playback": "background-audio",
            "forward skip": "skip-forward",
            "backward skip": "skip-backward",
            "show poster titles": "card-labels",
            "show external ratings": "detail-ratings",
            "position on screen": "subtitle-position"
        ]
        for (query, id) in queries {
            XCTAssertEqual(index.results(for: query).first?.id, id, query)
        }
        XCTAssertEqual(
            Set(index.results(for: "continuous playback").map(\.id)),
            ["autoplay-next-episode", "autoplay-next-playlist"]
        )
    }

    func testExactTitlesOutrankRelatedTermsAndResultsAreStable() {
        XCTAssertEqual(index.results(for: "Theme").first?.id, "theme")
        XCTAssertEqual(index.results(for: "Subtitle language").first?.id, "subtitle-language")
        XCTAssertEqual(index.results(for: "subtitles"), index.results(for: "subtitles"))
        XCTAssertEqual(index.results(for: "rewind").first?.id, "resume-rewind")
    }

    func testMinorTyposPrefixesAndAccents() {
        XCTAssertEqual(index.results(for: "subtitel size").first?.id, "subtitle-size")
        XCTAssertEqual(index.results(for: "GRÁDIENT BACK").first?.id, "gradient-backgrounds")
        XCTAssertEqual(index.results(for: "landscap lock").first?.id, "player-orientation")
    }

    func testEmptyAndUnsupportedQueriesDoNotInventCapabilities() {
        for query in ["", "   ", "!?...", "how do I", "passthrough", "AI upscaling", "teletext"] {
            XCTAssertTrue(index.results(for: query).isEmpty, query)
        }
        XCTAssertTrue(index.results(for: String(repeating: "z", count: 10_000)).isEmpty)
    }

    func testCatalogIdentityAndPlatformRoutes() {
        let entries = SettingsSearchCatalog.entries
        XCTAssertEqual(entries.count, Set(entries.map(\.id)).count)
        XCTAssertTrue(entries.allSatisfy { SettingsSearchCatalog.entry(id: $0.id) == $0 })
        let phone = Set(SettingsSearchCatalog.entries(on: .phone).map(\.id))
        let tablet = Set(SettingsSearchCatalog.entries(on: .tablet).map(\.id))
        let tv = Set(SettingsSearchCatalog.entries(on: .television).map(\.id))
        XCTAssertTrue(phone.contains("player-orientation"))
        XCTAssertFalse(tablet.contains("player-orientation"))
        XCTAssertTrue(tablet.contains("background-audio"))
        XCTAssertFalse(tv.contains("background-audio"))
        XCTAssertTrue(tv.contains("card-focus"))
        XCTAssertFalse(phone.contains("card-focus"))
        XCTAssertFalse(phone.contains("navigation-layout"))
        let remembered = SettingsSearchCatalog.entry(id: "subtitle-remember")
        XCTAssertEqual(remembered?.destinationPage(on: .phone), .playback)
        XCTAssertEqual(remembered?.destinationPage(on: .television), .subtitles)
    }
}
