import XCTest
import CoreModels
@testable import FeatureHomeCore

/// Unclassified library art must not change preference when a hero logo arrives.
final class HeroArtworkPlacementTests: XCTestCase {
    func testCompactHeroesPreferSquareBackgroundWithoutChangingPostersOrLogos() throws {
        let square = try XCTUnwrap(URL(string: "https://library.example.test/square.jpg"))
        var item = makeItem(hasLogo: true)
        item.artworkSelections = [.init(placement: .squareHero, references: [.remote(square)])]

        for surface in [HeroPresentationSurface.home, .detail] {
            let compact = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: surface)
            XCTAssertEqual(compact.artworkPlacement, .squareHero)
            for preference in ArtworkPreference.allCases {
                XCTAssertEqual(compact.artworkReferences(preference: preference).first, .remote(square))
            }
            XCTAssertEqual(compact.logoReferences, [.remote(item.logoURL!)])
            XCTAssertEqual(item.artworkReferences(for: .poster), [.remote(item.posterURL!)])
            XCTAssertTrue(compact.artworkReferences.contains(.remote(item.backdropURL!)))

            let landscape = HeroPresentation(item: item, artworkStyle: .landscape, surface: surface)
            XCTAssertNotEqual(landscape.artworkPlacement, .squareHero)
            XCTAssertFalse(landscape.artworkReferences.contains(.remote(square)))
            XCTAssertEqual(landscape.artworkReferences.first, .remote(item.backdropURL!))
        }
    }

    func testSquareHeroPolicyPreservesExplicitOnlineOverrideAndMissingArtFallback() {
        var item = makeItem(hasLogo: true)
        for surface in [HeroPresentationSurface.home, .detail] {
            let area: ArtworkArea = surface == .home ? .home : .details
            let fallback = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: surface)
            XCTAssertNotEqual(fallback.artworkPlacement, .squareHero)
            XCTAssertTrue(ArtworkSettings.default.prefersOnlineArtwork(in: area, placement: fallback.artworkPlacement))

            item.artworkSelections = [.init(placement: .squareHero, references: [.remote(item.posterURL!)])]
            let square = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: surface)
            XCTAssertFalse(ArtworkSettings.default.prefersOnlineArtwork(in: area, placement: square.artworkPlacement))
            XCTAssertFalse(ArtworkSettings(preference: .library).prefersOnlineArtwork(in: area, placement: square.artworkPlacement))
            XCTAssertTrue(ArtworkSettings(preference: .online).prefersOnlineArtwork(in: area, placement: square.artworkPlacement))
            XCTAssertTrue(ArtworkSettings(overrides: [area: .online]).prefersOnlineArtwork(in: area, placement: square.artworkPlacement))
            item.artworkSelections = []
        }
    }

    private func makeItem(hasLogo: Bool) -> MediaItem {
        var item = MediaItem(id: "1", title: "Futurama", kind: .series)
        item.posterURL = URL(string: "https://example.test/poster.jpg")
        item.backdropURL = URL(string: "https://example.test/backdrop.jpg")
        item.logoURL = hasLogo ? URL(string: "https://example.test/logo.png") : nil
        return item
    }

    private func firstReference(
        hasLogo: Bool,
        style: HeroArtworkStyle
    ) -> ArtworkReference? {
        HeroPresentation(
            item: makeItem(hasLogo: hasLogo),
            artworkStyle: style,
            surface: .home
        ).artworkReferences.first
    }

    func testPortraitHeroUsesTheBackdropBeforeTheLogoResolves() {
        XCTAssertEqual(
            firstReference(hasLogo: false, style: .compactPortrait),
            .remote(URL(string: "https://example.test/backdrop.jpg")!),
            "a missing logo may still resolve asynchronously"
        )
    }

    func testPortraitHeroAvoidsThePosterWhenALogoWillBeDrawnOverIt() {
        XCTAssertEqual(
            firstReference(hasLogo: true, style: .compactPortrait),
            .remote(URL(string: "https://example.test/backdrop.jpg")!),
            "a logo over a poster shows the title twice"
        )
    }

    func testLandscapeHeroIsUnchanged() {
        for hasLogo in [true, false] {
            XCTAssertEqual(
                firstReference(hasLogo: hasLogo, style: .landscape),
                .remote(URL(string: "https://example.test/backdrop.jpg")!)
            )
        }
    }

    /// The poster must remain reachable as a fallback; this narrows preference,
    /// it does not discard artwork.
    func testPosterRemainsAvailableAsAFallback() {
        let references = HeroPresentation(
            item: makeItem(hasLogo: true),
            artworkStyle: .compactPortrait,
            surface: .home
        ).artworkReferences
        XCTAssertTrue(
            references.contains(.remote(URL(string: "https://example.test/poster.jpg")!))
        )
    }

    func testPortraitHeroKeepsTheSeparateLogoAndDoesNotChangeOrdinaryPosters() {
        let item = makeItem(hasLogo: true)
        let presentation = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .home)
        XCTAssertEqual(presentation.logoReferences, [.remote(item.logoURL!)])
        XCTAssertEqual(item.artworkReferences(for: .poster), [.remote(item.posterURL!)])
    }

    func testTouchHeroesHonorLibrarySelectionWithoutChangingRecommendedVariety() throws {
        let selected = try XCTUnwrap(URL(string: "https://example.test/selected.jpg"))
        let alternative = try XCTUnwrap(URL(string: "https://example.test/alternative.jpg"))
        var item = makeItem(hasLogo: true)
        item.heroBackdropURL = selected
        item.artworkSelections = [
            .init(placement: .homeHero, references: [.remote(selected), .remote(alternative)]),
            .init(placement: .detailBackdrop, references: [.remote(alternative), .remote(selected)])
        ]
        for style in [HeroArtworkStyle.landscape, .compactPortrait] {
            let home = HeroPresentation(item: item, artworkStyle: style, surface: .home)
            let detail = HeroPresentation(item: item, artworkStyle: style, surface: .detail)
            XCTAssertEqual(home.artworkReferences.first, .remote(selected))
            XCTAssertEqual(detail.artworkReferences.first, .remote(alternative))
            XCTAssertEqual(home.artworkReferences(preferringLibrarySelection: true).first, .remote(selected))
            XCTAssertEqual(detail.artworkReferences(preferringLibrarySelection: true).first, .remote(selected))
            XCTAssertEqual(detail.artworkReferences(preferringLibrarySelection: false).first, .remote(alternative))
            XCTAssertEqual(home.artworkReferences(preference: .recommended).first, .remote(selected))
            XCTAssertEqual(detail.artworkReferences(preference: .recommended).first, .remote(alternative))
            XCTAssertEqual(detail.artworkReferences(preference: .library).first, .remote(selected))
        }
    }

    func testRecommendedTouchDetailVariesFromTheActualLibraryHomeChoice() throws {
        let selected = try XCTUnwrap(URL(string: "https://library.example.test/selected.jpg"))
        let alternate = try XCTUnwrap(URL(string: "https://metadata.example.test/alternate.jpg"))
        var item = makeItem(hasLogo: true)
        item.heroBackdropURL = selected
        item.backdropURL = selected
        item.artworkSelections = [
            .init(placement: .homeHero, references: [.remote(alternate), .remote(selected)]),
            .init(placement: .detailBackdrop, references: [.remote(selected), .remote(alternate)])
        ]
        let home = HeroPresentation(item: item, artworkStyle: .landscape, surface: .home)
        let detail = HeroPresentation(item: item, artworkStyle: .landscape, surface: .detail)
        XCTAssertEqual(home.artworkReferences(preference: .recommended).first, .remote(selected))
        XCTAssertEqual(detail.artworkReferences(preference: .recommended).first, .remote(alternate))
        XCTAssertEqual(home.artworkReferences(preference: .library).first, .remote(selected))
        XCTAssertEqual(detail.artworkReferences(preference: .library).first, .remote(selected))
        let homeOverride = ArtworkSettings(overrides: [.home: .online])
        XCTAssertEqual(home.artworkReferences(settings: homeOverride, in: .home).first, .remote(alternate))
        XCTAssertEqual(detail.artworkReferences(settings: homeOverride, in: .details).first, .remote(selected))
        XCTAssertEqual(
            detail.artworkReferences(settings: homeOverride, in: .details).first,
            homeOverride.artworkReferences(for: item, placement: .detailBackdrop, in: .details).first
        )
    }
}
