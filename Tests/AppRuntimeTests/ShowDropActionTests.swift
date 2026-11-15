@testable import AppRuntime
import CoreModels
import XCTest

/// Drop Show from a card's menu: it holds in Plozz at once, is mirrored to every
/// server that can record it, and is taken back when the show is watched again.
@MainActor
final class ShowDropActionTests: XCTestCase {
    private func episode(account: String = "jellyfin") -> MediaItem {
        var item = MediaItem(id: "e1", title: "Episode", kind: .episode, sourceAccountID: account)
        item.seriesID = "series"
        item.providerIDs = ["SeriesTvdb": "81189"]
        return item
    }

    private func coordinator(
        _ dropped: DroppedShowsModel, providers: [String: any MediaProvider],
        failures: @escaping () -> Void = {}
    ) -> MediaItemActionCoordinator {
        MediaItemActionCoordinator(
            providerResolver: { $0.flatMap { providers[$0] } },
            providerCapabilityResolver: { _ in (true, false, false) },
            primaryAccountID: { "jellyfin" },
            crossServerWatchSyncEnabled: { true },
            enqueueWatchMutation: { _ in },
            makeWatchlistFailureFeedback: { failures },
            droppedShows: { dropped }
        )
    }

    private func model() -> DroppedShowsModel {
        DroppedShowsModel(store: DroppedShowsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    func testDropShowHoldsLocallyAndIsSentToTheServer() async throws {
        let dropped = model()
        let server = DropRecordingProvider()
        let coordinator = coordinator(dropped, providers: ["jellyfin": server])
        let item = episode()

        XCTAssertEqual(coordinator.actions(for: item, context: .continueWatching).last, .dropShow)
        coordinator.perform(.dropShow, on: item, context: .continueWatching)

        XCTAssertTrue(dropped.isDropped(item))
        XCTAssertEqual(coordinator.actions(for: item, context: .continueWatching).last, .undropShow)
        try await waitUntil { await server.writes.count == 1 }
        let writes = await server.writes
        XCTAssertEqual(writes.first?.dropped, true)
        XCTAssertEqual(writes.first?.seriesID, "series", "The server is told about the show, not the episode")
    }

    func testUndropShowClearsItEverywhere() async throws {
        let dropped = model()
        dropped.drop(episode())
        let server = DropRecordingProvider()
        coordinator(dropped, providers: ["jellyfin": server]).perform(.undropShow, on: episode(), context: .none)

        XCTAssertFalse(dropped.isDropped(episode()))
        try await waitUntil { await server.writes.count == 1 }
        let dropFlag = await server.writes.first?.dropped
        XCTAssertEqual(dropFlag, false)
    }

    /// Finishing an episode, or marking one watched, takes the drop back.
    func testWatchingAnEpisodeTakesTheDropBack() async throws {
        let dropped = model()
        dropped.drop(episode())
        let server = DropRecordingProvider()
        let coordinator = coordinator(dropped, providers: ["jellyfin": server])

        MediaItemMutation(itemIDs: ["e2"], played: true, resumePosition: 0, playedPercentage: 1, item: {
            var next = episode()
            next.id = "e2"
            return next
        }()).post()

        try await waitUntil { await MainActor.run { !dropped.isDropped(self.episode()) } }
        try await waitUntil { await server.writes.count == 1 }
        let dropFlag = await server.writes.first?.dropped
        XCTAssertEqual(dropFlag, false)
        withExtendedLifetime(coordinator) {}
    }

    /// Progress alone is not "watched": a drop survives a partial play.
    func testAPartialPlayKeepsTheDrop() async throws {
        let dropped = model()
        dropped.drop(episode())
        let coordinator = coordinator(dropped, providers: [:])
        MediaItemMutation(itemIDs: ["e1"], resumePosition: 120, playedPercentage: 0.1, item: episode()).post()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(dropped.isDropped(episode()))
        withExtendedLifetime(coordinator) {}
    }

    /// A server that cannot be reached does not undo the drop, but is reported.
    func testAFailedServerWriteKeepsTheDropAndReportsIt() async throws {
        let dropped = model()
        let failed = expectation(description: "failure reported")
        let server = DropRecordingProvider(failing: true)
        coordinator(dropped, providers: ["jellyfin": server], failures: { failed.fulfill() })
            .perform(.dropShow, on: episode(), context: .none)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(dropped.isDropped(episode()))
    }

    /// A provider that cannot record drops still gets the local one.
    func testDroppingWorksWithoutAServerThatRecordsIt() {
        let dropped = model()
        coordinator(dropped, providers: [:]).perform(.dropShow, on: episode(account: "plex"), context: .none)
        XCTAssertTrue(dropped.isDropped(episode(account: "plex")))
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out")
    }
}

private actor DropWrites {
    private(set) var writes: [(dropped: Bool, itemID: String, seriesID: String?)] = []
    func record(_ dropped: Bool, _ itemID: String, _ seriesID: String?) { writes.append((dropped, itemID, seriesID)) }
}

private struct DropRecordingProvider: MediaProvider, ShowDropSyncing {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(id: "server", name: "Home", baseURL: URL(string: "https://media.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "TEST_TOKEN"
    )
    var failing = false
    private let recorded = DropWrites()

    init(failing: Bool = false) { self.failing = failing }

    var writes: [(dropped: Bool, itemID: String, seriesID: String?)] {
        get async { await recorded.writes }
    }

    func setShowDropped(_ dropped: Bool, itemID: String, seriesID: String?) async throws {
        if failing { throw AppError.serverUnreachable }
        await recorded.record(dropped, itemID, seriesID)
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
