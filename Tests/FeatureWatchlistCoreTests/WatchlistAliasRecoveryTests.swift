import CoreModels
import Foundation
import XCTest
@testable import FeatureWatchlistCore

@MainActor
final class WatchlistAliasRecoveryTests: XCTestCase {
    func testLegacyRowRecoversItsIdentityAndKeepsPositionWithoutDuplicate() async throws {
        let legacy = try intent(origin: .legacyHomeSeed, rank: 5)
        let nativeID = MediaAliasID()
        let weak = try XCTUnwrap(MediaAliasWeakEvidence(kind: .series, title: "Star Wars: Skeleton Crew", year: 2024))
        let record = try XCTUnwrap(MediaAliasRecord(
            id: nativeID, kind: .series, createdAt: Date(timeIntervalSince1970: 20),
            strongEvidence: [try XCTUnwrap(.init(kind: .series, namespace: .tmdb, value: "202879"))],
            weakEvidence: [weak], presentation: legacy.presentation
        ))
        let store = InMemoryMediaAliasStore(.init(records: [record]))
        let ledger = try MediaAliasLedger(profileID: "p", store: store)
        let restored = try await ledger.restoreMissingLegacyAliases(from: [legacy])
        XCTAssertEqual(restored, 1)
        let again = try await ledger.restoreMissingLegacyAliases(from: [legacy])
        XCTAssertEqual(again, 0)
        let aliases = await ledger.snapshot()
        XCTAssertEqual(aliases.resolvedAliasID(for: legacy.aliasID), aliases.resolvedAliasID(for: nativeID))
        let canonical = try XCTUnwrap(aliases.resolvedAliasID(for: legacy.aliasID))
        XCTAssertEqual(aliases.record(for: canonical)?.strongEvidence.first?.value, "202879")
        let source = MediaSourceRef(accountID: "silo", itemID: "series-tvdb-420600", kind: .series, providerKind: .silo)
        let destination = try XCTUnwrap(WatchlistDestinationID(rawValue: "silo"))
        var native = NativeWatchlistView()
        native.applySuccess(destinationID: destination, entries: [
            try XCTUnwrap(NativeWatchlistEntry(
                aliasID: nativeID, kind: .series, presentation: legacy.presentation,
                index: 0, ownedSource: source
            ))
        ])
        let snapshot = WatchlistSnapshot(intents: [legacy], aliasSnapshot: aliases)
        XCTAssertEqual(snapshot.orderedEntries.first?.effectiveOrderingRank, 5)
        let union = WatchlistUnion(
            snapshot: snapshot, nativeView: native, aliasSnapshot: aliases,
            enabledDestinationIDs: [destination]
        )
        let rows = WatchlistPresentationResolver.resolve(
            union: union, aliasSnapshot: aliases, currentItemsByAliasID: [:]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.item.id, source.itemID)
        XCTAssertFalse(rows.first?.item.isNotInLibraryDiscovery ?? true)
        let reloaded = try MediaAliasLedger(profileID: "p", store: store)
        let persisted = await reloaded.snapshot()
        XCTAssertEqual(persisted.resolvedAliasID(for: legacy.aliasID), aliases.resolvedAliasID(for: legacy.aliasID))
    }

    func testAmbiguousLegacyTitleStaysUnboundAndNewerIntentIsNotReconstructed() async throws {
        let legacy = try intent(origin: .legacyHomeSeed, rank: 0)
        let local = try intent(origin: .local, rank: 1)
        let weak = try XCTUnwrap(MediaAliasWeakEvidence(kind: .series, title: "Star Wars: Skeleton Crew", year: 2024))
        let records = try ["1", "2"].map { id in
            try XCTUnwrap(MediaAliasRecord(
                kind: .series, createdAt: Date(timeIntervalSince1970: 20),
                strongEvidence: [try XCTUnwrap(.init(kind: .series, namespace: .tmdb, value: id))],
                weakEvidence: [weak], presentation: legacy.presentation
            ))
        }
        let ledger = try MediaAliasLedger(profileID: "p", store: InMemoryMediaAliasStore(.init(records: records)))
        let count = try await ledger.restoreMissingLegacyAliases(from: [legacy, local])
        XCTAssertEqual(count, 0)
        let aliases = await ledger.snapshot()
        XCTAssertNil(aliases.record(for: legacy.aliasID))
        XCTAssertNil(aliases.record(for: local.aliasID), "Current sync records must not be guessed from presentation")
        for record in records {
            XCTAssertNotEqual(aliases.resolvedAliasID(for: legacy.aliasID), aliases.resolvedAliasID(for: record.id))
        }
    }

    func testReplayedNativeImportStaysEvidenceAndPreservesSyncRoundTrip() throws {
        let model = WatchlistModel()
        try model.activate(profileID: "p")
        try model.retireNativeImports(profileID: "p")
        let imported = try intent(origin: .nativeImport, rank: 0)
        let key = WatchlistMediaStateRecordKey(profileID: "p", aliasID: imported.aliasID)
        let bytes = try XCTUnwrap(CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: imported)))
        _ = try model.applyRemoteSyncRecords(profileID: "p", changes: [key: bytes])
        XCTAssertEqual(try model.captureSyncRecords(profileID: "p")[key.recordName], bytes)
        XCTAssertTrue(model.union(
            profileID: "p", nativeView: .empty, aliasSnapshot: .empty, enabledDestinationIDs: []
        ).orderedEntries.isEmpty)
        let destination = try XCTUnwrap(WatchlistDestinationID(rawValue: "silo"))
        var native = NativeWatchlistView()
        native.applySuccess(destinationID: destination, entries: [
            try XCTUnwrap(NativeWatchlistEntry(aliasID: imported.aliasID, kind: .series, index: 0))
        ])
        XCTAssertTrue(model.union(
            profileID: "p", nativeView: native, aliasSnapshot: .empty,
            enabledDestinationIDs: [destination]
        ).contains(aliasID: imported.aliasID))
    }

    private func intent(origin: WatchlistIntentOrigin, rank: UInt64) throws -> WatchlistIntent {
        try XCTUnwrap(WatchlistIntent(
            aliasID: MediaAliasID(), kind: .series, desiredState: .present,
            rank: rank, origin: origin, changedAt: Date(timeIntervalSince1970: 10),
            presentation: .init(title: "Star Wars: Skeleton Crew", year: 2024)
        ))
    }
}
