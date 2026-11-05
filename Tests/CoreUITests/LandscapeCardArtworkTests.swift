import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI
@testable import MetadataKit
#if canImport(UIKit)
import UIKit

@MainActor
final class LandscapeCardArtworkTests: XCTestCase {
    private let card = CardArtworkPolicy.standard
    private let native = URL(string: "https://art.example/thumb.jpg")!
    private let background = URL(string: "https://art.example/backdrop.jpg")!
    private let online = URL(string: "https://art.example/online.jpg")!

    private func item(titled: Bool = true, kind: MediaItemKind = .movie) -> MediaItem {
        MediaItem(
            id: "title", title: "Title", kind: kind,
            posterURL: URL(string: "https://art.example/poster.jpg")!, backdropURL: background,
            artworkSelections: titled ? [.init(placement: .landscapeCard, references: [.remote(native)])] : []
        )
    }

    private func policy(_ preference: ArtworkPreference = .recommended) -> ArtworkPresentationPolicy {
        .init(area: .homeRows, settings: .init(preference: preference), logoLanguage: "en")
    }

    private func source(
        _ item: MediaItem, mode: LandscapeTitleLogo, preference: ArtworkPreference = .recommended
    ) -> ContinueWatchingArtworkSource {
        .init(item: item, style: .landscape, policy: policy(preference), titleLogo: mode)
    }

    func testArtworkOnlyPrefersNativeThumbAndKeepsPrefetchInRenderOrder() {
        let value = item()
        let refs = card.references(for: value, style: .landscape)
        XCTAssertEqual(refs.first, .remote(native))
        XCTAssertEqual(value.artworkCandidates(for: .landscape).map(ArtworkReference.remote), refs)
        XCTAssertTrue(card.prefersPrimaryReference(for: value, style: .landscape, policy: policy()))
        XCTAssertFalse(card.prefersPrimaryReference(for: value, style: .landscape, policy: policy(.online)))
        XCTAssertTrue(PosterCardPresentation.titleBearingArtwork(for: value).contains(.remote(native)))
    }

    func testAutoRetainsNativeTitleArtWithoutAnUnnecessaryTextlessLookup() {
        let value = item()
        for preference in [ArtworkPreference.recommended, .library] {
            let selected = source(value, mode: .automatic, preference: preference)
            XCTAssertEqual(selected.policy.area, .homeRows)
            XCTAssertFalse(selected.prefersTextlessBackdrop)
            XCTAssertEqual(selected.primaryReference(textlessBackdrop: online), .remote(native))
            XCTAssertEqual(selected.references(textlessBackdrop: online).first, .remote(native))
        }
    }

    func testAutoForBackdropOnlyServersAndOnForEveryServerUseCleanBackgrounds() {
        for (value, mode) in [(item(titled: false), LandscapeTitleLogo.automatic), (item(), .on)] {
            let selected = source(value, mode: mode)
            XCTAssertTrue(selected.prefersTextlessBackdrop)
            XCTAssertEqual(selected.primaryReference(textlessBackdrop: online), .remote(online))
            XCTAssertEqual(selected.references(textlessBackdrop: online).first, .remote(online))
            XCTAssertEqual(selected.references(textlessBackdrop: nil).first, .remote(background))
            XCTAssertFalse(PosterCardPresentation.titleBearingArtwork(for: value).contains(.remote(background)))
            let library = source(value, mode: mode, preference: .library)
            XCTAssertFalse(library.prefersTextlessBackdrop)
            XCTAssertNil(library.primaryReference(textlessBackdrop: online))
            XCTAssertEqual(library.references(textlessBackdrop: online).first, .remote(background))
        }
    }

    func testExplicitOnlinePolicyCanOverrideNativeTitleArtInAuto() {
        let selected = source(item(), mode: .automatic, preference: .online)
        XCTAssertTrue(selected.prefersTextlessBackdrop)
        XCTAssertEqual(selected.primaryReference(textlessBackdrop: online), .remote(online))
        XCTAssertEqual(selected.references(textlessBackdrop: online).first, .remote(online))
        XCTAssertTrue(selected.references(textlessBackdrop: online).contains(.remote(native)))
    }

