#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVPortableLibraryImportTests: XCTestCase {
    func testProfilePartitionReusesParsedIDsButAlwaysUsesCurrentPayloads() async throws {
        let worker = LiveTVPortableLibraryPreparation()
        let first = LiveTVPortableRecordKey(profileID: "first", kind: .channel, entityID: "one").recordName
        let second = LiveTVPortableRecordKey(profileID: "second", kind: .channel, entityID: "two").recordName
        let unknown = "unrecognized-record"
        let original = Data("original".utf8)
        var input = [first: original, second: original, unknown: original]
        let partitioned = await worker.partitionByProfile(input)
        XCTAssertEqual(partitioned, ["first": [first: original], "second": [second: original]])
        let initialParses = await worker.recordIDParseCount
        XCTAssertEqual(initialParses, 3)

        let edited = Data("edited".utf8)
        input[first] = edited
        let updated = await worker.partitionByProfile(input)
        XCTAssertEqual(updated["first"], [first: edited])
        let repeatedParses = await worker.recordIDParseCount
        XCTAssertEqual(repeatedParses, initialParses, "Unchanged IDs, even unknown ones, must not be decoded again.")

        input[second] = nil
        let third = LiveTVPortableRecordKey(profileID: "third", kind: .channel, entityID: "three").recordName
        input[third] = original
        let replaced = await worker.partitionByProfile(input)
        XCTAssertNil(replaced["second"])
        XCTAssertEqual(replaced["third"], [third: original])
        let finalParses = await worker.recordIDParseCount
        let retained = await worker.cachedRecordIDCount
        XCTAssertEqual(finalParses, initialParses + 1)
        XCTAssertEqual(retained, input.count)
        _ = await worker.partitionByProfile([:])
        let cleared = await worker.cachedRecordIDCount
        XCTAssertEqual(cleared, 0)
    }

    func testCaptureReceiptDoesNotRetainAnUnchangedCollectionAbove64MiB() async throws {
        let worker = LiveTVPortableLibraryPreparation()
        let bytes = Data(repeating: 42, count: 51_280)
        let records = Dictionary(uniqueKeysWithValues: (0..<1_478).map { ("record-\($0)", bytes) })
        XCTAssertGreaterThan(records.values.reduce(0) { $0 + $1.count }, 64 * 1_024 * 1_024)
        let prepared = try await worker.captureRecords(records, fallback: records)
        let receipt = try XCTUnwrap(prepared)
        XCTAssertTrue(receipt.changes.isEmpty)
        XCTAssertEqual(receipt.byteCount, 0)
        XCTAssertEqual(receipt.fingerprints.count, records.count)
        let matches = try await worker.matches(records, fingerprints: receipt.fingerprints)
        XCTAssertTrue(matches)
        var edited = records
        edited["record-0"] = Data(repeating: 43, count: bytes.count)
        let changed = try await worker.matches(edited, fingerprints: receipt.fingerprints)
        XCTAssertFalse(changed)
        edited = records
        edited["record-0"] = nil
        let removed = try await worker.matches(edited, fingerprints: receipt.fingerprints)
        XCTAssertFalse(removed)
    }

    func testUnacknowledgedLocalOutputReusesCaptureAgainstTheUnchangedServerFallback() async throws {
        let fixture = try fixture()
        let profileID = fixture.profiles.activeProfileID
        let (snapshot, definition) = try library(profileID: profileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = RetainingImportSnapshots()
        try await snapshots.seed(snapshot, profileID: profileID)
        let revision = UUID()
        let bridge = fixture.bridge(
            definitions: definitions, snapshots: snapshots, captureIdentityRevision: { _ in revision }
        )
        let output = await bridge.capture(fallback: [:])
        XCTAssertFalse(output.isEmpty)
        let stabilized = await bridge.capture(fallback: [:])
        XCTAssertEqual(stabilized, output)
        let before = await snapshots.readCount
        for _ in 0..<4 {
            let retried = await bridge.capture(fallback: [:])
            XCTAssertEqual(retried, output, "Reuse local output, not the older server fallback")
        }
        let after = await snapshots.readCount
        XCTAssertEqual(before, after, "Pending uploads must not force schedule reconstruction")
    }

    func testSettledCapturesSkipSnapshotsAndIdentityExportsAcrossProfiles() async throws {
        let fixture = try fixture()
        let profileID = fixture.profiles.activeProfileID
        let other = fixture.profiles.add(name: "Other")
        LiveTVPortableSyncPreferenceStore(
            defaults: fixture.defaults, profileID: other.id, namespace: other.id
        ).isEnabled = true
        let (snapshot, definition) = try library(profileID: profileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let empty = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots()
        try await snapshots.seed(snapshot, profileID: profileID)
        var identityCaptures = 0
        var identityRevision = UUID()
        let bridge = LiveTVPortableSyncBridge(
            profiles: fixture.profiles, directory: fixture.directory, defaults: fixture.defaults,
            sourceStore: { _ in PortableImportSources() },
            definitions: { $0 == profileID ? definitions : empty }, snapshots: snapshots,
            captureIdentityHints: { _ in identityCaptures += 1; return [:] },
            captureIdentityRevision: { _ in identityRevision }
        )
        var records = await bridge.capture(fallback: [:])
        records = await bridge.capture(fallback: records)
        XCTAssertEqual(bridge.statuses[profileID], .ready)
        XCTAssertEqual(bridge.statuses[other.id], .ready)
        let readCount = await snapshots.readCount
        let captures = identityCaptures
        for _ in 0..<4 {
            let repeated = await bridge.capture(fallback: records)
            XCTAssertEqual(repeated, records)
        }
        let repeatedReads = await snapshots.readCount
        XCTAssertEqual(repeatedReads, readCount, "No schedule payload may be read on a settled poll")
        XCTAssertEqual(identityCaptures, captures, "Empty profiles must not evict another profile's receipt")

        try LiveTVPreferencesStore(defaults: fixture.defaults, namespace: nil).save(
            .init(favoriteIDs: ["changed"])
        )
        records = await bridge.capture(fallback: records)
        XCTAssertNotNil(records[LiveTVPortableRecordKey(
            profileID: profileID, kind: .channel, entityID: "changed"
        ).recordName])
        XCTAssertGreaterThan(identityCaptures, captures)
        records = await bridge.capture(fallback: records)
        let beforeIdentityChange = identityCaptures
        identityRevision = UUID()
        _ = await bridge.capture(fallback: records)
        XCTAssertGreaterThan(identityCaptures, beforeIdentityChange)
    }

    func testSettledCaptureInvalidatesForDefinitionsSnapshotsFallbackAndConsent() async throws {
        let fixture = try fixture()
        let profileID = fixture.profiles.activeProfileID
        let (snapshot, definition) = try library(profileID: profileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = RetainingImportSnapshots()
        try await snapshots.seed(snapshot, profileID: profileID)
        let revision = UUID()
        let bridge = fixture.bridge(
            definitions: definitions, snapshots: snapshots, captureIdentityRevision: { _ in revision }
        )
        var records = await bridge.capture(fallback: [:])
        records = await bridge.capture(fallback: records)
        var disabled = definition
        disabled.isEnabled = false
        try definitions.save([disabled])
        records = await bridge.capture(fallback: records)
        let key = LiveTVPortableRecordKey(
            profileID: profileID, kind: .library, entityID: definition.id.uuidString
        )
        let exported = try JSONDecoder().decode(
            LiveTVPortableRecord.self, from: XCTUnwrap(records[key.recordName])
        )
        XCTAssertEqual(exported.library, disabled)
        records = await bridge.capture(fallback: records)
        let beforeFallbackChange = await snapshots.readCount
        _ = await bridge.capture(fallback: [:])
        let afterFallbackChange = await snapshots.readCount
        XCTAssertGreaterThan(afterFallbackChange, beforeFallbackChange)

        let consent = LiveTVPortableSyncPreferenceStore(
            defaults: fixture.defaults, profileID: profileID, namespace: fixture.profiles.activeNamespace
        )
        consent.isEnabled = false
        let optedOut = await bridge.capture(fallback: records)
        XCTAssertEqual(optedOut, records)
        consent.isEnabled = true
        _ = await bridge.capture(fallback: records)
        let afterConsent = await snapshots.readCount
        XCTAssertGreaterThan(afterConsent, afterFallbackChange)

        _ = await bridge.capture(fallback: records)
        try await snapshots.retain(ids: [], profileID: profileID)
        _ = await bridge.capture(fallback: records)
        XCTAssertEqual(bridge.statuses[profileID], .pendingLibraryInputs)
    }

    func testSettledCaptureDoesNotHideJournalEditsFromAnotherAdapter() async throws {
        let fixture = try fixture()
        let profileID = fixture.profiles.activeProfileID
        let (snapshot, definition) = try library(profileID: profileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = RetainingImportSnapshots()
        try await snapshots.seed(snapshot, profileID: profileID)
        let revision = UUID()
        let bridge = fixture.bridge(
            definitions: definitions, snapshots: snapshots, captureIdentityRevision: { _ in revision }
        )
        var records = await bridge.capture(fallback: [:])
        records = await bridge.capture(fallback: records)
        let before = await snapshots.readCount
        let other = LiveTVPortableSyncAdapter(
            directory: fixture.directory, profileID: profileID, defaults: fixture.defaults,
            namespace: fixture.profiles.activeNamespace
        )
        var remote = definition
        remote.isEnabled = false
        _ = try other.apply(
            self.records(snapshot: snapshot, definition: remote),
            sourceStore: PortableImportSources(), includeLibrarySnapshots: false
        )
        records = await bridge.capture(fallback: records)
        let afterApply = await snapshots.readCount
        XCTAssertGreaterThan(afterApply, before)
        XCTAssertEqual(try definitions.load(), [remote])
        _ = await bridge.capture(fallback: records)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: fixture.directory, includingPropertiesForKeys: nil
        ))
        let file = try XCTUnwrap((enumerator.allObjects as? [URL])?.first { $0.pathExtension == "record" })
        try Data("corrupt".utf8).write(to: file, options: .atomic)
        _ = await bridge.capture(fallback: records)
        XCTAssertEqual(bridge.statuses[profileID], .unavailable)
    }

    func testExportPreparationReusesOnlyAnExactlyMatchingValidatedInput() async throws {
        let builds = PortableExportBuilds()
        let worker = LiveTVPortableLibraryPreparation(makeExport: builds.make)
        let (snapshot, definition) = try library(profileID: "profile")
        let first = try await worker.prepare(definitions: [definition], snapshots: [snapshot])
        let repeated = try await worker.prepare(definitions: [definition], snapshots: [snapshot])
        XCTAssertEqual(first.state, repeated.state)
        XCTAssertEqual(builds.count, 1)

        let changed = try LibraryChannelSnapshot(
            id: snapshot.id, items: snapshot.items,
            createdAt: snapshot.createdAt.addingTimeInterval(1)
        )
        let updated = try await worker.prepare(definitions: [definition], snapshots: [changed])
        XCTAssertEqual(updated.state.snapshots, [changed])
        XCTAssertEqual(builds.count, 2, "Snapshot ID alone must not authorize cache reuse")
        var paused = definition
        paused.isEnabled = false
        let edited = try await worker.prepare(definitions: [paused], snapshots: [changed])
        XCTAssertEqual(edited.state.definitions, [paused])
        XCTAssertEqual(builds.count, 3)
        await worker.discardExport()
        _ = try await worker.prepare(definitions: [paused], snapshots: [changed])
        XCTAssertEqual(builds.count, 4)
    }

    func testImmutableInputsStayPinnedDuringConcurrentRetentionUntilDefinitionCommit() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots()
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertEqual(try definitions.load(), [definition])
        let saved = try await snapshots.snapshot(id: snapshot.id, profileID: definition.profileID)
        XCTAssertEqual(saved, snapshot)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.stages, 1)
        XCTAssertEqual(counts.inserts, 0)
        XCTAssertEqual(counts.releases, 1)
    }

    func testFailedDefinitionCommitReleasesStagedSnapshotLease() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(failsSave: true)
        let snapshots = RetainingImportSnapshots()
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertEqual(bridge.statuses[definition.profileID], .unavailable)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
        try await snapshots.retain(ids: [], profileID: definition.profileID)
        let removed = try await snapshots.snapshot(id: snapshot.id, profileID: definition.profileID)
        XCTAssertNil(removed)
    }

    func testDisableTakesEffectWhileNewImmutableInputsAreStillMissing() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        try await snapshots.insert(snapshot, profileID: definition.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        var incoming = definition
        incoming.isEnabled = false
        incoming.revisions.append(.init(
            snapshotID: UUID(), recipe: definition.revisions[0].recipe, epochSeconds: 1_700_000_060
        ))
        let key = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        await bridge.apply([key: try LiveTVPortableRecord(library: incoming).encoded()])
        let current = try XCTUnwrap(definitions.load().first)
        XCTAssertFalse(current.isEnabled)
        XCTAssertEqual(current.revisions, definition.revisions)
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingSchedules(1))
    }

    func testPublishedRevisionMutationStaysPendingWithoutRewritingOrAcknowledging() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        try await snapshots.insert(snapshot, profileID: definition.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        var recipe = definition.revisions[0].recipe
        recipe.seed += 1
        var changed = definition
        changed.revisions = [.init(
            id: definition.revisions[0].id, snapshotID: snapshot.id, recipe: recipe,
            epochSeconds: definition.revisions[0].epochSeconds
        )]
        await bridge.apply(try records(snapshot: snapshot, definition: changed))
        XCTAssertEqual(try definitions.load(), [definition])
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryReview)
        XCTAssertEqual(try fixture.pending().libraryReviewIDs, [definition.id])
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(try definitions.load(), [definition])
        XCTAssertEqual(try fixture.pending().libraryDefinitions, [changed])
        XCTAssertEqual(try fixture.pending().libraryReviewIDs, [definition.id])
    }

    func testStaleRemoteDefinitionPreservesFutureRevisionAndItsLocalSnapshot() async throws {
        let fixture = try fixture()
        let (old, remote) = try library(profileID: fixture.profiles.activeProfileID)
        let (future, _) = try library(profileID: remote.profileID)
        let schedule = try LibraryChannelSchedule(definition: remote, snapshots: [old.id: old])
        let boundary = try schedule.slot(at: Date().addingTimeInterval(3_600)).endSeconds
        var local = remote
        local.revisions.append(.init(
            snapshotID: future.id, recipe: remote.revisions[0].recipe, epochSeconds: boundary
        ))
        local.publishedThrough = boundary
        let definitions = PortableImportDefinitions(values: [local])
        let snapshots = RetainingImportSnapshots()
        try await snapshots.seed(old, profileID: remote.profileID)
        try await snapshots.seed(future, profileID: remote.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: old, definition: remote))
        XCTAssertEqual(try definitions.load(), [local])
        let retained = try await snapshots.snapshot(id: future.id, profileID: remote.profileID)
        XCTAssertEqual(retained, future)
        XCTAssertTrue(try fixture.pending().libraryDefinitions.isEmpty)
    }

    func testMissingExportSnapshotPreservesFallbackWhileChannelPreferencesStillCapture() async throws {
        let fixture = try fixture()
        let (_, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = LibraryChannelSnapshotStore(databaseURL: nil)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        try LiveTVPreferencesStore(
            defaults: fixture.defaults, namespace: fixture.profiles.activeNamespace
        ).save(.init(favoriteIDs: ["favorite"]))
        let first = await bridge.capture(fallback: [:])
        XCTAssertFalse(first.keys.contains { LiveTVPortableRecordKey.parse($0)?.kind == .library })
        XCTAssertTrue(first.keys.contains { LiveTVPortableRecordKey.parse($0)?.entityID == "favorite" })
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryInputs)
        let key = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        let previous = try LiveTVPortableRecord(library: definition).encoded()
        let next = await bridge.capture(fallback: [key: previous])
        XCTAssertEqual(next[key], previous)
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryInputs)
    }

    func testConcurrentLocalEditRemainsPendingAcrossLaterCapture() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        var paused = definition
        paused.isEnabled = false
        let snapshots = RetainingImportSnapshots(afterStage: { [paused] in
            try definitions.save([paused])
        })
        try await snapshots.seed(snapshot, profileID: definition.profileID)
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertEqual(try definitions.load(), [paused])
        XCTAssertEqual(bridge.statuses[definition.profileID], .pendingLibraryReview)
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(try definitions.load(), [paused])
        XCTAssertEqual(try fixture.pending().libraryReviewIDs, [definition.id])
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.stages, 1)
    }

    func testConsentRevokedAndReenabledDuringStagingCannotCommitUnderNewConsent() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots(afterStage: {
            await MainActor.run {
                let consent = LiveTVPortableSyncPreferenceStore(
                    defaults: fixture.defaults, profileID: definition.profileID,
                    namespace: fixture.profiles.activeNamespace
                )
                consent.isEnabled = false
                consent.isEnabled = true
            }
        })
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertEqual(try fixture.pending().libraryDefinitions, [definition])
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testNewerJournalDefinitionDuringStagingCannotBePublishedOrAcknowledgedAsOlderInput() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        var changed = definition
        changed.isEnabled = false
        let newer = try records(snapshot: snapshot, definition: changed)
        let writer = LiveTVPortableSyncAdapter(
            directory: fixture.directory, profileID: definition.profileID, defaults: fixture.defaults,
            namespace: fixture.profiles.activeNamespace
        )
        let snapshots = RetainingImportSnapshots(afterStage: {
            _ = try writer.apply(newer, sourceStore: PortableImportSources())
        })
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertEqual(try fixture.pending().libraryDefinitions, [changed])
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testAccountChangeDuringStagingReleasesInputsWithoutCommitting() async throws {
        let fixture = try fixture()
        let (snapshot, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions()
        let snapshots = RetainingImportSnapshots(afterStage: {
            await MainActor.run {
                LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
            }
        })
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        await bridge.apply(try records(snapshot: snapshot, definition: definition))
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertTrue(try fixture.pending().libraryDefinitions.isEmpty)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.releases, 1)
    }

    func testDeletedDefinitionRevokesAuthorityWithoutItsOldSnapshot() async throws {
        let fixture = try fixture()
        let (_, definition) = try library(profileID: fixture.profiles.activeProfileID)
        let definitions = PortableImportDefinitions(values: [definition])
        let snapshots = RetainingImportSnapshots()
        let bridge = fixture.bridge(definitions: definitions, snapshots: snapshots)
        let key = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        await bridge.apply([key: try LiveTVPortableRecord(isDeleted: true).encoded()])
        XCTAssertTrue(try definitions.load().isEmpty)
        XCTAssertTrue(try fixture.pending().deletedLibraryIDs.isEmpty)
        let counts = await snapshots.counts()
        XCTAssertEqual(counts.stages, 0)
    }

    private func records(
        snapshot: LibraryChannelSnapshot, definition: LibraryChannelDefinition
    ) throws -> SyncLocalChanges {
        var changes: SyncLocalChanges = [:]
        let definitionKey = LiveTVPortableRecordKey(
            profileID: definition.profileID, kind: .library, entityID: definition.id.uuidString
        ).recordName
        changes[definitionKey] = try LiveTVPortableRecord(library: definition).encoded()
        for part in try LiveTVPortableSnapshots.partition(snapshot) {
            let key = LiveTVPortableRecordKey(
                profileID: definition.profileID, kind: .snapshot, entityID: part.entityID
            ).recordName
            changes[key] = try LiveTVPortableRecord(snapshot: part).encoded()
        }
        return changes
    }

    private func library(profileID: String) throws -> (LibraryChannelSnapshot, LibraryChannelDefinition) {
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let item = try LibraryChannelItem(
            item: MediaItem(id: "movie", title: "Programme", kind: .movie, runtime: 60),
            library: library, serverID: "server", userID: "user"
        )
        let snapshot = try LibraryChannelSnapshot(
            items: [item], createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(name: "Channel", libraries: [library]), epochSeconds: 1_700_000_000)
        ], publishedThrough: 1_700_000_060)
        return (snapshot, definition)
    }

    private func fixture() throws -> PortableLibraryImportFixture {
        let suite = "LiveTVPortableLibraryImportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        LiveTVPortableSyncPreferenceStore(
            defaults: defaults, profileID: profiles.activeProfileID, namespace: profiles.activeNamespace
        ).isEnabled = true
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/live-tv-library-import-tests/" + UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return PortableLibraryImportFixture(profiles: profiles, defaults: defaults, directory: directory)
    }
}

