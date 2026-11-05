import CoreModels
import XCTest
@testable import MediaDownloads

/// Download management keeps separate files independent; playback can prefer
/// one of these copies without requiring the selected server version on disk.
final class VersionScopedDownloadTests: XCTestCase {
    private func makeRegistry() -> DownloadedMediaRegistry {
        DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
    }

    private func movieSelecting(_ versionID: String?) -> MediaItem {
        var item = DownloadTestFactory.movie(imdb: "tt1375666", title: "Inception")
        item.selectedVersionID = versionID
        return item
    }

    func testTwoVersionsOfOneTitleCoexist() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let uhd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-4k", status: .completed
        )
        let hd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-1080", status: .completed
        )
        _ = try await registry.beginDownload(uhd)
        _ = try await registry.beginDownload(hd)

        XCTAssertNotEqual(
            uhd.identityKey,
            hd.identityKey,
            "each version needs its own key, or one download overwrites the other"
        )
        let all = await registry.all()
        XCTAssertEqual(all.count, 2)
    }

    func testLookupReturnsTheSelectedVersionNotJustAnyDownloadedCopy() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let uhd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-4k", status: .completed
        )
        let hd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-1080", status: .completed
        )
        _ = try await registry.beginDownload(uhd)
        _ = try await registry.beginDownload(hd)

        let found = await registry.record(
            for: movieSelecting("v-1080"), versionID: "v-1080"
        )
        XCTAssertEqual(found?.identityKey, hd.identityKey)
    }

    /// Download controls must allow another version to be saved separately.
    func testUndownloadedVersionReportsNoLocalCopy() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let hd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-1080", status: .completed
        )
        _ = try await registry.beginDownload(hd)

        let found = await registry.record(
            for: movieSelecting("v-4k"), versionID: "v-4k"
        )
        XCTAssertNil(
            found,
            "4K isn't downloaded, so its download control must not manage the 1080p file"
        )
    }

    /// "Is this title available offline at all?" must still see version-scoped
    /// copies, otherwise download badges and the offline library go blank.
    func testAnyVersionLookupStillFindsAVersionScopedDownload() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let uhd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-4k", status: .completed
        )
        _ = try await registry.beginDownload(uhd)

        let found = await registry.record(for: movieSelecting(nil))
        XCTAssertEqual(found?.identityKey, uhd.identityKey)
    }

    /// Records with no version concept keep their historic un-suffixed key.
    func testVersionlessRecordsKeepTheirOriginalKey() {
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")
        XCTAssertEqual(
            MediaIdentityKey.string(for: identity, versionID: nil),
            MediaIdentityKey.string(for: identity)
        )
        XCTAssertEqual(
            MediaIdentityKey.string(for: identity, versionID: ""),
            MediaIdentityKey.string(for: identity)
        )
    }

    func testPhysicalEpisodeChoicesCoexistWithNilOrCollidingProviderVersionIDs() async throws {
        for versionID: String? in [nil, "1"] {
            let registry = makeRegistry()
            let first = selectedEpisode(id: "file-a", versionID: versionID)
            let second = selectedEpisode(id: "file-b", versionID: versionID)
            XCTAssertEqual(DownloadMediaIdentity.primary(for: first), DownloadMediaIdentity.primary(for: second))
            let firstRecord = try selectedRecord(first)
            let secondRecord = try selectedRecord(second)
            XCTAssertNotEqual(firstRecord.identityKey, secondRecord.identityKey)
            _ = try await registry.beginDownloads([firstRecord, secondRecord])
            let all = await registry.all()
            XCTAssertEqual(all.count, 2)
            let foundFirst = await registry.record(for: first, versionID: versionID)
            let foundSecond = await registry.record(for: second, versionID: versionID)
            XCTAssertEqual(foundFirst?.identityKey, firstRecord.identityKey)
            XCTAssertEqual(foundSecond?.identityKey, secondRecord.identityKey)
            let playback = await registry.playbackRecords(for: first, preferring: versionID)
            XCTAssertEqual(Set(playback.map(\.identityKey)), Set(all.map(\.identityKey)))
            XCTAssertEqual(firstRecord.versionID, versionID, "Provider IDs must remain unqualified.")
        }
    }

    func testExplicitChoiceReusesOnlyItsOwnLegacyDownload() async throws {
        let first = selectedEpisode(id: "file-a", versionID: nil)
        let otherFile = selectedEpisode(id: "file-b", versionID: nil)
        let otherAccount = selectedEpisode(id: "file-a", versionID: nil, account: "other")
        var legacy = try DownloadTestFactory.record(
            identity: XCTUnwrap(DownloadMediaIdentity.primary(for: first)), status: .completed
        )
        legacy.snapshot = PinnedMediaSnapshot(item: first)
        XCTAssertEqual(
            DownloadMediaIdentity.requestIdentity(for: first, existingRecords: [legacy]), legacy.identity
        )
        for other in [otherFile, otherAccount] {
            XCTAssertNotEqual(
                DownloadMediaIdentity.requestIdentity(for: other, existingRecords: [legacy]), legacy.identity
            )
            XCTAssertNil(DownloadMediaIdentity.selectedRecord(for: other, in: [legacy]))
            let registry = makeRegistry()
            _ = try await registry.beginDownload(legacy)
            let found = await registry.record(for: other, versionID: nil)
            XCTAssertNil(found)
        }
    }

    func testAnyVersionLookupFindsSeveralSourceScopedCopies() async throws {
        let registry = makeRegistry()
        let first = try selectedRecord(selectedEpisode(id: "file-a", versionID: "1"))
        let second = try selectedRecord(selectedEpisode(id: "file-a", versionID: "2"))
        _ = try await registry.beginDownloads([first, second])
        var item = selectedEpisode(id: "file-a", versionID: nil)
        item.explicitSourceSelection = false
        let found = await registry.record(for: item)
        XCTAssertNotNil(found)
    }

    private func selectedEpisode(
        id: String, versionID: String?, account: String = "fixture"
    ) -> MediaItem {
        var item = MediaItem(
            id: id, title: "First Light", kind: .episode,
            seasonNumber: 1, episodeNumber: 1, seriesID: "show",
            providerIDs: ["tvdb": "12345"], sourceAccountID: account
        )
        item.selectedVersionID = versionID
        item.explicitSourceSelection = true
        return item
    }

    private func selectedRecord(_ item: MediaItem) throws -> DownloadedMediaRecord {
        var record = try DownloadTestFactory.record(
            identity: XCTUnwrap(DownloadMediaIdentity.requestIdentity(for: item, existingRecords: [])),
            versionID: item.selectedVersionID, status: .completed
        )
        record.snapshot = PinnedMediaSnapshot(item: item)
        return record
    }
}