    func testModeAndLanguageChangesCannotReuseThePreviousFirstPaintIdentity() {
        let automatic = source(item(), mode: .automatic)
        let on = source(item(), mode: .on)
        XCTAssertNotEqual(automatic.pinIdentity, on.pinIdentity)
        XCTAssertNotEqual(on.pinIdentity, card.pinIdentity(for: item()))
        let english = card.presentationPolicy(for: item(), style: .landscape, inheriting: policy())
        let french = card.presentationPolicy(
            for: item(), style: .landscape,
            inheriting: .init(area: .homeRows, logoLanguage: "fr")
        )
        XCTAssertNotEqual(english.identity, french.identity)
        XCTAssertNotEqual(
            english.identity, card.presentationPolicy(for: item(), style: .landscape, inheriting: policy(.online)).identity
        )
        XCTAssertEqual(english.settings.preference(in: .homeRows), .recommended)
        XCTAssertEqual(EnvironmentValues().plozzLandscapeTitleLogo, .off)
    }

    func testOnSkipsTitleArtworkEvenWhenItAlsoOccupiesAHeroSlot() {
        var value = item()
        value.artworkSelections.append(.init(placement: .homeHero, references: [.remote(native)]))
        value.artworkSelections.append(.init(placement: .detailBackdrop, references: [.remote(native)]))
        let selected = source(value, mode: .on, preference: .library)
        XCTAssertEqual(selected.references(textlessBackdrop: nil).first, .remote(background))
        XCTAssertTrue(PosterCardPresentation.titleBearingArtwork(for: value).contains(.remote(native)))
    }

    func testEpisodesExtrasAndPortraitsKeepTheirOriginalPolicy() {
        let episode = item(kind: .episode)
        XCTAssertFalse(card.usesLandscapeKeyArt(for: episode, style: .landscape))
        XCTAssertFalse(card.references(for: episode, style: .landscape).contains(.remote(native)))
        XCTAssertFalse(card.usesLandscapeKeyArt(for: item(), style: .poster))
        XCTAssertFalse(CardArtworkPolicy.extra.usesLandscapeKeyArt(for: item(), style: .landscape))
        let continuing = ContinueWatchingArtworkSource(item: item(), style: .landscape, policy: policy())
        XCTAssertEqual(continuing.policy.area, .continueWatching)
        XCTAssertFalse(continuing.references(textlessBackdrop: nil).contains(.remote(native)))
    }

    func testActualFirstPaintHonorsNativeAndExplicitLibraryPrecedence() async {
        let onlineURL = online
        let backgroundURL = background
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        for preference in [ArtworkPreference.recommended, .library, .online] {
            for titled in [true, false] {
                let value = item(titled: titled)
                let inherited = policy(preference)
                let resolvedPolicy = card.presentationPolicy(for: value, style: .landscape, inheriting: inherited)
                let result = await ArtworkFirstPaintResolver.resolve(
                    references: card.references(for: value, style: .landscape),
                    prefersPrimaryReference: card.prefersPrimaryReference(
                        for: value, style: .landscape, policy: inherited
                    ),
                    variant: .landscapeCard, asyncOnlineURL: { onlineURL },
                    prefersOnlineArtwork: resolvedPolicy.prefersOnlineArtwork,
                    imageLoader: { _ in image }
                )
                let expected = preference == .online ? online
                    : titled ? native : preference == .library ? background : online
                XCTAssertEqual(result?.reference, .remote(expected))
            }
        }
        let fallback = await ArtworkFirstPaintResolver.resolve(
            references: [.remote(native), .remote(background)],
            prefersPrimaryReference: true, variant: .landscapeCard, asyncOnlineURL: { nil },
            imageLoader: { reference in reference == .remote(backgroundURL) ? image : nil }
        )
        XCTAssertEqual(fallback?.reference, .remote(background))
    }
}
#endif
