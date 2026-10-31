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

    func testHeroFindsItsOwnPageBeforeTheDetailBackground() {
        for platform: SettingsSearchEntry.Platform in [.phone, .tablet, .television] {
            let index = SettingsSearchIndex(
                entries: SettingsSearchCatalog.entries(on: platform), locale: Locale(identifier: "en_US")
            )
            for query in ["hero", "hero settings", "show hero", "disable hero", "home banner", "spotlight"] {
                let result = index.results(for: query).first
                XCTAssertEqual(result?.id, "hero-enabled", query)
                XCTAssertEqual(result?.destinationPage(on: platform), .hero, query)
            }
            XCTAssertTrue(index.results(for: "hero").contains { $0.id == "detail-background" })
        }
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

    func testModelBackedFamiliesAreExhaustive() {
        for source in RatingSource.allCases {
            XCTAssertEqual(
                SettingsSearchCatalog.entry(id: "rating-source-\(source.rawValue)")?.page, .detailRatingSources
            )
        }
        for view in CardCaptionView.customizableCases {
            XCTAssertEqual(
                SettingsSearchCatalog.entry(id: "card-label-view-\(view.rawValue)")?.cardCaptionView, view
            )
        }
        for area in ArtworkArea.allCases {
            XCTAssertNotNil(SettingsSearchCatalog.entry(id: "artwork-view-\(area.rawValue)"))
        }
        for category in SubtitleContentCategory.allCases where category != .other {
            for prefix in ["audio-language", "subtitle-default", "skip-content"] {
                XCTAssertEqual(
                    SettingsSearchCatalog.entry(id: "\(prefix)-\(category.rawValue)")?.contentCategory, category
                )
            }
            for kind in MediaSegment.Kind.skippable {
                for suffix in ["", "-delay"] {
                    let entry = SettingsSearchCatalog.entry(id: "skip-rule-\(kind.rawValue)-\(category.rawValue)\(suffix)")
                    XCTAssertEqual(entry?.skipKind, kind)
                    XCTAssertEqual(entry?.contentCategory, category)
                }
            }
        }
        for source in HeroSourceKind.allCases {
            XCTAssertNotNil(SettingsSearchCatalog.entry(id: "hero-source-\(source.rawValue)"))
        }
        for source in HeroDiscoverySource.allCases {
            XCTAssertNotNil(SettingsSearchCatalog.entry(id: "hero-discovery-\(source.rawValue)"))
        }
    }

    func testLiveSubtitleStylesReuseAnchorsWithoutOfferingDualTracks() {
        let regular = SettingsSearchCatalog.entries.filter { $0.page == .subtitleStyle && $0.subtitlePage != .dual }
        let live = SettingsSearchCatalog.entries.filter { $0.page == .liveSubtitleStyle }
        XCTAssertEqual(live.count, regular.count)
        for entry in regular {
            let variant = SettingsSearchCatalog.entry(id: "live-\(entry.id)")
            XCTAssertEqual(variant?.anchorID, entry.anchorID)
            XCTAssertEqual(variant?.subtitlePage, entry.subtitlePage)
            XCTAssertEqual(variant?.platform, entry.platform)
            XCTAssertEqual(variant?.minimumOSVersion, entry.minimumOSVersion)
        }
        XCTAssertFalse(live.contains { $0.subtitlePage == .dual })
        XCTAssertEqual(index.results(for: "live subtitles size").first?.id, "live-subtitle-size")
        XCTAssertEqual(index.results(for: "subtitle size").first?.id, "subtitle-size")
    }

    func testCustomQualityKeepsNetworkContextsDistinct() {
        for network in SettingsSearchQualityNetwork.allCases {
            for field in ["height", "bitrate"] {
                let entry = SettingsSearchCatalog.entry(id: "quality-custom-\(field)-\(network.rawValue)")
                XCTAssertEqual(entry?.qualityNetwork, network)
                XCTAssertEqual(entry?.anchorID, "quality-custom-\(field)")
                XCTAssertEqual(entry?.platform, .mobile)
            }
        }
        XCTAssertTrue(index.results(for: "anime skip delay").contains {
            $0.skipKind != nil && $0.contentCategory == .anime && $0.id.hasSuffix("-delay")
        })
        XCTAssertTrue(index.results(for: "cellular bitrate").contains { $0.qualityNetwork == .cellular })
    }

    func testHouseholdSettingsAndOSCapabilitiesStayRestricted() {
        for platform: SettingsSearchEntry.Platform in [.phone, .tablet, .television] {
            for entry in SettingsSearchCatalog.entries where entry.requiresAdultProfile {
                XCTAssertFalse(entry.isAvailable(on: platform, osVersion: 27, isKids: true), entry.id)
            }
        }
        for id in ["spatial-audio", "spatial-layout"] {
            let entry = SettingsSearchCatalog.entry(id: id)
            XCTAssertNotNil(entry)
            XCTAssertFalse(entry?.isAvailable(on: .television, osVersion: 25) ?? true)
            XCTAssertTrue(entry?.isAvailable(on: .television, osVersion: 26) ?? false)
        }
        XCTAssertTrue(SettingsSearchPage.accountLibraries.requiresParentalAuthorization)
        XCTAssertTrue(SettingsSearchPage.profileSettings.requiresParentalAuthorization)
        XCTAssertFalse(SettingsSearchPage.profileAppearance.requiresParentalAuthorization)
    }

    func testCircadianSearchIdentifiesPrerequisitesWithoutChangingSettings() {
        XCTAssertEqual(
            Set(SettingsSearchCatalog.circadianScheduleFallbacks(isEnabled: false, mode: .manual)),
            Set(SettingsSearchCatalog.targets(on: .circadian))
        )
        XCTAssertEqual(
            Set(SettingsSearchCatalog.circadianScheduleFallbacks(isEnabled: true, mode: .solar)),
            ["circadian-on", "circadian-off"]
        )
        XCTAssertEqual(
            Set(SettingsSearchCatalog.circadianScheduleFallbacks(isEnabled: true, mode: .manual)),
            ["circadian-region"]
        )
        XCTAssertEqual(
            Set(SettingsSearchCatalog.circadianScheduleFallbacks(isEnabled: true, mode: .alwaysOn)),
            ["circadian-region", "circadian-on", "circadian-off", "circadian-fade"]
        )
    }

    func testPreferredQueryTermsParticipateInCandidateMatching() {
        let entry = SettingsSearchEntry(
            "example", page: .playback, title: "Example", keywords: "ordinary",
            preferredQueries: ["alternative terminology"]
        )
        let local = SettingsSearchIndex(entries: [entry], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(local.results(for: "alternative terminology").map(\.id), ["example"])
    }
}
