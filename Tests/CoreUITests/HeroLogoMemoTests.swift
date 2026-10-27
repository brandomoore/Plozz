import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class HeroLogoMemoTests: XCTestCase {
    func testAppLocaleReachesLogoResolutionAndSeparatesMemoEntries() async {
        let item = MediaItem(id: "series", title: "Series", kind: .series)
        let fallback = HeroLogoFallback(for: item, localizedResolve: { language in
            URL(string: "https://example.test/\(language).png")
        })
        var environment = EnvironmentValues()
        environment.locale = Locale(identifier: "fr_CA")
        let policy = environment.plozzArtworkPolicy
        XCTAssertEqual(policy.logoLanguage, "fr")
        XCTAssertEqual(policy.forArea(.home).forPlacement(.logo).logoLanguage, "fr")
        let french = fallback.localized(to: policy.logoLanguage)
        let english = fallback.localized(to: "en")
        let frenchURL = await french.resolve()
        let englishURL = await english.resolve()
        XCTAssertEqual(frenchURL?.lastPathComponent, "fr.png")
        XCTAssertEqual(englishURL?.lastPathComponent, "en.png")
        XCTAssertNotEqual(
            HeroLogoMemo.key(for: [], fallback: french),
            HeroLogoMemo.key(for: [], fallback: english)
        )
        environment.locale = Locale(identifier: "en")
        XCTAssertNotEqual(
            policy.forPlacement(.logo).identity,
            environment.plozzArtworkPolicy.forPlacement(.logo).identity
        )
        XCTAssertEqual(policy.identity, environment.plozzArtworkPolicy.identity,
                       "Non-logo artwork must retain its shared first-paint cache keys.")
        XCTAssertEqual(
            HeroLogoMemo.key(for: [], fallback: french),
            HeroLogoMemo.key(for: [], fallback: fallback.localized(to: "fr-FR"))
        )
    }

    func testFallbackOnlyTitlesHaveDifferentKeysWithEitherArtworkPreference() {
        let first = MediaItem(id: "first", title: "First series", kind: .series)
        let second = MediaItem(id: "second", title: "Second series", kind: .series)
        for prefersOnline in [false, true] {
            XCTAssertNotEqual(key(first, prefersOnline: prefersOnline), key(second, prefersOnline: prefersOnline))
        }
    }

    func testSharedOrFailingServerReferenceCannotMergeDifferentFallbacks() throws {
        let reference = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://logo.example.test/missing.png")))
        let first = MediaItem(id: "first", title: "First series", kind: .series)
        let second = MediaItem(id: "second", title: "Second series", kind: .series)
        XCTAssertNotEqual(key(first, references: [reference]), key(second, references: [reference]))
    }

    func testSameProviderLocalIDRemainsAccountScoped() {
        var first = MediaItem(id: "123", title: "Shared title", kind: .series)
        first.sourceAccountID = "plex-account"
        var second = first
        second.sourceAccountID = "jellyfin-account"
        XCTAssertNotEqual(key(first), key(second))
    }

    func testLookupIdentityChangesWhenMetadataIsCorrected() {
        let original = MediaItem(id: "123", title: "Same name", kind: .series)
        var enriched = original
        enriched.providerIDs["Tmdb"] = "789"
        XCTAssertNotEqual(key(original), key(enriched))
        var corrected = enriched
        corrected.providerIDs["Tmdb"] = "456"
        XCTAssertNotEqual(key(enriched), key(corrected))
        var movie = original
        movie.kind = .movie
        XCTAssertNotEqual(key(original), key(movie))
    }

    func testEquivalentLookupReusesMemoDespiteNewClosureAndPlaybackState() {
        let original = MediaItem(id: "123", title: "Same series", kind: .series)
        var changed = original
        changed.isPlayed = true
        changed.resumePosition = 100
        XCTAssertEqual(key(original), key(changed))
    }

    func testChangingArtworkPreferenceInvalidatesFallbackPresentation() {
        let item = MediaItem(id: "123", title: "Same series", kind: .series)
        XCTAssertNotEqual(key(item, prefersOnline: false), key(item, prefersOnline: true))
    }

    func testReferenceOnlyMemoStillSharesChannelArtworkRegardlessOfOnlinePreference() throws {
        let reference = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://logo.example.test/channel.png")))
        XCTAssertEqual(
            HeroLogoMemo.key(for: [reference]),
            HeroLogoMemo.key(for: [reference], prefersOnlineArtwork: true)
        )
    }

    #if canImport(UIKit)
    func testCachedFallbackCannotLeakToAnotherTitleOrArtworkPreference() throws {
        let first = MediaItem(id: UUID().uuidString, title: "First series", kind: .series)
        let second = MediaItem(id: UUID().uuidString, title: "Second series", kind: .series)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 10, y: 10, width: 100, height: 60))
        }
        let prepared = try XCTUnwrap(HeroLogoPipeline.decodeAndPrepare(XCTUnwrap(image.pngData())))
        let processed = HeroLogoAnalysis.analyze(prepared, backgroundSample: nil)
        HeroLogoMemo.store(processed, for: key(first))
        XCTAssertTrue(HeroLogoMemo.value(for: key(first))?.image === processed.image)
        XCTAssertNil(HeroLogoMemo.value(for: key(second)))
        XCTAssertNil(HeroLogoMemo.value(for: key(first, prefersOnline: true)))
    }
    #endif

    private func key(
        _ item: MediaItem,
        references: [ArtworkReference] = [],
        prefersOnline: Bool = false
    ) -> HeroLogoMemo.Key {
        HeroLogoMemo.key(
            for: references, fallback: HeroLogoFallback(for: item) { nil },
            prefersOnlineArtwork: prefersOnline
        )
    }
}
