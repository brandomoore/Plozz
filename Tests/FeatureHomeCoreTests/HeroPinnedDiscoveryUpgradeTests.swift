import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

final class HeroPinnedDiscoveryUpgradeTests: XCTestCase {
    private func external() -> MediaItem {
        MediaItem(
            id: "tmdb:movie:42", title: "Visible title", kind: .movie,
            heroBackdropURL: URL(string: "https://images.example/visible.jpg"),
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
    }

    private func owned(_ source: MediaSourceRef, additional: [MediaSourceRef] = []) -> MediaItem {
        MediaItem(
            id: source.itemID, title: "Library title", kind: .movie,
            runtime: 1_000,
            heroBackdropURL: URL(string: "https://server.example/library.jpg"),
            providerIDs: ["Tmdb": "42", "Imdb": "tt0042"], discoverySources: [.tmdb],
            availability: .available, downloadProgress: 0.5,
            sourceAccountID: source.accountID, sources: [source] + additional
        )
    }

    private func merge(_ showing: MediaItem, _ fresh: MediaItem) throws -> MediaItem {
        try XCTUnwrap(HeroLiveMerge.merge(
            showing: [showing], fresh: [fresh], limit: 1,
            pinnedItemIDs: [showing.id], preservesPinnedItems: true
        ).items.first)
    }

    func testExternalPinnedSlideAcquiresFreshRoutingWithoutSyntheticPhysicalPrimary() throws {
        let showing = external()
        let source = MediaSourceRef(
            accountID: "account", itemID: "library-42", kind: .movie,
            resumePosition: 250, playedPercentage: 0.25, isFavorite: true,
            lastPlayedAt: Date(timeIntervalSince1970: 100)
        )
        let fresh = owned(source)
        let upgraded = try merge(showing, fresh)
        XCTAssertEqual(upgraded.id, showing.id)
        XCTAssertEqual(upgraded.title, showing.title)
        XCTAssertEqual(upgraded.heroBackdropURL, showing.heroBackdropURL)
        XCTAssertNil(upgraded.sourceAccountID)
        XCTAssertNil(upgraded.selectedSourceAccountID)
        XCTAssertFalse(upgraded.explicitSourceSelection)
        XCTAssertTrue(upgraded.locallyValidatedPlayableSource)
        XCTAssertTrue(upgraded.hasPlayableLibraryTarget())
        XCTAssertEqual(upgraded.sources, [source])
        XCTAssertFalse(upgraded.sources.contains { $0.itemID == showing.id })
        XCTAssertEqual(upgraded.resumePosition, 250)
        XCTAssertEqual(upgraded.playedPercentage, 0.25)
        XCTAssertEqual(upgraded.runtime, 1_000)
        XCTAssertTrue(upgraded.isFavorite)
        XCTAssertEqual(upgraded.lastPlayedAt, source.lastPlayedAt)
        XCTAssertNil(upgraded.availability)
        XCTAssertNil(upgraded.downloadProgress)
        XCTAssertEqual(upgraded.providerID(.imdb), "tt0042")
    }

    func testGenericDiscoveryAliasUpgradesWithoutKeepingAnExplicitStaleSelection() throws {
        var showing = external()
        showing.id = "discovery:movie:42"
        showing.explicitSourceSelection = true
        showing.selectedSourceAccountID = "stale"
        let source = MediaSourceRef(accountID: "account", itemID: "library-42", kind: .movie)
        let result = try merge(showing, owned(source))
        XCTAssertEqual(result.id, "discovery:movie:42")
        XCTAssertTrue(result.hasPlayableLibraryTarget())
        XCTAssertEqual(result.sources, [source])
        XCTAssertNil(result.sourceAccountID)
        XCTAssertNil(result.selectedSourceAccountID)
        XCTAssertFalse(result.explicitSourceSelection)
    }

    func testRepeatedWarmRefreshReplacesRoutesAndDoesNotToggleOwnershipOff() throws {
        let first = MediaSourceRef(
            accountID: "a", itemID: "a-item", kind: .movie, resumePosition: 300
        )
        let initial = try merge(external(), owned(first))
        let second = MediaSourceRef(
            accountID: "b", itemID: "b-item", kind: .movie,
            resumePosition: 999, playedPercentage: 1, isPlayed: true
        )
        let next = try merge(initial, owned(second))
        XCTAssertEqual(next.id, external().id)
        XCTAssertNil(next.sourceAccountID)
        XCTAssertTrue(next.locallyValidatedPlayableSource)
        XCTAssertEqual(next.sources, [second])
        XCTAssertEqual(next.additionalSourceAccountIDs, ["b"])
        XCTAssertTrue(next.isPlayed)
        XCTAssertTrue(next.hasBeenPlayed)
        XCTAssertNil(next.resumePosition)
        XCTAssertNil(next.availability)
    }

    func testExternalUpgradeRejectsWrongKindUntypedPeerAndSyntheticRoutingRefs() throws {
        let source = MediaSourceRef(accountID: "account", itemID: "library-42", kind: .movie)
        let peers: [MediaSourceRef] = [
            .init(accountID: "wrong-kind", itemID: "series", kind: .series),
            .init(accountID: "untyped", itemID: "unknown"),
            .init(accountID: "synthetic", itemID: external().id, kind: .movie),
            .init(accountID: "", itemID: "empty-account", kind: .movie)
        ]
        let result = try merge(external(), owned(source, additional: peers))
        XCTAssertEqual(result.sources, [source])
        XCTAssertNil(result.sourceAccountID)
        XCTAssertTrue(result.locallyValidatedPlayableSource)
    }

    func testVerifiedFlagWithoutFreshPhysicalRefsCannotGrantPlay() throws {
        let source = MediaSourceRef(accountID: "account", itemID: "library-42", kind: .movie)
        var fresh = owned(source)
        fresh.sources = []
        let result = try merge(external(), fresh)
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertNil(result.sourceAccountID)
    }

    func testSharedTitleWithoutStrongIdentityCannotUpgradeOwnership() throws {
        var showing = external()
        showing.providerIDs = [:]
        showing.productionYear = 2026
        let source = MediaSourceRef(accountID: "account", itemID: "library-42", kind: .movie)
        var fresh = owned(source)
        fresh.title = showing.title
        fresh.productionYear = showing.productionYear
        fresh.providerIDs = [:]
        let result = try merge(showing, fresh)
        XCTAssertEqual(result.id, showing.id)
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertTrue(result.sources.isEmpty)
    }

    func testConflictingSecondaryStrongIdentityCannotUpgradeOwnership() throws {
        var showing = external()
        showing.providerIDs["Imdb"] = "tt9999"
        let source = MediaSourceRef(accountID: "account", itemID: "library-42", kind: .movie)
        let result = try merge(showing, owned(source))
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertTrue(result.sources.isEmpty)
    }

    func testVerifiedUntypedSelfGetsKindFromItsPhysicalRecordForPlaybackRouting() throws {
        let source = MediaSourceRef(accountID: "account", itemID: "library-42")
        let result = try merge(external(), owned(source))
        XCTAssertTrue(result.locallyValidatedPlayableSource)
        XCTAssertEqual(result.sources.first?.id, source.id)
        XCTAssertEqual(result.sources.first?.kind, .movie)
        XCTAssertEqual(MediaSourceRef.retainingKindCompatible(
            result.sources, itemKind: result.kind, selfIDs: []
        ).count, 1)
        XCTAssertNil(result.sourceAccountID)
    }

    func testRejectedPhysicalPrimaryStaysRevokedOnLaterPinnedRefreshes() throws {
        let a = MediaSourceRef(accountID: "a", itemID: "a-item", kind: .movie)
        let b = MediaSourceRef(accountID: "b", itemID: "b-item", kind: .movie)
        var showing = owned(a, additional: [b])
        for _ in 0..<3 {
            showing = try merge(showing, owned(b))
            XCTAssertEqual(showing.id, "a-item")
            XCTAssertNil(showing.sourceAccountID)
            XCTAssertFalse(showing.locallyValidatedPlayableSource)
            XCTAssertTrue(showing.sources.isEmpty)
            XCTAssertFalse(showing.hasPlayableLibraryTarget(additionalSources: [a]))
        }
    }

    func testExternalPresentationCanRecoverAfterVerificationWasRevoked() throws {
        let source = MediaSourceRef(accountID: "account", itemID: "library-42", kind: .movie)
        let upgraded = try merge(external(), owned(source))
        let revoked = try merge(upgraded, external())
        XCTAssertFalse(revoked.locallyValidatedPlayableSource)
        XCTAssertTrue(revoked.sources.isEmpty)
        let restored = try merge(revoked, owned(source))
        XCTAssertTrue(restored.locallyValidatedPlayableSource)
        XCTAssertEqual(restored.sources, [source])
        XCTAssertEqual(restored.id, external().id)
    }
}
