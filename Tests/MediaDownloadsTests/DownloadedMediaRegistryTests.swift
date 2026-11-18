import CoreModels
import XCTest
@testable import MediaDownloads

final class DownloadedMediaRegistryTests: XCTestCase {
    func testSubtitleWarningAcknowledgementIsDurableAndCannotConsumeANewerFailure() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try await registry.beginDownload(DownloadTestFactory.record())
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 10, subtitleStatus: .unavailable)
        let first = await registry.record(forKey: record.identityKey)
        let firstWarning = try XCTUnwrap(first?.subtitleWarningID)
        let decoded = try JSONDecoder().decode(
            DownloadedMediaRegistryState.self, from: JSONEncoder().encode(store.load())
        )
        XCTAssertEqual(decoded.records[record.identityKey]?.subtitleWarningID, firstWarning)
        try await registry.setSubtitleStatus(identityKey: record.identityKey, .unavailable)
        try await registry.acknowledgeSubtitleWarning(identityKey: record.identityKey, warningID: firstWarning)
        let second = await registry.record(forKey: record.identityKey)
        let secondWarning = try XCTUnwrap(second?.subtitleWarningID)
        XCTAssertNotEqual(secondWarning, firstWarning)
        try await registry.acknowledgeSubtitleWarning(identityKey: record.identityKey, warningID: secondWarning)
        let acknowledged = await DownloadedMediaRegistry(store: store).record(forKey: record.identityKey)
        XCTAssertNil(acknowledged?.subtitleWarningID)
        XCTAssertEqual(acknowledged?.subtitleStatus, .unavailable)
        try await registry.setSubtitleStatus(identityKey: record.identityKey, .unavailable)
        try await registry.setSubtitleStatus(identityKey: record.identityKey, .saved)
        let recovered = await registry.record(forKey: record.identityKey)
        XCTAssertNil(recovered?.subtitleWarningID)
    }

    func testLegacyDownloadDoesNotInventASubtitleWarning() throws {
        let record = try DownloadTestFactory.record(status: .completed)
        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["subtitleWarningID"])
        let decoded = try JSONDecoder().decode(DownloadedMediaRecord.self, from: data)
        XCTAssertNil(decoded.subtitleWarningID)
    }

    func testCancelledArtworkCannotAttach() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let original = try DownloadTestFactory.record(status: .completed)
        _ = try await registry.beginDownload(original)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await registry.setArtworkFileName(
                identityKey: original.identityKey, fileName: "cancelled.jpg",
                expectedCreatedAt: original.createdAt
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled artwork must not be attached.")
        } catch is CancellationError {
        }
        let current = await registry.record(forKey: original.identityKey)
        XCTAssertNil(current?.snapshot.artworkFileName)
        XCTAssertEqual(current?.status, .completed)
    }

    func testArtworkCannotAttachToARemovedAndRecreatedDownload() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let original = try DownloadTestFactory.record(status: .completed)
        _ = try await registry.beginDownload(original)
        try await registry.remove(identityKey: original.identityKey)
        var replacement = original
        replacement.createdAt = original.createdAt.addingTimeInterval(1)
        _ = try await registry.beginDownload(replacement)

        let attached = try await registry.setArtworkFileName(
            identityKey: original.identityKey, fileName: "old.jpg",
            expectedCreatedAt: original.createdAt
        )
        XCTAssertFalse(attached)
        let current = await registry.record(forKey: original.identityKey)
        XCTAssertNil(current?.snapshot.artworkFileName)
        XCTAssertEqual(current?.status, .completed)
    }

    func testAttachingArtworkPreservesCompletionAndSurvivesReload() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let original = try DownloadTestFactory.record(status: .completed, bytesDownloaded: 100, totalBytes: 100)
        _ = try await registry.beginDownload(original)
        let attached = try await registry.setArtworkFileName(
            identityKey: original.identityKey, fileName: "artwork.jpg",
            expectedCreatedAt: original.createdAt
        )
        XCTAssertTrue(attached)
        let reloaded = await DownloadedMediaRegistry(store: store).record(forKey: original.identityKey)
        XCTAssertEqual(reloaded?.snapshot.artworkFileName, "artwork.jpg")
        XCTAssertEqual(reloaded?.status, .completed)
        XCTAssertEqual(reloaded?.bytesDownloaded, 100)
        XCTAssertEqual(reloaded?.totalBytes, 100)
    }

    func testPosterAttachmentSurvivesEnrichmentAndRejectsStaleOrCancelledWork() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        var original = try DownloadTestFactory.record(status: .completed)
        original.snapshot.artworkFileName = "landscape.jpg"
        _ = try await registry.beginDownload(original)
        let attached = try await registry.setArtworkFileName(
            identityKey: original.identityKey, fileName: "poster.jpg", role: .poster,
            expectedCreatedAt: original.createdAt
        )
        XCTAssertTrue(attached)
        try await registry.enrichSnapshot(
            identityKey: original.identityKey, expectedCreatedAt: original.createdAt,
            snapshot: .init(title: "Updated", kind: .movie)
        )
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await registry.setArtworkFileName(
                identityKey: original.identityKey, fileName: "cancelled.jpg", role: .poster
            )
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled posters must not attach.")
        } catch is CancellationError {}
        let stale = try await registry.setArtworkFileName(
            identityKey: original.identityKey, fileName: "stale.jpg", role: .poster,
            expectedCreatedAt: original.createdAt.addingTimeInterval(-1)
        )
        XCTAssertFalse(stale)
        let reloaded = await DownloadedMediaRegistry(store: store).record(forKey: original.identityKey)
        XCTAssertEqual(reloaded?.snapshot.artworkFileName, "landscape.jpg")
        XCTAssertEqual(reloaded?.snapshot.posterArtworkFileName, "poster.jpg")
        XCTAssertEqual(reloaded?.snapshot.title, "Updated")
        XCTAssertEqual(reloaded?.status, .completed)
    }

    func testPinnedPosterSchemaReadsLegacySnapshotsAndRoundTripsNewOnes() throws {
        var snapshot = PinnedMediaSnapshot(title: "Movie", kind: .movie, artworkFileName: "landscape.jpg")
        let legacy = try JSONEncoder().encode(snapshot)
        let decodedLegacy = try JSONDecoder().decode(PinnedMediaSnapshot.self, from: legacy)
        XCTAssertNil(decodedLegacy.posterArtworkFileName)
        XCTAssertEqual(decodedLegacy.artworkFileName, "landscape.jpg")
        snapshot.posterArtworkFileName = "poster.jpg"
        XCTAssertEqual(
            try JSONDecoder().decode(PinnedMediaSnapshot.self, from: JSONEncoder().encode(snapshot)),
            snapshot
        )
    }

    func testBeginDownloadRoundTripsThroughStore() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try DownloadTestFactory.record(status: .downloading)

        _ = try await registry.beginDownload(record)

        // A fresh registry over the SAME store sees the persisted record.
        let reloaded = DownloadedMediaRegistry(store: store)
        let loaded = await reloaded.record(forKey: record.identityKey)
        XCTAssertEqual(loaded?.identityKey, record.identityKey)
        XCTAssertEqual(loaded?.status, .downloading)
    }

    func testBeginDownloadIsIdempotentAndPreservesProgress() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let identity = DownloadTestFactory.imdbIdentity()

        // First marker, then real progress recorded.
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )
        try await registry.updateProgress(
            identityKey: MediaIdentityKey.string(for: identity),
            bytesDownloaded: 40,
            totalBytes: 100
        )

        // Re-issuing the begin marker (e.g. after a relaunch) must NOT rewind the
        // 40 bytes already on disk back to zero.
        let reissued = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .queued)
        )
        XCTAssertEqual(reissued.bytesDownloaded, 40)
        XCTAssertEqual(reissued.totalBytes, 100)
    }

    func testBeginDownloadKeepsCompletedRecordUntouched() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = DownloadTestFactory.imdbIdentity()
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )
        try await registry.markCompleted(
            identityKey: MediaIdentityKey.string(for: identity), totalBytes: 100
        )

        let again = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .queued, bytesDownloaded: 0)
        )
        XCTAssertEqual(again.status, .completed)
        XCTAssertEqual(again.bytesDownloaded, 100)
    }

    func testLateProgressDoesNotReopenCompletedRecord() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let record = try DownloadTestFactory.record(
            status: .downloading,
            bytesDownloaded: 40
        )
        _ = try await registry.beginDownload(record)
        try await registry.markCompleted(
            identityKey: record.identityKey,
            totalBytes: 100
        )

        try await registry.updateProgress(
            identityKey: record.identityKey,
            bytesDownloaded: 80,
            totalBytes: 100
        )

        let completed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.bytesDownloaded, 100)
    }

    func testRecordForItemMatchesAnyCrossServerIdentity() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .completed)
        )
        // An item carrying the same imdb id (even from a different server) resolves.
        let item = DownloadTestFactory.movie(imdb: "tt1375666", title: "Inception")
        let found = await registry.record(for: item)
        XCTAssertEqual(found?.identity, identity)
    }

    func testRecordForItemMatchesUniqueAccountScopedFallbackByItemID() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = MediaIdentity.external(
            source: "plozz-account:share-account",
            value: "episode-7"
        )
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .completed)
        )
        let item = MediaItem(id: "episode-7", title: "Episode 7", kind: .episode)

        let found = await registry.record(for: item)

        XCTAssertEqual(found?.identity, identity)
    }

    func testRecordForItemRejectsAmbiguousAccountScopedFallback() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        for account in ["one", "two"] {
            let identity = MediaIdentity.external(
                source: "plozz-account:\(account)",
                value: "episode-7"
            )
            _ = try await registry.beginDownload(
                try DownloadTestFactory.record(identity: identity, status: .completed)
            )
        }
        let item = MediaItem(id: "episode-7", title: "Episode 7", kind: .episode)

        let found = await registry.record(for: item)

        XCTAssertNil(found)
    }

    func testRecordForItemUsesSourceAccountToDisambiguateFallback() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        for account in ["one", "two"] {
            let identity = MediaIdentity.external(
                source: "plozz-account:\(account)",
                value: "episode-7"
            )
            _ = try await registry.beginDownload(
                try DownloadTestFactory.record(identity: identity, status: .completed)
            )
        }
        let item = MediaItem(
            id: "episode-7",
            title: "Episode 7",
            kind: .episode,
            sourceAccountID: "two"
        )

        let found = await registry.record(for: item)

        XCTAssertEqual(
            found?.identity,
            .external(source: "plozz-account:two", value: "episode-7")
        )
    }

    func testStatusTransitionsAndRemoval() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let identity = DownloadTestFactory.imdbIdentity()
        let key = MediaIdentityKey.string(for: identity)
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )

        try await registry.setStatus(identityKey: key, .paused, failureReason: "user")
        let paused = await registry.record(forKey: key)
        XCTAssertEqual(paused?.status, .paused)
        XCTAssertEqual(paused?.failureReason, "user")

        try await registry.remove(identityKey: key)
        let removed = await registry.record(forKey: key)
        let all = await registry.all()
        XCTAssertNil(removed)
        XCTAssertTrue(all.isEmpty)
    }

    func testEmitsProgressEvents() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let stream = await registry.events()
        let identity = DownloadTestFactory.imdbIdentity()

        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading, groupID: "season-1")
        )

        var sawItem = false
        var sawGroup = false
        var sawGlobal = false
        var iterator = stream.makeAsyncIterator()
        // Three events are emitted for the single write: item + group + global.
        for _ in 0..<3 {
            switch await iterator.next() {
            case .item: sawItem = true
            case .group(let g): sawGroup = (g.groupID == "season-1")
            case .global: sawGlobal = true
            default: break
            }
        }
        XCTAssertTrue(sawItem)
        XCTAssertTrue(sawGroup)
        XCTAssertTrue(sawGlobal)
    }
}
