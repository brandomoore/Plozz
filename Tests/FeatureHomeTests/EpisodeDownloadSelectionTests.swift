import CoreModels
import XCTest
@testable import FeatureHomeCore

final class EpisodeDownloadSelectionTests: XCTestCase {
    private struct Preferences: VersionPreferenceStoring {
        var descriptor: MediaVersionDescriptor?
        func preferredVersionID(forTitle titleID: String) -> String? { nil }
        func setPreferredVersionID(_ versionID: String?, forTitle titleID: String) {}
        func preferredVersionDescriptor(forTitle titleID: String) -> MediaVersionDescriptor? { descriptor }
    }

    private func episode(_ id: String, number: Int = 1, account: String = "server") -> MediaItem {
        MediaItem(
            id: id, title: "Episode", kind: .episode,
            seasonNumber: 1, episodeNumber: number, seriesID: "show",
            sourceAccountID: account
        )
    }

    private func selection(_ items: [MediaItem]) -> EpisodeDownloadSelection {
        EpisodeDownloadSelection(items: items, preferences: Preferences(), capabilities: .default)
    }

    func testPathAliasesProduceOneEpisodeWithOneDefaultWithoutDeletingEitherChoice() throws {
        let link = episode("links/episode.mkv")
        let torrent = episode("torrents/episode.mkv")
        var model = selection([link, torrent, link])
        XCTAssertEqual(model.episodes.count, 1)
        let group = try XCTUnwrap(model.episodes.first)
        XCTAssertEqual(group.options.count, 2)
        XCTAssertEqual(model.selectedOptions.count, 1)
        XCTAssertNil(model.selectedOptions.first?.item.selectedVersionID, "Synthetic picker IDs must never reach providers.")
        for option in group.options { model.setSelected(true, optionID: option.id) }
        XCTAssertEqual(Set(model.selectedOptions.map(\.item.id)), Set([link.id, torrent.id]))
        model.setSelected(false, episode: group)
        XCTAssertTrue(model.selectedOptions.isEmpty)
        model.setSelected(true, episode: group)
        XCTAssertEqual(model.selectedOptions.map(\.id), [group.recommendedID])
    }

    func testConfirmationOnlySkipsAnUnambiguousSingleDownloadWithAlwaysAskOff() {
        for kind in [MediaItemKind.episode, .movie] {
            var item = episode("single")
            item.kind = kind
            let single = selection([item])
            XCTAssertFalse(single.requiresConfirmation(alwaysAsk: false, isBulk: false))
            XCTAssertTrue(single.requiresConfirmation(alwaysAsk: true, isBulk: false))
            XCTAssertTrue(single.requiresConfirmation(alwaysAsk: false, isBulk: true))
            item.versions = [.init(id: "hd", height: 1080), .init(id: "sd", height: 480)]
            XCTAssertTrue(selection([item]).requiresConfirmation(alwaysAsk: false, isBulk: false))
        }
        XCTAssertTrue(selection([episode("a"), episode("b")]).requiresConfirmation(alwaysAsk: false, isBulk: false))
        XCTAssertTrue(selection([]).requiresConfirmation(alwaysAsk: false, isBulk: false))
    }

    func testFifteenVersionsPerEpisodeKeepOnlyOneSelectedPerEpisode() {
        let items = (1...10).map { number -> MediaItem in
            var item = episode("episode-\(number)", number: number)
            item.versions = (1...15).map {
                MediaVersion(id: "file-\($0)", height: $0 == 1 ? 1080 : 720, sizeBytes: Int64($0 * 1_000))
            }
            return item
        }
        let model = selection(items)
        XCTAssertEqual(model.episodes.count, 10)
        XCTAssertEqual(model.episodes.flatMap(\.options).count, 150)
        XCTAssertEqual(model.selectedOptions.count, 10)
        XCTAssertEqual(Set(model.selectedOptions.map(\.item.id)).count, 10)
        XCTAssertTrue(model.selectedOptions.allSatisfy { $0.item.selectedVersionID == "file-1" })
    }

    func testGroupingPreservesAccountSeriesSeasonRangesAndConflictingMetadata() {
        let base = episode("a")
        var otherShow = episode("b"); otherShow.seriesID = "other"
        var otherSeason = episode("c"); otherSeason.seasonNumber = 2
        var range = episode("d"); range.episodeNumberEnd = 2
        var unnumbered = episode("e"); unnumbered.episodeNumber = nil
        var unknownAccount = episode("f"); unknownAccount.sourceAccountID = nil
        XCTAssertEqual(selection([
            base, otherShow, otherSeason, range, unnumbered, unknownAccount,
            episode("a", account: "other")
        ]).episodes.count, 7)
        var first = base; first.providerIDs = ["Tmdb": "1"]
        var conflict = episode("other-file"); conflict.providerIDs = ["tmdb": "2"]
        XCTAssertEqual(selection([first, conflict]).episodes.count, 2)
    }

    func testExplicitVersionOverridesRecommendationAndRetainsProviderFileIdentity() throws {
        var item = episode("episode")
        item.versions = [
            .init(id: "hd", height: 1080),
            .init(id: "sd", height: 480)
        ]
        item.selectedVersionID = "sd"
        let choice = try XCTUnwrap(selection([item]).selectedOptions.first)
        XCTAssertEqual(choice.item.id, item.id)
        XCTAssertEqual(choice.item.sourceAccountID, "server")
        XCTAssertEqual(choice.item.selectedVersionID, "sd")
        XCTAssertNotEqual(choice.id, "sd")
    }

    func testRememberedSeriesVersionShapeAppliesToAllEpisodes() {
        let items = (1...2).map { number -> MediaItem in
            var item = episode("episode-\(number)", number: number)
            item.versions = [
                .init(id: "hd-\(number)", height: 1080, videoRange: "SDR"),
                .init(id: "sd-\(number)", height: 480, videoRange: "SDR")
            ]
            return item
        }
        let model = EpisodeDownloadSelection(
            items: items, preferences: Preferences(descriptor: .init(height: 480, videoRange: "SDR")),
            capabilities: .default
        )
        XCTAssertEqual(model.selectedOptions.map(\.item.selectedVersionID), ["sd-1", "sd-2"])
    }

    func testExternalAndForeignAccountVersionsCannotEnterDownloadPlan() {
        var item = episode("episode")
        item.versions = [
            .init(id: "external", container: "strmlnk"),
            .init(id: "foreign", sourceItemID: "other", sourceAccountID: "other-account"),
            .init(id: "local", height: 1080)
        ]
        let model = selection([item])
        XCTAssertEqual(model.selectedOptions.map(\.item.selectedVersionID), ["local"])
        XCTAssertEqual(model.episodes.first?.options.count, 1)
    }

    func testCombinedPickerPreservesTheOwnerOfAnExplicitRawFileID() throws {
        var item = episode("first")
        let first = MediaSourceRef(
            accountID: "server", itemID: "first", kind: .episode,
            versions: [.init(id: "1", height: 720, sizeBytes: 100)]
        )
        let second = MediaSourceRef(
            accountID: "server", itemID: "second", kind: .episode,
            versions: [.init(id: "1", height: 1080, sizeBytes: 200)]
        )
        item.sources = [first, second]
        item.selectedVersionID = "1"
        let model = selection([item])
        XCTAssertEqual(model.episodes.first?.options.count, 2)
        let chosen = try XCTUnwrap(model.selectedOptions.first)
        XCTAssertEqual(chosen.item.id, "first")
        XCTAssertEqual(chosen.item.selectedVersionID, "1")
        XCTAssertEqual(chosen.item.sourceAccountID, "server")
    }
}
