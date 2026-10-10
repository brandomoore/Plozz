import CoreModels
import XCTest
@testable import FeatureWatchlistCore

final class WatchlistPresentationResolverTests: XCTestCase {
    func testSparseLibraryCandidateUsesExactLocalIdentityWithoutAliasOrYear() throws {
        let item = MediaItem(
            id: "folder/custom-film.mkv", title: "Custom Film", kind: .movie,
            sourceAccountID: "share"
        )
        let evidence = try XCTUnwrap(MediaAliasEvidence(item: item))
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: item.kind, localSources: evidence.localSources
        ))
        let candidates = WatchlistPresentationResolver.indexCurrentItems(
            [item], in: MediaAliasSnapshot(records: [record])
        )

        XCTAssertEqual(candidates[record.id]?.id, item.id)
        XCTAssertEqual(candidates[record.id]?.sourceAccountID, "share")
        XCTAssertEqual(candidates[record.id]?.locallyValidatedPlayableSource, true)
    }

    func testExplicitAliasResolvesRedirectWithoutOtherMatchingEvidence() throws {
        let canonical = try XCTUnwrap(MediaAliasRecord(kind: .series))
        let old = try XCTUnwrap(MediaAliasRecord(kind: .series, redirectTarget: canonical.id))
        let item = MediaItem(
            id: "series", title: "Custom Series", kind: .series,
            watchlistAliasID: old.id, sourceAccountID: "share"
        )
        let candidates = WatchlistPresentationResolver.indexCurrentItems(
            [item], in: MediaAliasSnapshot(records: [old, canonical])
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[canonical.id]?.id, item.id)
        XCTAssertNil(candidates[old.id])
    }

    func testStrongConflictCannotMatchThroughTitleOrLocalIdentity() throws {
        let item = MediaItem(
            id: "same-id", title: "Same Title", kind: .movie,
            productionYear: 2020, providerIDs: ["Imdb": "tt222"],
            sourceAccountID: "server"
        )
        let evidence = try XCTUnwrap(MediaAliasEvidence(item: item))
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            strongEvidence: [try XCTUnwrap(.init(kind: .movie, namespace: .imdb, value: "tt111"))],
            weakEvidence: [try XCTUnwrap(evidence.weak)],
            localSources: evidence.localSources
        ))

        XCTAssertTrue(WatchlistPresentationResolver.indexCurrentItems(
            [item], in: MediaAliasSnapshot(records: [record])
        ).isEmpty)
    }

    func testStrongIdentityDoesNotFallBackToUnrelatedWeakAlias() throws {
        let item = MediaItem(
            id: "library-id", title: "Same Title", kind: .movie,
            productionYear: 2020, providerIDs: ["Imdb": "tt222"],
            sourceAccountID: "server"
        )
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            weakEvidence: [try XCTUnwrap(.init(kind: .movie, title: item.title, year: 2020))]
        ))

        XCTAssertTrue(WatchlistPresentationResolver.indexCurrentItems(
            [item], in: MediaAliasSnapshot(records: [record])
        ).isEmpty)
    }

    func testUniqueWeakCandidateStillResolvesWithoutStrongIdentity() throws {
        let item = MediaItem(
            id: "library-id", title: "Custom Title", kind: .movie,
            productionYear: 2020, sourceAccountID: "share"
        )
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            weakEvidence: [try XCTUnwrap(.init(kind: .movie, title: item.title, year: 2020))]
        ))

        XCTAssertEqual(WatchlistPresentationResolver.indexCurrentItems(
            [item], in: MediaAliasSnapshot(records: [record])
        )[record.id]?.id, item.id)
    }

    func testSparseLocalIdentityDoesNotCrossAccountsOrKinds() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            localSources: [try XCTUnwrap(.init(
                accountDescriptorID: "first", providerItemID: "same-id"
            ))]
        ))
        let aliases = MediaAliasSnapshot(records: [record])
        let otherAccount = MediaItem(
            id: "same-id", title: "Custom Title", kind: .movie, sourceAccountID: "second"
        )
        let otherKind = MediaItem(
            id: "same-id", title: "Custom Title", kind: .series,
            watchlistAliasID: record.id, sourceAccountID: "first"
        )

        XCTAssertTrue(WatchlistPresentationResolver.indexCurrentItems(
            [otherAccount, otherKind], in: aliases
        ).isEmpty)
    }

    func testValidatedCandidateWinsRegardlessOfArrivalOrder() throws {
        let record = try XCTUnwrap(MediaAliasRecord(kind: .movie))
        let owned = MediaItem(
            id: "owned", title: "Fixture", kind: .movie,
            watchlistAliasID: record.id, sourceAccountID: "server"
        )
        let discovery = MediaItem(
            id: "discovery", title: owned.title, kind: .movie,
            watchlistAliasID: record.id,
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        for items in [[owned, discovery], [discovery, owned]] {
            XCTAssertEqual(WatchlistPresentationResolver.indexCurrentItems(
                items, in: MediaAliasSnapshot(records: [record])
            )[record.id]?.id, owned.id)
        }
    }
}