@MainActor
private struct PortableLibraryImportFixture {
    let profiles: ProfilesModel
    let defaults: UserDefaults
    let directory: URL
    func pending() throws -> LiveTVPortableImport {
        try LiveTVPortableSyncAdapter(
            directory: directory, profileID: profiles.activeProfileID, defaults: defaults,
            namespace: profiles.activeNamespace
        ).pending(sourceStore: PortableImportSources())
    }
    func bridge(
        definitions: any LibraryChannelDefinitionStoring, snapshots: any LibraryChannelSnapshotStoring,
        captureIdentityRevision: (@MainActor (String) async throws -> UUID)? = nil
    ) -> LiveTVPortableSyncBridge {
        LiveTVPortableSyncBridge(
            profiles: profiles, directory: directory, defaults: defaults,
            sourceStore: { _ in PortableImportSources() }, definitions: { _ in definitions }, snapshots: snapshots,
            captureIdentityRevision: captureIdentityRevision
        )
    }
}

private final class PortableExportBuilds: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func make(
        _ definitions: [LibraryChannelDefinition], _ snapshots: [LibraryChannelSnapshot]
    ) throws -> LiveTVPortableLibraryExport {
        lock.withLock { value += 1 }
        return try LiveTVPortableLibraryExport(definitions: definitions, snapshots: snapshots)
    }
}

