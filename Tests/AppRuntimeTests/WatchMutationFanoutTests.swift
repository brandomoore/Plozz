import XCTest
import CoreModels
@testable import AppRuntime

/// Guards the cross-server watch fan-out contract.
///
/// `additionalSources` carries the eager identity index's known servers for a
/// title. Omitting it silently narrows the fan-out to the item's own `sources`,
/// which is invisible at the call site and produces no error — the other server
/// simply never gets marked played. iOS shipped without it while tvOS passed it,
/// so a MOVIE reached from a Home row that only one server populated never
/// converged.
///
/// Scope note: episodes deliberately ignore `additionalSources` for fan-out (see
/// `targets(for:...)`) because a stale snapshot can hold a different episode of
/// the same series; they converge via the authoritative episode-expansion path
/// instead. So this parameter matters for movies and other non-episode kinds.
/// These tests pin both halves of that contract.
final class WatchMutationFanoutTests: XCTestCase {
    func testUnwatchedResetRetainsObservedServerTimeWithoutChangingTheActionClock() throws {
        let actionTime = Date(timeIntervalSince1970: 1_000)
        let serverTime = actionTime.addingTimeInterval(1)
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie, sourceAccountID: "origin",
            sources: [.init(accountID: "origin", itemID: "movie", lastPlayedAt: serverTime)],
            lastPlayedAt: serverTime
        )
        let reset = try XCTUnwrap(WatchMutationFactory.playedToggle(
            item: item, played: false, primaryAccountID: "origin", crossServerSync: false, capturedAt: actionTime
        ))
        XCTAssertEqual(reset.capturedAt, actionTime)
        XCTAssertEqual(reset.observedLastPlayedAt, ["origin:movie": serverTime])
        let watched = try XCTUnwrap(WatchMutationFactory.playedToggle(
            item: item, played: true, primaryAccountID: "origin", crossServerSync: false, capturedAt: actionTime
        ))
        XCTAssertTrue(watched.observedLastPlayedAt.isEmpty)
    }

    @MainActor
    func testMarkUnwatchedResetsProgressImmediatelyAndInDurableReplay() throws {
        for kind in [MediaItemKind.movie, .episode] {
            for played in [false, true] {
                let item = MediaItem(
                    id: "item", title: "Item", kind: kind,
                    resumePosition: 600, playedPercentage: 0.5,
                    isPlayed: played, sourceAccountID: "a",
                    sources: [.init(
                        accountID: "a", itemID: "item", kind: kind,
                        resumePosition: 600, playedPercentage: 0.5, isPlayed: played
                    )]
                )
                var queued: [WatchMutation] = []
                let coordinator = MediaItemActionCoordinator(
                    providerResolver: { _ in nil },
                    providerCapabilityResolver: { _ in (true, false, false) },
                    primaryAccountID: { "a" },
                    crossServerWatchSyncEnabled: { false },
                    enqueueWatchMutation: { queued.append($0) }
                )
                XCTAssertTrue(coordinator.actions(for: item, context: .none).contains(.markUnwatched))
                let received = expectation(forNotification: .mediaItemDidMutate, object: nil) { note in
                    guard let change = MediaItemMutation.from(note) else { return false }
                    XCTAssertEqual(change.played, false)
                    XCTAssertEqual(change.resumePosition, 0)
                    XCTAssertEqual(change.playedPercentage, 0)
                    let updated = change.applied(to: item)
                    XCTAssertFalse(updated.isPlayed)
                    XCTAssertFalse(updated.hasBeenPlayed)
                    XCTAssertNil(updated.resumePosition)
                    XCTAssertEqual(updated.playedPercentage, 0)
                    XCTAssertNil(updated.sources.first?.resumePosition)
                    XCTAssertEqual(updated.sources.first?.playedPercentage, 0)
                    return true
                }
                coordinator.perform(.markUnwatched, on: item, context: .none)
                wait(for: [received], timeout: 1)
                XCTAssertEqual(queued.count, 1)
                let intent = try XCTUnwrap(queued.first)
                XCTAssertEqual(intent.played, false)
                XCTAssertTrue(intent.clearResume)
                XCTAssertNil(intent.trakt)
                XCTAssertEqual(intent.targets.map(\.id), ["a:item"])
                XCTAssertFalse(intent.expansionPending)
                let restored = try JSONDecoder().decode(WatchMutation.self, from: JSONEncoder().encode(intent))
                let replay = try XCTUnwrap(MediaItemMutation(watchMutation: restored))
                XCTAssertNil(replay.applied(to: item).resumePosition)
                XCTAssertEqual(replay.applied(to: item).playedPercentage, 0)
                var otherAccount = item
                otherAccount.sourceAccountID = "b"
                otherAccount.sources = []
                XCTAssertEqual(replay.applied(to: otherAccount), otherAccount)
            }
        }
    }

    func testUnwatchedResetFansOutOnlyToTheSameTitle() throws {
        let peer = MediaSourceRef(accountID: "plex", itemID: "px", providerKind: .plex)
        let movie = makeItem()
        let intent = try XCTUnwrap(WatchMutationFactory.playedToggle(
            item: movie, played: false, primaryAccountID: nil, additionalSources: [peer]
        ))
        XCTAssertEqual(Set(intent.targets.map(\.id)), ["jellyfin-account:jf-1", "plex:px"])
        XCTAssertTrue(intent.clearResume)
        XCTAssertNil(intent.trakt)

        let episode = MediaItem(
            id: "e3", title: "Third", kind: .episode,
            seasonNumber: 1, episodeNumber: 3, seriesID: "show",
            resumePosition: 600, sourceAccountID: "jellyfin-account"
        )
        let episodeIntent = try XCTUnwrap(WatchMutationFactory.playedToggle(
            item: episode, played: false, primaryAccountID: nil,
            additionalSources: [.init(accountID: "plex", itemID: "e2", kind: .episode)]
        ))
        XCTAssertEqual(episodeIntent.targets.map(\.id), ["jellyfin-account:e3"])
        XCTAssertEqual(episodeIntent.seasonNumber, 1)
        XCTAssertEqual(episodeIntent.episodeNumber, 3)
        XCTAssertTrue(episodeIntent.expansionPending)
        XCTAssertTrue(episodeIntent.clearResume)
    }

    @MainActor
    func testSeasonMenuQueuesOnlyTheChosenSeasonAndPublishesItsCascade() throws {
        for played in [false, true] {
            var queued: [WatchMutation] = []
            let coordinator = MediaItemActionCoordinator(
                providerResolver: { _ in nil },
                primaryAccountID: { "a" },
                crossServerWatchSyncEnabled: { true },
                enqueueWatchMutation: { queued.append($0) }
            )
            let season = MediaItem(
                id: "s2", title: "Season 2", kind: .season,
                seasonNumber: 2, sourceAccountID: "a"
            )
            let received = expectation(forNotification: .mediaItemDidMutate, object: nil) { note in
                let mutation = MediaItemMutation.from(note)
                XCTAssertEqual(mutation?.scopedItemIDs, ["a:s2"])
                XCTAssertEqual(mutation?.cascadesToSeasonEpisodes, true)
                XCTAssertEqual(mutation?.played, played)
                XCTAssertEqual(mutation?.item, season)
                XCTAssertEqual(mutation?.kind, .season)
                return true
            }
            coordinator.perform(
                played ? .markWatched : .markUnwatched,
                on: season,
                context: MediaItemActionContext(precedingContainerIDs: ["s1"])
            )
            wait(for: [received], timeout: 1)
            let intent = try XCTUnwrap(queued.first)
            XCTAssertEqual(queued.count, 1)
            XCTAssertEqual(intent.targets.map(\.id), ["a:s2"])
            XCTAssertEqual(intent.kind, .season)
            XCTAssertEqual(intent.played, played)
        }
    }

    @MainActor
    func testMenuWatchActionsCarryKindAndParentForCountInvalidation() {
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in nil }, primaryAccountID: { "a" },
            crossServerWatchSyncEnabled: { true }, enqueueWatchMutation: { _ in })
        let show = MediaItem(
            id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: 8, sourceAccountID: "a")
        let unrelated = MediaItem(
            id: "unrelated", title: "Unrelated", kind: .series, unwatchedEpisodeCount: 12, sourceAccountID: "a")
        for kind in [MediaItemKind.movie, .episode] {
            let item = MediaItem(
                id: "item", title: "Item", kind: kind,
                seriesID: kind == .episode ? "show" : nil, sourceAccountID: "a")
            let received = expectation(forNotification: .mediaItemDidMutate, object: nil) { note in
                guard let mutation = MediaItemMutation.from(note) else { return false }
                XCTAssertEqual(mutation.item, item)
                XCTAssertEqual(mutation.kind, kind)
                XCTAssertEqual(mutation.applied(to: show).unwatchedEpisodeCount, kind == .episode ? nil : 8)
                XCTAssertEqual(mutation.applied(to: unrelated).unwatchedEpisodeCount, 12)
                return true
            }
            coordinator.perform(.markWatched, on: item, context: MediaItemActionContext())
            wait(for: [received], timeout: 1)
        }
    }

    private func makeItem() -> MediaItem {
        // A title reached from a Home row that only ONE server populated: it
        // carries no `sources` of its own, so the index is the only way to learn
        // about the other servers holding the same title.
        MediaItem(
            id: "jf-1",
            title: "Blade Runner",
            kind: .movie,
            sourceAccountID: "jellyfin-account"
        )
    }

    func testAdditionalSourcesExpandsFanoutBeyondTheOrigin() {
        let indexed = [
            MediaSourceRef(
                accountID: "plex-account",
                itemID: "46132",
                kind: .movie,
                providerKind: .plex
            )
        ]

        let withIndex = WatchMutationFactory.targets(
            for: makeItem(),
            primaryAccountID: nil,
            additionalSources: indexed
        )

        XCTAssertTrue(
            withIndex.contains { $0.accountID == "plex-account" && $0.itemID == "46132" },
            "the index's known Plex copy must be a fan-out target"
        )
        XCTAssertTrue(
            withIndex.contains { $0.accountID == "jellyfin-account" && $0.itemID == "jf-1" },
            "the origin must always remain a target"
        )
    }

    /// The regression itself: this is exactly what iOS was doing.
    func testOmittingAdditionalSourcesSilentlyLosesTheOtherServer() {
        let withoutIndex = WatchMutationFactory.targets(
            for: makeItem(),
            primaryAccountID: nil
        )

        XCTAssertFalse(
            withoutIndex.contains { $0.accountID == "plex-account" },
            "documents the failure mode: with no additionalSources the fan-out "
                + "cannot reach the other server, and does so without erroring"
        )
        XCTAssertEqual(
            withoutIndex.count,
            1,
            "origin only — the silent narrowing that lost cross-server sync"
        )
    }

    /// The deliberate exception, pinned so nobody "fixes" it by widening the
    /// episode path: a stale snapshot can hold a different episode of the same
    /// series, so episodes converge via episode-expansion, not pre-merged peers.
    func testEpisodesDeliberatelyIgnoreAdditionalSourcesForFanout() {
        let episode = MediaItem(
            id: "jf-ep",
            title: "Outside",
            kind: .episode,
            sourceAccountID: "jellyfin-account"
        )
        let indexed = [
            MediaSourceRef(
                accountID: "plex-account",
                itemID: "46132",
                kind: .episode,
                providerKind: .plex
            )
        ]

        let targets = WatchMutationFactory.targets(
            for: episode,
            primaryAccountID: nil,
            additionalSources: indexed
        )

        XCTAssertEqual(targets.map(\.accountID), ["jellyfin-account"])
    }
}
