import XCTest
import CoreModels
@testable import AppRuntime

final class PlaybackWatchPolicyTests: XCTestCase {
    private func movie(resume: TimeInterval? = nil) -> MediaItem {
        MediaItem(
            id: "movie", title: "Movie", kind: .movie, runtime: 7_200,
            resumePosition: resume, providerIDs: ["Tmdb": "123"], sourceAccountID: "origin"
        )
    }

    func testShortProgressIsDurableEvenBeforeContinueWatchingAdmission() {
        let item = movie()
        for position in [0.0, 1] {
            XCTAssertNil(WatchMutationFactory.playbackStop(
                item: item, position: position, watchedPercent: position / 72,
                primaryAccountID: "origin", reportTraktProgress: true
            ))
        }
        for position in [2.0, 10, 30, 59.999, 60, 120] {
            let mutation = WatchMutationFactory.playbackStop(
                item: item, position: position, watchedPercent: position / 72,
                primaryAccountID: "origin", reportTraktProgress: true
            )
            XCTAssertEqual(mutation?.resumePosition, position)
            XCTAssertNotNil(mutation?.traktProgress)
        }
    }

    func testExistingResumeAndCompletedShortContentAreNotDiscarded() {
        XCTAssertEqual(WatchMutationFactory.playbackStop(
            item: movie(resume: 15), position: 20, watchedPercent: 1,
            primaryAccountID: "origin"
        )?.resumePosition, 20)
        XCTAssertEqual(WatchMutationFactory.playbackStop(
            item: movie(), position: 45, watchedPercent: 100,
            primaryAccountID: "origin"
        )?.played, true)
    }

    func testTrailerUpdatesOnlyItselfWithoutParentExpansionOrTrackerWrites() throws {
        var trailer = movie().markingAsTrailer()
        trailer.id = "trailer"
        let otherCopy = MediaSourceRef(accountID: "other", itemID: "movie-copy", providerKind: .plex)
        for percent in [10.0, 100] {
            let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                item: trailer, position: 120, watchedPercent: percent,
                primaryAccountID: "origin", additionalSources: [otherCopy], reportTraktProgress: true
            ))
            XCTAssertEqual(mutation.targets.map(\.id), ["origin:trailer"])
            XCTAssertFalse(mutation.expansionPending)
            XCTAssertTrue(mutation.identities.isEmpty)
            XCTAssertNil(mutation.trakt)
            XCTAssertNil(mutation.traktProgress)
            XCTAssertEqual(mutation.played, percent == 100 ? true : nil)
            XCTAssertEqual(mutation.resumePosition, percent == 100 ? nil : 120)
            XCTAssertNotEqual(mutation.canonicalMediaID, WatchMutationFactory.playbackStop(
                item: movie(), position: 120, watchedPercent: percent, primaryAccountID: "origin"
            )?.canonicalMediaID)
        }
    }

    func testTrailerClassificationSurvivesPersistenceAndLegacyItemsStillDecode() throws {
        let encoded = try JSONEncoder().encode(movie().markingAsTrailer())
        XCTAssertTrue(try JSONDecoder().decode(MediaItem.self, from: encoded).isTrailer)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "isTrailer")
        legacy.removeValue(forKey: "isExtra")
        let restored = try JSONDecoder().decode(
            MediaItem.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertFalse(restored.isTrailer)
        XCTAssertFalse(restored.isExtra)
        XCTAssertTrue(MediaExtra(item: restored, kind: .trailer).playbackItem.isTrailer)
        XCTAssertFalse(MediaExtra(item: restored, kind: .featurette).playbackItem.isTrailer)
        XCTAssertTrue(MediaExtra(item: restored, kind: .featurette).playbackItem.isExtra)
    }

    func testSpecialFeatureNeverPropagatesParentIdentityOrTrackerWrites() throws {
        var item = movie()
        item.id = "featurette"
        let feature = MediaExtra(item: item, kind: .featurette).playbackItem
        for percent in [10.0, 100] {
            let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                item: feature, position: 15, watchedPercent: percent, primaryAccountID: "origin",
                additionalSources: [.init(accountID: "other", itemID: "movie-copy", providerKind: .plex)],
                reportTraktProgress: true
            ))
            XCTAssertEqual(mutation.targets.map(\.id), ["origin:featurette"])
            XCTAssertNil(mutation.trakt)
            XCTAssertNil(mutation.traktProgress)
            XCTAssertFalse(mutation.expansionPending)
            XCTAssertTrue(mutation.identities.isEmpty)
        }
    }

    func testManualTrailerWatchedToggleStaysOnItsOwnOrigin() throws {
        var trailer = movie().markingAsTrailer()
        trailer.id = "trailer"
        let mutation = try XCTUnwrap(WatchMutationFactory.playedToggle(
            item: trailer, played: true, primaryAccountID: "origin",
            additionalSources: [.init(accountID: "other", itemID: "movie-copy", providerKind: .plex)]
        ))
        XCTAssertEqual(mutation.targets.map(\.id), ["origin:trailer"])
        XCTAssertEqual(mutation.played, true)
        XCTAssertNil(mutation.trakt)
        XCTAssertNil(mutation.traktProgress)
        XCTAssertFalse(mutation.expansionPending)
        XCTAssertTrue(mutation.identities.isEmpty)
    }
}