private struct PortableImportSources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration { .empty }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private final class PortableImportDefinitions: LibraryChannelDefinitionCompareAndSwapping, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var values: [LibraryChannelDefinition]
    private let failsSave: Bool
    init(values: [LibraryChannelDefinition] = [], failsSave: Bool = false) {
        self.values = values
        self.failsSave = failsSave
    }
    func load() throws -> [LibraryChannelDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
    func save(_ definitions: [LibraryChannelDefinition]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failsSave else { throw LibraryChannelError.storageFailed }
        values = definitions
    }
    func save(_ definitions: [LibraryChannelDefinition], ifUnchangedFrom expected: [LibraryChannelDefinition]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard values == expected else { throw LibraryChannelError.publicationConflict }
        try save(definitions)
    }
}

private actor RetainingImportSnapshots: LibraryChannelSnapshotStaging {
    private let store = LibraryChannelSnapshotStore(databaseURL: nil)
    private var stageCount = 0
    private var insertCount = 0
    private var releaseCount = 0
    private(set) var readCount = 0
    private let afterStage: (@Sendable () async throws -> Void)?
    init(afterStage: (@Sendable () async throws -> Void)? = nil) { self.afterStage = afterStage }
    func seed(_ snapshot: LibraryChannelSnapshot, profileID: String) async throws {
        try await store.insert(snapshot, profileID: profileID)
    }
    func counts() -> (stages: Int, inserts: Int, releases: Int) { (stageCount, insertCount, releaseCount) }
    func snapshot(id: UUID, profileID: String) async throws -> LibraryChannelSnapshot? {
        readCount += 1
        return try await store.snapshot(id: id, profileID: profileID)
    }
    func changeRevision() async throws -> UUID? {
        try await store.changeRevision()
    }
    func insert(_ snapshot: LibraryChannelSnapshot, profileID: String) async throws {
        insertCount += 1
        try await store.insert(snapshot, profileID: profileID)
        try await store.retain(ids: [], profileID: profileID)
    }
    func stage(_ snapshots: [LibraryChannelSnapshot], profileID: String) async throws -> LibraryChannelSnapshotLease {
        stageCount += 1
        let lease = try await store.stage(snapshots, profileID: profileID)
        do {
            try await store.retain(ids: [], profileID: profileID)
            try await afterStage?()
            return lease
        } catch {
            await store.release(lease)
            throw error
        }
    }
    func release(_ lease: LibraryChannelSnapshotLease) async {
        releaseCount += 1
        await store.release(lease)
    }
    func retain(ids: Set<UUID>, profileID: String) async throws {
        try await store.retain(ids: ids, profileID: profileID)
    }
    func retainReferenced(by definitions: any LibraryChannelDefinitionStoring, profileID: String) async throws {
        try await store.retainReferenced(by: definitions, profileID: profileID)
    }
}
#endif
