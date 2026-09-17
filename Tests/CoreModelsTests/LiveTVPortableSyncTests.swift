import Foundation
import XCTest
@testable import CoreModels

final class LiveTVPortableSyncTests: XCTestCase {
    private let profileID = "profile"

    func testConsentCannotBeBorrowedWhenRootNamespaceOwnerChanges() throws {
        let fixture = try makeFixture()
        let original = LiveTVPortableSyncPreferenceStore(
            defaults: fixture.defaults, profileID: "original", namespace: nil
        )
        let replacement = LiveTVPortableSyncPreferenceStore(
            defaults: fixture.defaults, profileID: "replacement", namespace: nil
        )
        original.isEnabled = true
        XCTAssertTrue(original.isEnabled)
        XCTAssertFalse(replacement.isEnabled)
        replacement.isEnabled = true
        XCTAssertTrue(replacement.isEnabled)
        XCTAssertFalse(original.isEnabled)
    }

    func testReenablingReplaysMissedRemoteChangesWithoutOverwritingOfflineEdits() throws {
        let fixture = try makeFixture()
        let consent = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        try fixture.preferences.save(.init(
            favoriteIDs: ["a", "b"], channelOverrides: ["a": .init(name: "Original"), "b": .init(name: "Original")]
        ))
        let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        var baseline = initial
        for id in ["a", "b"] {
            let key = recordKey(.channel, id)
            let previous = try LiveTVPortableRecord.decode(try XCTUnwrap(initial[key.recordName]), key: key)
            var value = try XCTUnwrap(previous.channel)
            value.metadata = .init(name: "Remote")
            baseline[key.recordName] = try LiveTVPortableRecord(channel: value).encoded()
        }
        consent.isEnabled = false
        _ = try fixture.adapter.apply(baseline.mapValues(Optional.some), sourceStore: fixture.sources)
        try fixture.preferences.save(.init(
            favoriteIDs: ["a", "b"], channelOverrides: ["a": .init(name: "Original"), "b": .init(name: "Local edit")]
        ))
        consent.isEnabled = true
        let captured = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: baseline)
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["a"]?.name, "Remote")
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["b"]?.name, "Local edit")
        XCTAssertEqual(captured[recordKey(.channel, "a").recordName], baseline[recordKey(.channel, "a").recordName])
        XCTAssertNotEqual(captured[recordKey(.channel, "b").recordName], baseline[recordKey(.channel, "b").recordName])
    }

    func testUnloadedCatalogDoesNotErasePreviouslyReceivedNativeIdentityHint() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "native")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true, identityHint: hint)).encoded()
        _ = try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let captured = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: [:], fallback: [key.recordName: bytes]
        )
        let result = try LiveTVPortableRecord.decode(try XCTUnwrap(captured[key.recordName]), key: key)
        XCTAssertEqual(result.channel?.identityHint, hint)
    }

    func testStaleFallbackCannotUndoFreshApplyBeforeOrAfterFirstCapture() throws {
        for capturesFirst in [false, true] {
            let fixture = try makeFixture()
            let key = recordKey(.channel, "channel")
            let old = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
            let deleted = try LiveTVPortableRecord(isDeleted: true).encoded()
            _ = try fixture.adapter.apply([key.recordName: old], sourceStore: fixture.sources)
            if capturesFirst {
                _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: old])
            }
            _ = try fixture.adapter.apply([key.recordName: deleted], sourceStore: fixture.sources)
            for _ in 0..<2 {
                let captured = try fixture.adapter.capture(
                    sourceStore: fixture.sources, fallback: [key.recordName: old]
                )
                XCTAssertEqual(captured[key.recordName], deleted)
                XCTAssertTrue(try fixture.preferences.load().favoriteIDs.isEmpty)
            }
        }
    }

    func testFreshApplyDoesNotConsumeMissedReplayForUnrelatedRecords() throws {
        let fixture = try makeFixture()
        let consent = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        try fixture.preferences.save(.init(
            favoriteIDs: ["a", "b"], channelOverrides: ["a": .init(name: "Initial"), "b": .init(name: "Initial")]
        ))
        let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        consent.isEnabled = false
        var missed = initial
        for id in ["a", "b"] {
            let key = recordKey(.channel, id)
            var channel = try XCTUnwrap(LiveTVPortableRecord.decode(
                XCTUnwrap(initial[key.recordName]), key: key
            ).channel)
            channel.metadata = .init(name: "Missed")
            missed[key.recordName] = try LiveTVPortableRecord(channel: channel).encoded()
        }
        consent.isEnabled = true
        let freshKey = recordKey(.channel, "a")
        var fresh = try XCTUnwrap(LiveTVPortableRecord.decode(
            XCTUnwrap(missed[freshKey.recordName]), key: freshKey
        ).channel)
        fresh.metadata = .init(name: "Latest")
        _ = try fixture.adapter.apply(
            [freshKey.recordName: LiveTVPortableRecord(channel: fresh).encoded()], sourceStore: fixture.sources
        )
        _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: missed)
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["a"]?.name, "Latest")
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["b"]?.name, "Missed")
    }

    func testFailedApplyRetriesExactFallbackWithoutOverwritingLaterLocalEdit() throws {
        for editsLocally in [false, true] {
            let fixture = try makeFixture()
            try fixture.preferences.save(.init(
                favoriteIDs: ["channel"], channelOverrides: ["channel": .init(name: "Initial")]
            ))
            let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
            let key = recordKey(.channel, "channel")
            var remote = try XCTUnwrap(LiveTVPortableRecord.decode(
                XCTUnwrap(initial[key.recordName]), key: key
            ).channel)
            remote.metadata = .init(name: "Remote")
            let bytes = try LiveTVPortableRecord(channel: remote).encoded()
            XCTAssertThrowsError(try fixture.adapter.apply(
                [key.recordName: bytes], sourceStore: UnavailablePortableSources()
            ))
            if editsLocally {
                try fixture.preferences.save(.init(
                    favoriteIDs: ["channel"], channelOverrides: ["channel": .init(name: "Local")]
                ))
            }
            for _ in 0..<2 {
                _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: bytes])
                XCTAssertEqual(
                    try fixture.preferences.load().channelOverrides["channel"]?.name,
                    editsLocally ? "Local" : "Remote"
                )
            }
        }
    }

    func testExplicitHintClearIsNotEchoedBackFromUnchangedCachedEvidence() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "native")
        let original = try LiveTVPortableRecord(channel: .init(isFavorite: true, identityHint: hint)).encoded()
        _ = try fixture.adapter.apply([key.recordName: original], sourceStore: fixture.sources)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let cleared = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        _ = try fixture.adapter.apply([key.recordName: cleared], sourceStore: fixture.sources)
        let pending = try fixture.adapter.deferredIdentityHints()
        XCTAssertTrue(pending.keys.contains("channel"))
        XCTAssertNil(try XCTUnwrap(pending["channel"]))
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let capture = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": hint], fallback: [key.recordName: cleared]
        )
        let removed = try LiveTVPortableRecord.decode(try XCTUnwrap(capture[key.recordName]), key: key)
        XCTAssertNil(removed.channel?.identityHint)
        let changedHint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "new-evidence")
        let changed = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": changedHint], fallback: capture
        )
        XCTAssertEqual(
            try LiveTVPortableRecord.decode(XCTUnwrap(changed[key.recordName]), key: key).channel?.identityHint,
            changedHint
        )
    }

    func testCachedNativeHintCannotResurrectExplicitlyDeletedChannelState() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "native")
        let original = try LiveTVPortableRecord(channel: .init(isFavorite: true, identityHint: hint)).encoded()
        _ = try fixture.adapter.apply([key.recordName: original], sourceStore: fixture.sources)
        let deleted = try LiveTVPortableRecord(isDeleted: true).encoded()
        _ = try fixture.adapter.apply([key.recordName: deleted], sourceStore: fixture.sources)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let capture = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": hint], fallback: [key.recordName: deleted]
        )
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(capture[key.recordName]), key: key).isDeleted)
    }

    func testConsentDefaultsOffAndDoesNotTransferWithProfileSettings() throws {
        let fixture = try makeFixture(enabled: false)
        let key = recordKey(.channel, "channel")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        XCTAssertFalse(fixture.adapter.isEnabled)
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: bytes]), [key.recordName: bytes])
        XCTAssertEqual(try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources).appliedCount, 0)
        XCTAssertEqual(try fixture.preferences.load(), .empty)
        XCTAssertFalse(ProfileSettingsTransfer.transferableBaseKeys.contains("com.plozz.liveTV.portableSync.enabled"))
    }

    func testPreferencesRoundTripPreservesLocalRecentsBrowseAndCanonicalRemoteBytes() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        try sender.preferences.save(.init(
            favoriteIDs: ["b", "a"], recentChannelIDs: ["sender-recent"],
            hiddenChannels: [.init(id: "hidden", name: "Hidden")],
            favoriteOrder: ["b", "a"], favoriteChannels: [.init(id: "a", name: "Favorite A")],
            channelOverrides: ["a": .init(name: "My name", category: "My group", language: "en", country: "US")],
            browse: .init(sort: "sender-sort", favoritesOnly: true)
        ))
        try receiver.preferences.save(.init(
            recentChannelIDs: ["receiver-recent"], browse: .init(sort: "receiver-sort")
        ))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        _ = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        let prefs = try receiver.preferences.load()
        XCTAssertEqual(prefs.favoriteIDs, ["a", "b"])
        XCTAssertEqual(prefs.favoriteOrder, ["b", "a"])
        XCTAssertEqual(prefs.favoriteChannels, [.init(id: "a", name: "Favorite A")])
        XCTAssertEqual(prefs.channelOverrides["a"]?.name, "My name")
        XCTAssertEqual(prefs.hiddenChannelIDs, ["hidden"])
        XCTAssertEqual(prefs.recentChannelIDs, ["receiver-recent"])
        XCTAssertEqual(prefs.browse.sort, "receiver-sort")
        XCTAssertTrue(try receiver.adapter.deferredIdentityHints().isEmpty)
        XCTAssertTrue(try receiver.adapter.deferredGuideMappings().isEmpty)
        let recaptured = try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records)
        XCTAssertEqual(recaptured, records)
    }

    func testUnfavoriteAndUnhideAreExplicitAndDoNotDeleteUnrelatedPeerChanges() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        try sender.preferences.save(.init(favoriteIDs: ["a"], hiddenChannels: [.init(id: "a", name: "A")]))
        let initial = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        _ = try receiver.adapter.apply(initial.mapValues(Optional.some), sourceStore: receiver.sources)
        try sender.preferences.save(.empty)
        let cleared = try sender.adapter.capture(sourceStore: sender.sources, fallback: initial)
        try receiver.preferences.save(.init(favoriteIDs: ["a", "unrelated"], hiddenChannels: [.init(id: "a", name: "A")]))
        _ = try receiver.adapter.apply(cleared.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertEqual(try receiver.preferences.load().favoriteIDs, ["unrelated"])
        XCTAssertTrue(try receiver.preferences.load().hiddenChannels.isEmpty)
    }

    func testPlaylistCredentialsStayLocalAndPendingDescriptorPreservesPausedState() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let source = LiveTVPlaylistSource(
            id: "source", name: "News",
            playlistURL: URL(string: "https://host.test/path-password/list.m3u?token=query-secret")!,
            guideURLs: [URL(string: "https://host.test/guide-secret.xml")!], isEnabled: false
        )
        try sender.sources.save(.init(playlists: [source]))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        let encoded = records.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        for secret in ["path-password", "query-secret", "guide-secret", "https://"] {
            XCTAssertFalse(encoded.contains(secret))
        }
        let report = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertTrue(try receiver.sources.load().playlists.isEmpty)
        XCTAssertEqual(report.pendingPlaylists["source"]?.isEnabled, false)
        XCTAssertEqual(try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records), records)
    }

    func testRemovingSourceKeepsTombstoneAndFavoritesAndCannotRetargetServer() throws {
        let fixture = try makeFixture()
        let source = LiveTVPlaylistSource(id: "source", name: "News", playlistURL: URL(string: "https://host.test/list.m3u")!)
        try fixture.sources.save(.init(playlists: [source], servers: [
            .init(id: "server", name: "Original", accountID: "allowed-account")
        ]))
        try fixture.preferences.save(.init(favoriteIDs: ["recoverable-channel"]))
        let before = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        var config = try fixture.sources.load()
        config.playlists = []
        try fixture.sources.save(config)
        let after = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: before)
        let sourceKey = recordKey(.source, "source")
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(after[sourceKey.recordName]), key: sourceKey).isDeleted)
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: before), after)
        let malicious = try LiveTVPortableRecord(source: .init(
            kind: .server, name: "Different", isEnabled: true, accountID: "other-account"
        )).encoded()
        _ = try fixture.adapter.apply([recordKey(.source, "server").recordName: malicious], sourceStore: fixture.sources)
        XCTAssertEqual(try fixture.sources.load().servers.first?.accountID, "allowed-account")
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["recoverable-channel"])
    }

    func testOptInHydratesPreviouslyFetchedRemoteFavoritesWithoutErasingLocalChoices() throws {
        let fixture = try makeFixture(enabled: false)
        try fixture.preferences.save(.init(favoriteIDs: ["local"]))
        let remote = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let baseline = [recordKey(.channel, "remote").recordName: remote]
        _ = try fixture.adapter.apply(baseline.mapValues(Optional.some), sourceStore: fixture.sources)
        LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID).isEnabled = true
        _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: baseline)
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["local", "remote"])
    }

    func testUnknownProfileMalformedAndOversizedRecordsDoNotMutateStores() throws {
        let fixture = try makeFixture()
        let otherKey = LiveTVPortableRecordKey(profileID: "other", kind: .channel, entityID: "other-channel")
        let other = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let report = try fixture.adapter.apply([
            otherKey.recordName: other,
            recordKey(.channel, "bad").recordName: Data("bad".utf8),
            recordKey(.channel, "large").recordName: Data(repeating: 0, count: LiveTVPortableRecord.maximumBytes + 1)
        ], sourceStore: fixture.sources)
        XCTAssertEqual(report.rejectedCount, 2)
        XCTAssertEqual(try fixture.preferences.load(), .empty)
        XCTAssertTrue(try fixture.sources.load().playlists.isEmpty)
    }

    func testCloudDeletionRemainsTombstoneAndAccountChangeRequiresNewConsent() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "deleted")
        var deletion: SyncLocalChanges = [:]
        deletion.updateValue(nil, forKey: key.recordName)
        _ = try fixture.adapter.apply(deletion, sourceStore: fixture.sources)
        let captured = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(captured[key.recordName]), key: key).isDeleted)
        try fixture.adapter.resetForAccountChange()
        XCTAssertFalse(fixture.adapter.isEnabled)
    }

    func testMappingOverrideRoundTripsAndExplicitRemovalIsReported() throws {
        let fixture = try makeFixture()
        let mapping = LiveTVPortableGuideMapping(guideSourceID: "guide", guideChannelID: "station")
        let records = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: ["channel": mapping], fallback: [:]
        )
        let key = recordKey(.channel, "channel")
        XCTAssertEqual(try LiveTVPortableRecord.decode(XCTUnwrap(records[key.recordName]), key: key).channel?.guideMapping, mapping)
        let removal = try LiveTVPortableRecord(channel: .init()).encoded()
        let report = try fixture.adapter.apply([key.recordName: removal], sourceStore: fixture.sources)
        XCTAssertTrue(report.guideMappings.keys.contains("channel"))
        XCTAssertNil(report.guideMappings["channel"]!)
        let recaptured = try fixture.adapter.capture(sourceStore: fixture.sources, guideMappings: [:], fallback: records)
        XCTAssertEqual(recaptured[key.recordName], removal)
    }

    func testUnavailableGuideExportPreservesMappingUntilAnActualLocalRemoval() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: "feed-v1-" + String(repeating: "a", count: 64), guideChannelID: "station"
        )
        let first = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: ["channel": mapping], fallback: [:]
        )
        let unavailable = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: [:],
            unresolvedGuideMappingIDs: ["channel"], fallback: first
        )
        let retained = try LiveTVPortableRecord.decode(XCTUnwrap(unavailable[key.recordName]), key: key)
        XCTAssertEqual(retained.channel?.guideMapping, mapping)
        let removed = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: [:], fallback: unavailable
        )
        XCTAssertNil(try LiveTVPortableRecord.decode(XCTUnwrap(removed[key.recordName]), key: key).channel?.guideMapping)
    }

    func testPortableFeedBindingRetainsExactCredentialsWithoutExportingAddresses() throws {
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://host.test/list.m3u?token=playlist-secret"))
        )
        let guideURL = try XCTUnwrap(URL(string: "https://host.test/guide.xml?token=guide-secret"))
        let changedURL = try XCTUnwrap(URL(string: "https://host.test/guide.xml?token=changed-secret"))
        let identity = LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guideURL)
        XCTAssertEqual(identity, LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guideURL))
        XCTAssertNotEqual(identity, LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: changedURL))
        let mapping = LiveTVPortableGuideMapping(guideSourceID: identity, guideChannelID: "station")
        XCTAssertTrue(mapping.isSafe)
        XCTAssertTrue(mapping.hasBoundSourceIdentity)
        XCTAssertFalse(LiveTVPortableGuideMapping(guideSourceID: "guide-local", guideChannelID: "station").hasBoundSourceIdentity)
        let text = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        for secret in ["https://", "playlist-secret", "guide-secret", "host.test"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testRecordNamesRoundTripWithoutDelimiterOrPathAmbiguity() {
        let key = LiveTVPortableRecordKey(profileID: "profile:/% ü", kind: .channel, entityID: "channel:a/b:?")
        XCTAssertEqual(LiveTVPortableRecordKey.parse(key.recordName), key)
        XCTAssertNil(LiveTVPortableRecordKey.parse(key.recordName + ":extra"))
        XCTAssertNil(LiveTVPortableRecordKey.parse("liveTV:::"))
    }

    func testLibraryDefinitionWaitsForEveryImmutableSnapshotPart() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let snapshot = try LibraryChannelSnapshot(
            items: (0..<300).map {
                try LibraryChannelItem(
                    item: .init(id: "item-\($0)", title: "Item \($0)", kind: .movie, runtime: 60),
                    library: library, serverID: "server", userID: "user"
                )
            }, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(name: "Movies", libraries: [library]), epochSeconds: 1_700_000_000)
        ])
        XCTAssertThrowsError(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [], fallback: [:]
        ))
        XCTAssertThrowsError(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [], snapshots: [snapshot], fallback: [:]
        ))
        let records = try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [snapshot], fallback: [:]
        )
        let prepared = try LiveTVPortableLibraryExport(definitions: [definition], snapshots: [snapshot])
        XCTAssertEqual(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [snapshot],
            preparedLibrary: prepared, fallback: records
        ), records)
        var changedDefinition = definition
        changedDefinition.isEnabled = false
        XCTAssertThrowsError(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [changedDefinition], snapshots: [snapshot],
            preparedLibrary: prepared, fallback: records
        ))
        let definitionKey = recordKey(.library, definition.id.uuidString)
        let definitionBytes = try XCTUnwrap(records[definitionKey.recordName])
        let partial = try receiver.adapter.apply(
            [definitionKey.recordName: definitionBytes], sourceStore: receiver.sources
        )
        XCTAssertTrue(partial.libraryDefinitions.isEmpty)
        XCTAssertEqual(partial.incompleteSnapshotIDs, [snapshot.id])
        let pendingCapture = try receiver.adapter.capture(
            sourceStore: receiver.sources, libraryDefinitions: [], fallback: [definitionKey.recordName: definitionBytes]
        )
        XCTAssertEqual(pendingCapture[definitionKey.recordName], definitionBytes)
        let unresolved = try receiver.adapter.apply(
            records.mapValues(Optional.some), sourceStore: receiver.sources, includeLibrarySnapshots: false
        )
        XCTAssertTrue(unresolved.snapshots.isEmpty)
        let complete = unresolved.resolvingLibrarySnapshots()
        XCTAssertEqual(complete.libraryDefinitions, [definition])
        XCTAssertEqual(complete.snapshots, [snapshot])
        XCTAssertTrue(complete.incompleteSnapshotIDs.isEmpty)
        XCTAssertEqual(try receiver.adapter.pending(
            sourceStore: receiver.sources, includeLibrarySnapshots: false
        ).resolvingLibrarySnapshots().snapshots, complete.snapshots)
        try receiver.adapter.acknowledgeLibraries([definition.id])
        XCTAssertTrue(try receiver.adapter.pending(sourceStore: receiver.sources).libraryDefinitions.isEmpty)
        _ = try sender.adapter.apply(
            [definitionKey.recordName: definitionBytes], sourceStore: sender.sources
        )
        try sender.adapter.markLibrariesForReview([definition.id])
        let locallyDeleted = try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [], fallback: records
        )
        XCTAssertTrue(try LiveTVPortableRecord.decode(
            XCTUnwrap(locallyDeleted[definitionKey.recordName]), key: definitionKey
        ).isDeleted)
        XCTAssertTrue(try sender.adapter.pending(sourceStore: sender.sources).libraryReviewIDs.isEmpty)
    }

    func testRemovedServerSuppressionReachesDeviceWithoutLocalSource() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        try sender.sources.save(.init(servers: [
            .init(id: "manual-source", name: "Server", accountID: "account")
        ]))
        let initial = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        try sender.sources.save(.empty)
        let removed = try sender.adapter.capture(sourceStore: sender.sources, fallback: initial)
        _ = try receiver.adapter.apply(removed.mapValues(Optional.some), sourceStore: receiver.sources)
        let suppression = LiveTVServerEnrollmentSuppressionStore(defaults: receiver.defaults, profileID: profileID)
        XCTAssertEqual(try suppression.suppressedAccountIDs(), ["account"])
        XCTAssertTrue(try receiver.sources.load().servers.isEmpty)
    }

    func testSafeNativeIdentityHintsTransferButURLBasedHintsAreRejected() throws {
        let fixture = try makeFixture()
        try fixture.preferences.save(.init(favoriteIDs: ["channel"]))
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "BBC.One")
        let capture = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": hint], fallback: [:]
        )
        let key = recordKey(.channel, "channel")
        XCTAssertEqual(try LiveTVPortableRecord.decode(XCTUnwrap(capture[key.recordName]), key: key).channel?.identityHint, hint)
        let receiver = try makeFixture()
        _ = try receiver.adapter.apply(capture.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertEqual(try receiver.adapter.deferredIdentityHints()["channel"]!, hint)
        try receiver.adapter.acknowledgeIdentityHints(["channel"])
        XCTAssertTrue(try receiver.adapter.deferredIdentityHints().isEmpty)
        let favoriteOnlyChange = try LiveTVPortableRecord(channel: .init(
            isFavorite: false, identityHint: hint
        )).encoded()
        _ = try receiver.adapter.apply([key.recordName: favoriteOnlyChange], sourceStore: receiver.sources)
        XCTAssertTrue(try receiver.adapter.deferredIdentityHints().isEmpty, "Favorite edits must not trigger catalog re-import")
        let unsafe = LiveTVPortableRecord(channel: .init(identityHint: .init(
            sourceID: "source", nativeID: "https://host.test/secret?id=credential"
        )))
        XCTAssertThrowsError(try unsafe.validate(key: key))
    }

    func testIdentityHintsAloneDoNotPublishDownloadedCatalog() throws {
        let fixture = try makeFixture()
        let hints = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("channel-\($0)", LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "station.\($0)"))
        })
        let records = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: hints, fallback: [:]
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testAccountChangeInvalidatesEvenMissingProfileConsentAndOldAdapterInstances() throws {
        let fixture = try makeFixture()
        let missingProfile = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: "missing-profile")
        missingProfile.isEnabled = true
        XCTAssertTrue(fixture.adapter.isEnabled)
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
        XCTAssertFalse(missingProfile.isEnabled)
        XCTAssertFalse(fixture.adapter.isEnabled)
        LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID).isEnabled = true
        XCTAssertFalse(fixture.adapter.isEnabled, "A stale adapter must not reopen the old household's journal")
        fixture.defaults.set("../old-household", forKey: "com.plozz.liveTV.portableSync.accountEpoch")
        let preference = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        preference.isEnabled = true
        XCTAssertFalse(preference.isEnabled, "Corrupt epochs cannot opt in or select a journal path")
    }

    func testRemoteServerReenableAndSuppressionArriveInEitherOrderWithoutRecaptureClobber() throws {
        for sourceFirst in [true, false] {
            let fixture = try makeFixture()
            try fixture.sources.save(.init(servers: [.init(id: "server", name: "Server", accountID: "account", isEnabled: false)]))
            let policyStore = LiveTVApprovalAwareSourcesStore(
                underlying: fixture.sources,
                approvals: .init(defaults: fixture.defaults, profileID: profileID)
            )
            let baseline = try fixture.adapter.capture(sourceStore: policyStore, fallback: [:])
            let sourceKey = recordKey(.source, "server")
            let permissionKey = recordKey(.serverEnrollment, "account")
            let source = try LiveTVPortableRecord(source: .init(
                kind: .server, name: "Server", isEnabled: true, accountID: "account"
            )).encoded()
            let permission = try LiveTVPortableRecord(serverEnrollmentSuppressed: false).encoded()
            let first = sourceFirst ? [sourceKey.recordName: source] : [permissionKey.recordName: permission]
            let last = sourceFirst ? [permissionKey.recordName: permission] : [sourceKey.recordName: source]
            _ = try fixture.adapter.apply(first.mapValues(Optional.some), sourceStore: policyStore)
            XCTAssertEqual(try policyStore.load().servers.first?.isEnabled, false)
            let middle = try fixture.adapter.capture(sourceStore: policyStore, fallback: baseline)
            for (key, bytes) in first { XCTAssertEqual(middle[key], bytes) }
            _ = try fixture.adapter.apply(last.mapValues(Optional.some), sourceStore: policyStore)
            XCTAssertEqual(try policyStore.load().servers.first?.isEnabled, true)
        }
    }

    func testGuidePreferencesSyncWithoutRetargetingLocalURLsOrGuideIDs() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let remote = LiveTVPlaylistSource(
            id: "source", name: "News", playlistURL: URL(string: "https://remote.test/secret.m3u")!,
            guideURLs: [URL(string: "https://remote.test/guide.xml")!], guideSourceIDs: ["remote-guide"],
            discoversPlaylistGuides: false, guideLookbackDays: 2, guideLookaheadDays: 14
        )
        let local = LiveTVPlaylistSource(
            id: "source", name: "News", playlistURL: URL(string: "https://local.test/secret.m3u")!,
            guideURLs: [URL(string: "https://local.test/guide.xml")!], guideSourceIDs: ["local-guide"]
        )
        try sender.sources.save(.init(playlists: [remote]))
        try receiver.sources.save(.init(playlists: [local]))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        _ = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        let applied = try XCTUnwrap(receiver.sources.load().playlists.first)
        XCTAssertEqual(applied.playlistURL, local.playlistURL)
        XCTAssertEqual(applied.guideURLs, local.guideURLs)
        XCTAssertEqual(applied.guideSourceIDs, local.guideSourceIDs)
        XCTAssertFalse(applied.discoversPlaylistGuides)
        XCTAssertEqual(applied.guideLookbackDays, 2)
        XCTAssertEqual(applied.guideLookaheadDays, 14)
        XCTAssertEqual(try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records), records)
    }

    func testCredentialLikeGuideIDsStayLocalWhileFavoritesStillSync() throws {
        let fixture = try makeFixture()
        try fixture.preferences.save(.init(favoriteIDs: ["channel"]))
        let unsafe = LiveTVPortableGuideMapping(
            guideSourceID: "guide", guideChannelID: "https://guide.test/path-secret?token=guide-secret"
        )
        XCTAssertFalse(unsafe.isSafe)
        XCTAssertTrue(LiveTVPortableGuideMapping(guideSourceID: "guide", guideChannelID: "station@West").isSafe)
        let records = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: ["channel": unsafe], fallback: [:]
        )
        let key = recordKey(.channel, "channel")
        let bytes = try XCTUnwrap(records[key.recordName])
        let decoded = try LiveTVPortableRecord.decode(bytes, key: key)
        XCTAssertEqual(decoded.channel?.isFavorite, true)
        XCTAssertNil(decoded.channel?.guideMapping)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("guide-secret"))
        XCTAssertThrowsError(try LiveTVPortableRecord(channel: .init(guideMapping: unsafe)).validate(key: key))
    }

    func testImportedPlaylistMetadataNeverCreatesRemoteURLSetupOffer() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let sourceID = UUID().uuidString
        let source = LiveTVPlaylistSource(
            id: sourceID, name: "Imported file",
            playlistURL: URL(string: "plozz-playlist://\(sourceID.lowercased())")!
        )
        try sender.sources.save(.init(playlists: [source]))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        XCTAssertFalse(records.values.contains {
            String(decoding: $0, as: UTF8.self).contains("plozz-playlist")
        })
        let received = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertTrue(received.pendingPlaylists.isEmpty)
        XCTAssertEqual(received.localFileSources[sourceID]?.kind, .importedPlaylist)
        XCTAssertTrue(try receiver.sources.load().playlists.isEmpty)
        XCTAssertEqual(try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records), records)

        let conflictingURLDescriptor = try LiveTVPortableRecord(source: .init(
            kind: .playlist, name: source.name, isEnabled: true
        )).encoded()
        let result = try sender.adapter.apply([
            recordKey(.source, sourceID).recordName: conflictingURLDescriptor
        ], sourceStore: sender.sources)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertEqual(try sender.sources.load().playlists.first?.playlistURL, source.playlistURL)
    }

    func testPreparedOnlyAccessRequiresPreparationAndPreservesExactIncomingBytes() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources)) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
        }
        let key = recordKey(.channel, "channel")
        let record = LiveTVPortableRecord(channel: .init(
            isFavorite: true,
            guideMapping: .init(guideSourceID: "guide", guideChannelID: "station"),
            identityHint: .init(sourceID: "source", nativeID: "native")
        ))
        let object = try JSONSerialization.jsonObject(with: record.encoded())
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        let applied = try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources)
        XCTAssertEqual(applied.appliedCount, 1)
        let mapping = try XCTUnwrap(fixture.adapter.deferredGuideMappings()["channel"])
        let hint = try XCTUnwrap(fixture.adapter.deferredIdentityHints()["channel"])
        XCTAssertEqual(mapping?.guideChannelID, "station")
        XCTAssertEqual(hint?.nativeID, "native")
        try fixture.adapter.acknowledgeMappings(["channel"])
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let fallback = [key.recordName: bytes]
        for _ in 0..<3 {
            XCTAssertEqual(try fixture.adapter.capture(
                sourceStore: fixture.sources, fallback: fallback
            ), fallback)
            XCTAssertTrue(try fixture.adapter.deferredGuideMappings().isEmpty)
            XCTAssertTrue(try fixture.adapter.deferredIdentityHints().isEmpty)
        }
        fixture.adapter.discardPreparedJournal()
        XCTAssertThrowsError(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: fallback))
        try await fixture.adapter.prepareForOperation(records: fallback.mapValues(Optional.some))
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: fallback), fallback)
    }

    func testPreparedCaptureCachesNewlyEncodedLocalRecordsAndTombstones() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        try await fixture.adapter.prepareForOperation()
        try fixture.preferences.save(.init(favoriteIDs: ["local"]))
        let first = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: first), first)
        let key = recordKey(.channel, "local")
        var deletion: SyncLocalChanges = [:]
        deletion.updateValue(nil, forKey: key.recordName)
        let applied = try fixture.adapter.apply(deletion, sourceStore: fixture.sources)
        XCTAssertEqual(applied.appliedCount, 1)
        let deleted = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(deleted[key.recordName]), key: key).isDeleted)
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: deleted), deleted)
    }

    func testPreparedLibraryCaptureAndPendingReuseValidatedSnapshotParts() async throws {
        let sender = try makeFixture(requiresPreparedJournal: true)
        let receiver = try makeFixture(requiresPreparedJournal: true)
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let snapshot = try LibraryChannelSnapshot(
            items: (0..<300).map {
                try LibraryChannelItem(
                    item: .init(id: "item-\($0)", title: "Item \($0)", kind: .movie, runtime: 60),
                    library: library, serverID: "server", userID: "user"
                )
            }, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(name: "Movies", libraries: [library]), epochSeconds: 1_700_000_000)
        ])
        let export = try LiveTVPortableLibraryExport(definitions: [definition], snapshots: [snapshot])
        try await sender.adapter.prepareForOperation(preparedLibrary: export)
        let records = try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [snapshot],
            preparedLibrary: export, fallback: [:]
        )
        XCTAssertEqual(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [snapshot],
            preparedLibrary: export, fallback: records
        ), records)
        try await receiver.adapter.prepareForOperation(records: records.mapValues(Optional.some))
        let imported = try receiver.adapter.apply(
            records.mapValues(Optional.some), sourceStore: receiver.sources, includeLibrarySnapshots: false
        ).resolvingLibrarySnapshots()
        XCTAssertEqual(imported.libraryDefinitions, [definition])
        XCTAssertEqual(imported.snapshots, [snapshot])
        let revision = try XCTUnwrap(imported.journalRevision)
        XCTAssertTrue(receiver.adapter.isCurrentJournalRevision(revision))
        for _ in 0..<3 {
            let pending = try receiver.adapter.pending(
                sourceStore: receiver.sources, includeLibrarySnapshots: false
            ).resolvingLibrarySnapshots()
            XCTAssertEqual(pending.snapshots, [snapshot])
        }
        XCTAssertTrue(try receiver.adapter.acknowledgeLibraries([definition.id], ifCurrent: revision))
        XCTAssertFalse(receiver.adapter.isCurrentJournalRevision(revision))
        XCTAssertTrue(try receiver.adapter.pending(sourceStore: receiver.sources).snapshots.isEmpty)
    }

    func testPreparedSnapshotEquivalencePreservesOriginalOptionalFieldsAndFormatting() async throws {
        let inputs = try makeSnapshotExport()
        var wire = [recordKey(.library, inputs.definition.id.uuidString).recordName:
            try LiveTVPortableRecord(library: inputs.definition).encoded()]
        for part in try LiveTVPortableSnapshots.partition(inputs.snapshot) {
            let canonical = try LiveTVPortableRecord(snapshot: part).encoded()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
            object["channel"] = NSNull()
            object["library"] = NSNull()
            let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            XCTAssertNotEqual(original, canonical)
            wire[recordKey(.snapshot, part.entityID).recordName] = original
        }
        for persisted in [false, true] {
            let fixture = try makeFixture(requiresPreparedJournal: true)
            if persisted {
                try await fixture.adapter.prepareForOperation(records: wire.mapValues(Optional.some))
                _ = try fixture.adapter.apply(
                    wire.mapValues(Optional.some), sourceStore: fixture.sources, includeLibrarySnapshots: false
                )
                fixture.adapter.discardPreparedJournal()
            }
            try await fixture.adapter.prepareForOperation(
                records: wire.mapValues(Optional.some), preparedLibrary: inputs.export
            )
            for _ in 0..<2 {
                XCTAssertEqual(try fixture.adapter.capture(
                    sourceStore: fixture.sources, libraryDefinitions: [inputs.definition], snapshots: [inputs.snapshot],
                    preparedLibrary: inputs.export, fallback: wire
                ), wire)
                try await fixture.adapter.prepareForOperation()
            }
        }
    }

    func testSnapshotCandidateMustBePreparedAndIsBoundToExactCandidateBytes() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let inputs = try makeSnapshotExport()
        try await fixture.adapter.prepareForOperation()
        XCTAssertThrowsError(try fixture.adapter.capture(
            sourceStore: UnavailablePortableSources(), libraryDefinitions: [inputs.definition],
            snapshots: [inputs.snapshot], preparedLibrary: inputs.export, fallback: [:]
        )) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        try await fixture.adapter.prepareForOperation(preparedLibrary: inputs.export)
        let initial = try fixture.adapter.capture(
            sourceStore: fixture.sources, libraryDefinitions: [inputs.definition], snapshots: [inputs.snapshot],
            preparedLibrary: inputs.export, fallback: [:]
        )
        let changed = try LibraryChannelSnapshot(
            id: inputs.snapshot.id, items: inputs.snapshot.items,
            createdAt: inputs.snapshot.createdAt.addingTimeInterval(1)
        )
        let changedExport = try LiveTVPortableLibraryExport(definitions: [inputs.definition], snapshots: [changed])
        XCTAssertThrowsError(try fixture.adapter.capture(
            sourceStore: UnavailablePortableSources(), libraryDefinitions: [inputs.definition], snapshots: [changed],
            preparedLibrary: changedExport, fallback: initial
        )) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
        }
        try await fixture.adapter.prepareForOperation(preparedLibrary: changedExport)
        let captured = try fixture.adapter.capture(
            sourceStore: fixture.sources, libraryDefinitions: [inputs.definition], snapshots: [changed],
            preparedLibrary: changedExport, fallback: initial
        )
        for part in try LiveTVPortableSnapshots.partition(changed) {
            let name = recordKey(.snapshot, part.entityID).recordName
            XCTAssertNotEqual(captured[name], initial[name])
            XCTAssertEqual(captured[name], try LiveTVPortableRecord(snapshot: part).encoded())
        }
        try await fixture.adapter.prepareForOperation()
        XCTAssertEqual(try fixture.adapter.capture(
            sourceStore: fixture.sources, libraryDefinitions: [inputs.definition], snapshots: [changed],
            preparedLibrary: changedExport, fallback: captured
        ), captured)
    }

    func testPreparedSnapshotComparisonRejectsAnUncomparedExistingByteVariant() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let inputs = try makeSnapshotExport()
        try await fixture.adapter.prepareForOperation(preparedLibrary: inputs.export)
        let initial = try fixture.adapter.capture(
            sourceStore: fixture.sources, libraryDefinitions: [inputs.definition], snapshots: [inputs.snapshot],
            preparedLibrary: inputs.export, fallback: [:]
        )
        let part = try XCTUnwrap(LiveTVPortableSnapshots.partition(inputs.snapshot).first)
        let name = recordKey(.snapshot, part.entityID).recordName
        let alternate = Data(" \n".utf8) + (try XCTUnwrap(initial[name]))
        try await fixture.adapter.prepareForOperation(records: [name: alternate])
        XCTAssertThrowsError(try fixture.adapter.capture(
            sourceStore: UnavailablePortableSources(), libraryDefinitions: [inputs.definition],
            snapshots: [inputs.snapshot], preparedLibrary: inputs.export, fallback: [name: alternate]
        )) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
        }
        try await fixture.adapter.prepareForOperation(records: [name: alternate], preparedLibrary: inputs.export)
        XCTAssertEqual(try fixture.adapter.capture(
            sourceStore: fixture.sources, libraryDefinitions: [inputs.definition], snapshots: [inputs.snapshot],
            preparedLibrary: inputs.export, fallback: [name: alternate]
        ), initial)
    }

    func testObsoleteLibraryReportCannotAcknowledgeOrMarkNewerDeferredLibraryWork() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(
                snapshotID: UUID(), recipe: .init(name: "Movies", libraries: [library]),
                epochSeconds: 1_700_000_000
            )
        ])
        let key = recordKey(.library, definition.id.uuidString)
        let bytes = try LiveTVPortableRecord(library: definition).encoded()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        let report = try fixture.adapter.apply(
            [key.recordName: bytes], sourceStore: fixture.sources, includeLibrarySnapshots: false
        )
        let originalRevision = try XCTUnwrap(report.journalRevision)
        let peer = LiveTVPortableSyncAdapter(
            directory: fixture.root, profileID: profileID, defaults: fixture.defaults, requiresPreparedJournal: true
        )
        XCTAssertTrue(peer.isCurrentJournalRevision(originalRevision))
        let deleted = try LiveTVPortableRecord(isDeleted: true).encoded()
        try await peer.prepareForOperation(records: [key.recordName: deleted])
        _ = try peer.apply([key.recordName: deleted], sourceStore: fixture.sources, includeLibrarySnapshots: false)
        try await fixture.adapter.prepareForOperation()
        XCTAssertFalse(fixture.adapter.isCurrentJournalRevision(originalRevision))
        XCTAssertFalse(try fixture.adapter.acknowledgeLibraries([definition.id], ifCurrent: originalRevision))
        XCTAssertFalse(try fixture.adapter.markLibrariesForReview([definition.id], ifCurrent: originalRevision))
        let current = try fixture.adapter.pending(sourceStore: fixture.sources, includeLibrarySnapshots: false)
        XCTAssertEqual(current.deletedLibraryIDs, [definition.id])
        XCTAssertTrue(current.libraryReviewIDs.isEmpty)
        let currentRevision = try XCTUnwrap(current.journalRevision)
        XCTAssertTrue(try fixture.adapter.acknowledgeLibraries([definition.id], ifCurrent: currentRevision))
        XCTAssertTrue(try fixture.adapter.pending(sourceStore: fixture.sources).deletedLibraryIDs.isEmpty)
    }

    func testJournalRevisionIsBoundToJournalAndAccountAndDoesNotReadStorage() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        XCTAssertThrowsError(try fixture.adapter.preparedJournalRevision()) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
        }
        try await fixture.adapter.prepareForOperation()
        let revision = try fixture.adapter.preparedJournalRevision()
        XCTAssertTrue(fixture.adapter.isCurrentJournalRevision(revision))
        fixture.adapter.discardPreparedJournal()
        XCTAssertTrue(fixture.adapter.isCurrentJournalRevision(revision), "Discarding a cache does not mutate the journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        let unrelated = try makeFixture(requiresPreparedJournal: true)
        XCTAssertFalse(unrelated.adapter.isCurrentJournalRevision(revision))
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
        XCTAssertFalse(fixture.adapter.isCurrentJournalRevision(revision))
    }

    func testLibraryReportAcknowledgementAndReviewShareOneRevisionCheck() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let acknowledged = UUID()
        let needsReview = UUID()
        let deletion = try LiveTVPortableRecord(isDeleted: true).encoded()
        let changes: SyncLocalChanges = [
            recordKey(.library, acknowledged.uuidString).recordName: deletion,
            recordKey(.library, needsReview.uuidString).recordName: deletion
        ]
        try await fixture.adapter.prepareForOperation(records: changes)
        let report = try fixture.adapter.apply(changes, sourceStore: fixture.sources, includeLibrarySnapshots: false)
        let revision = try XCTUnwrap(report.journalRevision)
        XCTAssertTrue(try fixture.adapter.acknowledgeLibraries(
            [acknowledged], markingForReview: [needsReview], ifCurrent: revision
        ))
        let pending = try fixture.adapter.pending(sourceStore: fixture.sources, includeLibrarySnapshots: false)
        XCTAssertEqual(pending.deletedLibraryIDs, [needsReview])
        XCTAssertEqual(pending.libraryReviewIDs, [needsReview])
        XCTAssertFalse(fixture.adapter.isCurrentJournalRevision(revision))
    }

    func testUnpreparedIncomingVariantFailsBeforeAnyLocalMutation() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let key = recordKey(.channel, "channel")
        let original = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let changed = try LiveTVPortableRecord(channel: .init(isFavorite: false)).encoded()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: original])
        for value in [changed, Data("unvalidated".utf8)] {
            XCTAssertThrowsError(try fixture.adapter.apply(
                [key.recordName: value], sourceStore: UnavailablePortableSources()
            )) {
                XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
            }
            XCTAssertThrowsError(try fixture.adapter.capture(
                sourceStore: UnavailablePortableSources(), fallback: [key.recordName: value]
            )) {
                XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
            }
        }
        XCTAssertEqual(try fixture.preferences.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testPreparedValidationRetainsRejectionAndWrongProfileSemantics() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let wrongProfile = LiveTVPortableRecordKey(profileID: "other", kind: .channel, entityID: "other")
        let valid = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let changes: SyncLocalChanges = [
            wrongProfile.recordName: valid,
            recordKey(.channel, "valid").recordName: valid,
            recordKey(.channel, "malformed").recordName: Data("bad".utf8),
            recordKey(.channel, "oversized").recordName: Data(repeating: 0, count: LiveTVPortableRecord.maximumBytes + 1),
            recordKey(.channel, "over-cache-budget").recordName: Data(repeating: 0, count: 64 * 1_024 * 1_024 + 1),
            recordKey(.source, "wrong-kind").recordName: valid
        ]
        try await fixture.adapter.prepareForOperation(records: changes)
        let result = try fixture.adapter.apply(changes, sourceStore: fixture.sources)
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.rejectedCount, 4)
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["valid"])
    }

    func testEmptyAndIncrementalWarmupsPreserveEarlierIncomingVariantsAndRejections() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let later = recordKey(.channel, "later")
        let now = recordKey(.channel, "now")
        let invalid = recordKey(.channel, "invalid")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let malformed = Data("not JSON".utf8)
        try await fixture.adapter.prepareForOperation(records: [later.recordName: bytes, invalid.recordName: malformed])
        try await fixture.adapter.prepareForOperation(records: [now.recordName: bytes])
        try await fixture.adapter.prepareForOperation()
        XCTAssertEqual(try fixture.adapter.apply(
            [now.recordName: bytes], sourceStore: fixture.sources
        ).appliedCount, 1)
        try await fixture.adapter.prepareForOperation()
        _ = try fixture.adapter.pending(sourceStore: fixture.sources)
        try await fixture.adapter.prepareForOperation()
        let result = try fixture.adapter.apply(
            [later.recordName: bytes, invalid.recordName: malformed], sourceStore: fixture.sources
        )
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["later", "now"])
    }

    func testWarmupsRetainFallbackAndIncomingVariantsForTheSameKey() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let key = recordKey(.channel, "channel")
        let fallback = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let incoming = try LiveTVPortableRecord(channel: .init(isFavorite: false)).encoded()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: fallback])
        try await fixture.adapter.prepareForOperation(records: [key.recordName: incoming])
        try await fixture.adapter.prepareForOperation()
        _ = try fixture.adapter.apply([key.recordName: incoming], sourceStore: fixture.sources)
        try await fixture.adapter.prepareForOperation()
        let captured = try fixture.adapter.capture(
            sourceStore: fixture.sources, fallback: [key.recordName: fallback]
        )
        XCTAssertEqual(captured[key.recordName], incoming)
        XCTAssertTrue(try fixture.preferences.load().favoriteIDs.isEmpty)
    }

    func testSinglePlaylistDescriptorMatchesPendingWithoutRequiringPreparation() async throws {
        let records: [LiveTVPortableRecord] = [
            .init(source: .init(kind: .playlist, name: "Paused playlist", isEnabled: false)),
            .init(source: .init(kind: .importedPlaylist, name: "Local file", isEnabled: true)),
            .init(source: .init(kind: .server, name: "Server", isEnabled: true, accountID: "account")),
            .init(isDeleted: true)
        ]
        for record in records {
            let fixture = try makeFixture(requiresPreparedJournal: true)
            let key = recordKey(.source, "source")
            let bytes = try record.encoded()
            try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
            _ = try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources)
            let expected = try fixture.adapter.pending(sourceStore: fixture.sources).pendingPlaylists["source"]
            fixture.adapter.discardPreparedJournal()
            XCTAssertEqual(try fixture.adapter.pendingPlaylistDescriptor(
                sourceID: "source", sourceStore: fixture.sources
            ), expected)
            XCTAssertNil(try fixture.adapter.pendingPlaylistDescriptor(
                sourceID: "missing", sourceStore: fixture.sources
            ))
            XCTAssertTrue(try fixture.sources.load().playlists.isEmpty)
            XCTAssertTrue(try fixture.sources.load().servers.isEmpty)
            XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources), "A targeted read is not full preparation")
            try fixture.sources.save(.init(playlists: [.init(
                id: "source", name: "Already configured", playlistURL: URL(string: "https://local.test/private.m3u")!
            )]))
            XCTAssertNil(try fixture.adapter.pendingPlaylistDescriptor(
                sourceID: "source", sourceStore: fixture.sources
            ))
            XCTAssertThrowsError(try fixture.adapter.pendingPlaylistDescriptor(
                sourceID: "source", sourceStore: UnavailablePortableSources()
            ))
        }
    }

    func testSinglePlaylistDescriptorDoesNotReadUnrelatedSnapshotRecords() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let sourceKey = recordKey(.source, "source")
        let descriptor = LiveTVPortableSource(kind: .playlist, name: "Playlist", isEnabled: false)
        let sourceBytes = try LiveTVPortableRecord(source: descriptor).encoded()
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let snapshot = try LibraryChannelSnapshot(items: [
            LibraryChannelItem(
                item: .init(id: "movie", title: "Movie", kind: .movie, runtime: 60),
                library: library, serverID: "server", userID: "user"
            )
        ], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let part = try XCTUnwrap(LiveTVPortableSnapshots.partition(snapshot).first)
        let snapshotKey = recordKey(.snapshot, part.entityID)
        let changes: SyncLocalChanges = [
            sourceKey.recordName: sourceBytes,
            snapshotKey.recordName: try LiveTVPortableRecord(snapshot: part).encoded()
        ]
        try await fixture.adapter.prepareForOperation(records: changes)
        _ = try fixture.adapter.apply(changes, sourceStore: fixture.sources, includeLibrarySnapshots: false)
        let file = try journalRecordURL(in: fixture, named: snapshotKey.recordName)
        fixture.adapter.discardPreparedJournal()
        try Data("corrupt unrelated snapshot wrapper".utf8).write(to: file, options: .atomic)
        try Data("corrupt unrelated observation".utf8).write(
            to: file.deletingLastPathComponent().appendingPathComponent("observed-local.json"), options: .atomic
        )
        XCTAssertEqual(try fixture.adapter.pendingPlaylistDescriptor(
            sourceID: "source", sourceStore: fixture.sources
        ), descriptor)
        do {
            try await fixture.adapter.prepareForOperation()
            XCTFail("Full journal preparation must still reject the damaged snapshot")
        } catch {}
        XCTAssertEqual(try fixture.adapter.pendingPlaylistDescriptor(
            sourceID: "source", sourceStore: fixture.sources
        ), descriptor)
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
        XCTAssertThrowsError(try fixture.adapter.pendingPlaylistDescriptor(
            sourceID: "source", sourceStore: fixture.sources
        )) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .accountChanged)
        }
    }

    func testSinglePlaylistDescriptorValidatesItsOwnWrapperRecordAndSize() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let key = recordKey(.source, "source")
        let bytes = try LiveTVPortableRecord(source: .init(
            kind: .playlist, name: "Playlist", isEnabled: true
        )).encoded()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        _ = try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources)
        let file = try journalRecordURL(in: fixture, named: key.recordName)
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var wrongIdentity = wrapper
        wrongIdentity["name"] = LiveTVPortableRecordKey(
            profileID: "other", kind: .source, entityID: "source"
        ).recordName
        var wrongKind = wrapper
        wrongKind["value"] = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded().base64EncodedString()
        var malformed = wrapper
        malformed["value"] = Data("not JSON".utf8).base64EncodedString()
        let damaged = try [wrongIdentity, wrongKind, malformed].map {
            try JSONSerialization.data(withJSONObject: $0)
        } + [Data(repeating: 0, count: LiveTVPortableRecord.maximumBytes * 2 + 1)]
        for contents in damaged {
            fixture.adapter.discardPreparedJournal()
            try contents.write(to: file, options: .atomic)
            XCTAssertThrowsError(try fixture.adapter.pendingPlaylistDescriptor(
                sourceID: "source", sourceStore: fixture.sources
            ))
            XCTAssertTrue(try fixture.sources.load().playlists.isEmpty)
        }
    }

    func testPreparedJournalAndObservedWritesInvalidateOtherAdapterInstances() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let key = recordKey(.channel, "channel")
        let bytes = try LiveTVPortableRecord(channel: .init(
            isFavorite: true, identityHint: .init(sourceID: "source", nativeID: "native")
        )).encoded()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        _ = try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources)
        let peer = LiveTVPortableSyncAdapter(
            directory: fixture.root, profileID: profileID, defaults: fixture.defaults, requiresPreparedJournal: true
        )
        try await peer.prepareForOperation()
        XCTAssertFalse(try peer.deferredIdentityHints().isEmpty)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        XCTAssertThrowsError(try peer.deferredIdentityHints()) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .preparationRequired)
        }
        try await peer.prepareForOperation()
        XCTAssertTrue(try peer.deferredIdentityHints().isEmpty)
        let replacement = try LiveTVPortableRecord(channel: .init(isFavorite: false)).encoded()
        try await peer.prepareForOperation(records: [key.recordName: replacement])
        _ = try peer.apply([key.recordName: replacement], sourceStore: fixture.sources)
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources))
        try await fixture.adapter.prepareForOperation()
        let current = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        XCTAssertEqual(current[key.recordName], replacement)
        try peer.resetForAccountChange()
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources))
        try await fixture.adapter.prepareForOperation()
        XCTAssertTrue(try fixture.adapter.pending(sourceStore: fixture.sources).pendingPlaylists.isEmpty)
        XCTAssertFalse(fixture.adapter.isEnabled)
    }

    func testPreparedStateNeverGrantsConsentOrReopensAnOldAccountEpoch() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let key = recordKey(.channel, "channel")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        let consent = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        consent.isEnabled = false
        XCTAssertEqual(try fixture.adapter.apply(
            [key.recordName: bytes], sourceStore: fixture.sources
        ).appliedCount, 0)
        XCTAssertEqual(try fixture.preferences.load(), .empty)
        consent.isEnabled = true
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
        consent.isEnabled = true
        XCTAssertFalse(fixture.adapter.isEnabled)
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources)) {
            XCTAssertEqual($0 as? LiveTVPortableSyncAdapter.PreparationError, .accountChanged)
        }
        do {
            try await fixture.adapter.prepareForOperation()
            XCTFail("An old adapter must not prepare the previous household's journal")
        } catch {
            XCTAssertEqual(error as? LiveTVPortableSyncAdapter.PreparationError, .accountChanged)
        }
    }

    func testEmptyDeferredSetsDoNotScanOrValidateUnrelatedJournalRecords() async throws {
        let fixture = try makeFixture()
        try fixture.preferences.save(.init(favoriteIDs: ["channel"]))
        _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        let file = try journalRecordURL(in: fixture)
        fixture.adapter.discardPreparedJournal()
        try Data("corrupt wrapper".utf8).write(to: file, options: .atomic)
        XCTAssertTrue(try fixture.adapter.deferredGuideMappings().isEmpty)
        XCTAssertTrue(try fixture.adapter.deferredIdentityHints().isEmpty)
        do {
            try await fixture.adapter.prepareForOperation()
            XCTFail("Full preparation must still validate the unrelated persisted record")
        } catch {}
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources))
    }

    func testPreparationValidatesInnerJournalRecordAndWrapperIdentity() async throws {
        for corruptIdentity in [false, true] {
            let fixture = try makeFixture()
            try fixture.preferences.save(.init(favoriteIDs: ["channel"]))
            _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
            let file = try journalRecordURL(in: fixture)
            var wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            if corruptIdentity {
                wrapper["name"] = LiveTVPortableRecordKey(
                    profileID: "other", kind: .channel, entityID: "channel"
                ).recordName
            } else {
                wrapper["value"] = Data("invalid inner record".utf8).base64EncodedString()
            }
            try JSONSerialization.data(withJSONObject: wrapper).write(to: file, options: .atomic)
            fixture.adapter.discardPreparedJournal()
            do {
                try await fixture.adapter.prepareForOperation()
                XCTFail("Preparation must reject invalid stored identity or record data")
            } catch {}
            XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["channel"])
        }
    }

    func testFailedPreparedApplyInvalidatesPeersAndPreservesExactReplayReceipt() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        try await fixture.adapter.prepareForOperation()
        try fixture.preferences.save(.init(
            favoriteIDs: ["channel"], channelOverrides: ["channel": .init(name: "Initial")]
        ))
        let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        let key = recordKey(.channel, "channel")
        var remote = try XCTUnwrap(LiveTVPortableRecord.decode(XCTUnwrap(initial[key.recordName]), key: key).channel)
        remote.metadata = .init(name: "Remote")
        let bytes = try LiveTVPortableRecord(channel: remote).encoded()
        let peer = LiveTVPortableSyncAdapter(
            directory: fixture.root, profileID: profileID, defaults: fixture.defaults, requiresPreparedJournal: true
        )
        try await peer.prepareForOperation()
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        XCTAssertThrowsError(try fixture.adapter.apply(
            [key.recordName: bytes], sourceStore: UnavailablePortableSources()
        ))
        XCTAssertThrowsError(try peer.pending(sourceStore: fixture.sources))
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources))
        try await fixture.adapter.prepareForOperation(records: [key.recordName: bytes])
        let recovered = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: bytes])
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["channel"]?.name, "Remote")
        XCTAssertEqual(recovered[key.recordName], bytes)
    }

    func testFailedObservedWriteInvalidatesPartiallyWrittenPreparedJournal() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        try await fixture.adapter.prepareForOperation()
        try fixture.preferences.save(.init(favoriteIDs: ["initial"]))
        _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        let peer = LiveTVPortableSyncAdapter(
            directory: fixture.root, profileID: profileID, defaults: fixture.defaults, requiresPreparedJournal: true
        )
        try await peer.prepareForOperation()
        let observedURL = try journalRecordURL(in: fixture).deletingLastPathComponent()
            .appendingPathComponent("observed-local.json")
        let originalObserved = try Data(contentsOf: observedURL)
        try FileManager.default.removeItem(at: observedURL)
        try FileManager.default.createDirectory(at: observedURL, withIntermediateDirectories: false)
        try Data().write(to: observedURL.appendingPathComponent("blocker"))
        try fixture.preferences.save(.init(favoriteIDs: ["initial", "new"]))
        XCTAssertThrowsError(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:]))
        XCTAssertThrowsError(try peer.pending(sourceStore: fixture.sources))
        XCTAssertThrowsError(try fixture.adapter.pending(sourceStore: fixture.sources))
        try FileManager.default.removeItem(at: observedURL)
        try originalObserved.write(to: observedURL, options: .atomic)
        try await fixture.adapter.prepareForOperation()
        let recovered = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        XCTAssertNotNil(recovered[recordKey(.channel, "new").recordName])
    }

    func testCancelledPreparationCannotPublishACache() async throws {
        let fixture = try makeFixture(requiresPreparedJournal: true)
        let adapter = fixture.adapter
        let task = Task {
            withUnsafeCurrentTask { task in
                if let task { task.cancel() }
            }
            try await adapter.prepareForOperation()
        }
        do {
            try await task.value
            XCTFail("Cancelled preparation should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try adapter.pending(sourceStore: fixture.sources))
        try await adapter.prepareForOperation()
        XCTAssertTrue(try adapter.pending(sourceStore: fixture.sources).pendingPlaylists.isEmpty)
    }

    private func makeSnapshotExport() throws -> (
        definition: LibraryChannelDefinition, snapshot: LibraryChannelSnapshot, export: LiveTVPortableLibraryExport
    ) {
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let snapshot = try LibraryChannelSnapshot(
            items: (0..<300).map {
                try LibraryChannelItem(
                    item: .init(id: "item-\($0)", title: "Item \($0)", kind: .movie, runtime: 60),
                    library: library, serverID: "server", userID: "user"
                )
            }, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(name: "Movies", libraries: [library]), epochSeconds: 1_700_000_000)
        ])
        return (
            definition, snapshot, try LiveTVPortableLibraryExport(definitions: [definition], snapshots: [snapshot])
        )
    }

    private func journalRecordURL(in fixture: Fixture, named name: String? = nil) throws -> URL {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: fixture.root, includingPropertiesForKeys: nil
        ))
        return try XCTUnwrap(enumerator.compactMap { $0 as? URL }.first { url in
            guard url.pathExtension == "record" else { return false }
            guard let name else { return true }
            guard let data = try? Data(contentsOf: url),
                  let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return wrapper["name"] as? String == name
        })
    }

    private func recordKey(_ kind: LiveTVPortableRecordKey.Kind, _ id: String) -> LiveTVPortableRecordKey {
        .init(profileID: profileID, kind: kind, entityID: id)
    }

    private func makeFixture(enabled: Bool = true, requiresPreparedJournal: Bool = false) throws -> Fixture {
        let suite = "LiveTVPortableSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/live-tv-portable-tests/\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID).isEnabled = enabled
        return Fixture(
            root: root,
            defaults: defaults,
            adapter: .init(
                directory: root, profileID: profileID, defaults: defaults,
                requiresPreparedJournal: requiresPreparedJournal
            ),
            sources: PortableTestSources(),
            preferences: .init(defaults: defaults, namespace: profileID)
        )
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let adapter: LiveTVPortableSyncAdapter
        let sources: PortableTestSources
        let preferences: LiveTVPreferencesStore
    }
}

private struct UnavailablePortableSources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration { throw CocoaError(.fileReadNoPermission) }
    func save(_ configuration: LiveTVSourcesConfiguration) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class PortableTestSources: LiveTVSourcesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = LiveTVSourcesConfiguration.empty

    func load() throws -> LiveTVSourcesConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    func save(_ configuration: LiveTVSourcesConfiguration) throws {
        try configuration.validate()
        lock.lock()
        defer { lock.unlock() }
        self.configuration = configuration
    }
}
