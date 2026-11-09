import Foundation
import CoreModels
import XCTest
@testable import MediaDownloads

final class ManagedDownloadLifecycleTests: XCTestCase {
    func testOnlyHLSRenditionsRequireUncappedTransfers() {
        for provider: ProviderKind in [.plex, .jellyfin, .emby, .silo] {
            for allAudio in [false, true] {
                for quality: DownloadQuality in [.original, .hd720] {
                    let source = ManagedHTTPDownloadSource(
                        provider: provider, accountID: "account", itemID: "movie",
                        quality: quality, includesAllAudioTracks: allAudio)
                    XCTAssertEqual(source.requiresUncappedRenditionTransfer,
                                   quality != .original && (provider == .jellyfin || (provider == .emby && !allAudio)))
                }
            }
        }
    }

    func testAudioPreparationReferencesAreIndependentAndDurable() throws {
        let primary = ManagedHTTPPreparationReference(queueIdentifier: "video", itemIdentifier: "1")
        let extra = ManagedHTTPPreparationReference(queueIdentifier: "audio", itemIdentifier: "2")
        let source = ManagedHTTPDownloadSource(
            provider: .plex, accountID: "account", itemID: "movie", quality: .hd720,
            includesAllAudioTracks: true, preparationReference: primary
        ).replacingPreparationReference(extra, audioTrackID: 2)
        let restored = try JSONDecoder().decode(ManagedHTTPDownloadSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored.preparationReference, primary)
        XCTAssertEqual(restored.audioPreparationReferences, [2: extra])
        let cleared = restored.replacingPreparationReference(nil, audioTrackID: 2)
        XCTAssertEqual(cleared.preparationReference, primary)
        XCTAssertTrue(cleared.audioPreparationReferences.isEmpty)
        XCTAssertTrue(cleared.includesAllAudioTracks)
    }

    func testLegacySourceHasNoAudioPreparationReferences() throws {
        let source = ManagedHTTPDownloadSource(provider: .plex, accountID: "account", itemID: "movie")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        json.removeValue(forKey: "audioPreparationReferences")
        let restored = try JSONDecoder().decode(
            ManagedHTTPDownloadSource.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertTrue(restored.audioPreparationReferences.isEmpty)
        XCTAssertFalse(restored.includesAllAudioTracks)
    }

    func testNewManagedDownloadsDefaultToPreferredAudioAndAvailableTextSubtitles() throws {
        for provider: ProviderKind in [.plex, .jellyfin, .emby, .silo] {
            for quality: DownloadQuality in [.original, .hd720] {
                let source = ManagedHTTPDownloadSource(
                    provider: provider, accountID: "account", itemID: "movie",
                    quality: quality, preferredAudioLanguages: ["fr"]
                )
                XCTAssertFalse(source.includesAllAudioTracks)
                XCTAssertTrue(source.includesTextSubtitleTracks)
                XCTAssertEqual(source.preferredAudioLanguages, ["fr"])
                XCTAssertEqual(source.quality, quality)
                XCTAssertEqual(try JSONDecoder().decode(
                    ManagedHTTPDownloadSource.self, from: JSONEncoder().encode(source)
                ), source)
            }
        }
    }

    func testExistingDownloadTrackSelectionsSurviveReload() throws {
        var download = try record()
        download.managedHTTPSource = .init(
            provider: .jellyfin, accountID: "account", itemID: "movie",
            quality: .hd720, includesAllAudioTracks: true, includesTextSubtitleTracks: false,
            preferredAudioLanguages: ["de"]
        )
        let restored = try JSONDecoder().decode(
            DownloadedMediaRecord.self, from: JSONEncoder().encode(download)
        )
        XCTAssertEqual(restored, download)
        XCTAssertTrue(try XCTUnwrap(restored.managedHTTPSource).includesAllAudioTracks)
        XCTAssertFalse(try XCTUnwrap(restored.managedHTTPSource).includesTextSubtitleTracks)
    }

    private func record() throws -> DownloadedMediaRecord {
        var record = try DownloadTestFactory.record(status: .completed)
        record.sourceKind = .managedHTTP
        record.managedHTTPSource = ManagedHTTPDownloadSource(
            provider: .silo, accountID: "account", itemID: "movie1", mediaSourceID: "42",
            preparationReference: .init(queueIdentifier: "silo:2", itemIdentifier: "download1"))
        return record
    }

    func testRemoteDeletionSurvivesLocalRecordRemovalAndRelaunch() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try record()
        _ = try await registry.beginDownload(record)
        try await registry.remove(identityKey: record.identityKey)
        let reloaded = DownloadedMediaRegistry(store: store)
        let local = await reloaded.record(forKey: record.identityKey)
        let pending = await reloaded.pendingManagedRemovals()
        XCTAssertNil(local)
        XCTAssertEqual(pending, [try XCTUnwrap(record.managedHTTPSource)])
        try await reloaded.acknowledgeManagedRemoval(pending[0])
        let acknowledged = await reloaded.pendingManagedRemovals()
        XCTAssertTrue(acknowledged.isEmpty)
    }

    func testCompletionCanBeRetriedWithoutRedownloadingMedia() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try record()
        _ = try await registry.beginDownload(record)
        let pending = await registry.pendingManagedCompletions()
        XCTAssertEqual(pending.count, 1)
        let entry = try XCTUnwrap(pending.first)
        try await registry.acknowledgeManagedCompletion(identityKey: entry.identityKey, at: entry.updatedAt)
        let reloaded = DownloadedMediaRegistry(store: store)
        let remaining = await reloaded.pendingManagedCompletions()
        let available = await reloaded.record(forKey: entry.identityKey)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(available?.status, .completed)
    }

    func testOldDownloadStateDecodesWithoutNewOutboxes() throws {
        let state = try JSONDecoder().decode(DownloadedMediaRegistryState.self, from: Data(#"{"records":{}}"#.utf8))
        XCTAssertTrue(state.pendingManagedRemovals.isEmpty)
        XCTAssertTrue(state.managedCompletionAcknowledgements.isEmpty)
    }
}
