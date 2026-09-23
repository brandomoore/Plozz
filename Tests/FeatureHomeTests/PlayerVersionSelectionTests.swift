import CoreModels
import XCTest
@testable import FeatureHomeCore

final class PlayerVersionSelectionTests: XCTestCase {
    func testSDRAlternativesRequireKnownRangeAndExplicitSelection() throws {
        var item = movie("one", edition: "Theatrical").selectingVersion("file-2")
        item.versions[0].videoRange = "SDR"
        item.versions[1].videoRange = "HDR10"
        item.versions.append(.init(id: "unknown", height: 720))
        item.versions.append(.init(id: "foreign", videoRange: "SDR", sourceAccountID: "other"))
        let alternatives = PlayerVersionSelection.sdrAlternatives(for: item, mediaSourceID: "file-2")
        XCTAssertEqual(alternatives.map(\.id), ["file-1"])
        XCTAssertEqual(item.selectedVersionID, "file-2", "Finding an alternative must not change the selected version")
        XCTAssertEqual(PlayerVersionSelection.selecting("file-1", in: item)?.selectedVersionID, "file-1")
        XCTAssertTrue(PlayerVersionSelection.sdrAlternatives(for: item, mediaSourceID: "file-1").isEmpty)
        item.versions[0].sourceMetadata = .init(video: .init(videoRangeType: "HDR10"))
        XCTAssertTrue(PlayerVersionSelection.sdrAlternatives(for: item, mediaSourceID: "file-2").isEmpty)
    }

    private func movie(_ id: String, account: String = "server", edition: String) -> MediaItem {
        MediaItem(
            id: id, title: "Fixture", kind: .movie, providerIDs: ["Tmdb": "1"],
            sourceAccountID: account, edition: edition,
            versions: [
                .init(id: "file-1", edition: edition, height: 1080, isDefault: true),
                .init(id: "file-2", edition: edition, height: 2160)
            ]
        )
    }

    func testSameAccountEditionsKeepProviderIDsAndNeverSwitchServers() throws {
        let merged = try XCTUnwrap(MediaItemMerger.merge([
            movie("one", edition: "Theatrical"),
            movie("two", edition: "Extended"),
            movie("one", account: "other", edition: "Theatrical")
        ]).first)
        let item = merged.selectingSource(try XCTUnwrap(merged.sources.first { $0.accountID == "server" }))
        let versions = PlayerVersionSelection.versions(for: item)
        XCTAssertEqual(versions.count, 4)
        for version in versions {
            let selected = try XCTUnwrap(PlayerVersionSelection.selecting(version.id, in: item))
            XCTAssertEqual(selected.sourceAccountID, "server")
            XCTAssertEqual(selected.id, version.sourceItemID)
            XCTAssertEqual(selected.selectedVersionID, version.playbackMediaSourceID)
            XCTAssertTrue(PlayerVersionSelection.isSelected(version, item: selected, mediaSourceID: selected.selectedVersionID))
        }
        let foreign = try XCTUnwrap(merged.sources.first { $0.accountID == "other" }?.selectableVersions.first)
        XCTAssertNil(PlayerVersionSelection.selecting(foreign.id, in: item))
    }

    func testLightweightEntryUsesResolvedVersionsWithoutDiscardingMergedSources() {
        let full = movie("one", edition: "Theatrical")
        var opened = full
        opened.versions = []
        let combined = PlayerVersionSelection.item(opened: opened, resolved: full)
        XCTAssertEqual(PlayerVersionSelection.versions(for: combined).count, 2)
        XCTAssertEqual(combined.sourceAccountID, opened.sourceAccountID)
        XCTAssertEqual(PlayerVersionSelection.item(opened: opened, resolved: movie("two", edition: "Extended")), opened)
        XCTAssertEqual(PlayerVersionSelection.item(opened: opened, resolved: movie("one", account: "other", edition: "Theatrical")), opened)
    }

    func testRawVersionAndDefaultSelectionsAreUnambiguous() throws {
        let item = movie("one", edition: "Theatrical")
        let selected = try XCTUnwrap(PlayerVersionSelection.selecting("file-2", in: item))
        XCTAssertEqual(selected.id, "one")
        XCTAssertEqual(selected.selectedVersionID, "file-2")
        XCTAssertTrue(PlayerVersionSelection.isSelected(item.versions[1], item: item, mediaSourceID: "file-2"))
        XCTAssertFalse(PlayerVersionSelection.isSelected(item.versions[0], item: item, mediaSourceID: "file-2"))
        XCTAssertTrue(PlayerVersionSelection.isSelected(item.versions[0], item: item, mediaSourceID: nil))
        XCTAssertNil(PlayerVersionSelection.selecting("missing", in: item))
    }

    func testResolvedFilesRefreshOnlyThePlayingSourceInACombinedTitle() throws {
        var lightweight = movie("one", edition: "Theatrical")
        lightweight.versions = [lightweight.versions[0]]
        let merged = try XCTUnwrap(MediaItemMerger.merge([
            lightweight,
            movie("two", edition: "Extended"),
            movie("one", account: "other", edition: "Theatrical")
        ]).first)
        let source = try XCTUnwrap(merged.sources.first {
            $0.accountID == "server" && $0.itemID == "one"
        })
        let opened = merged.selectingSource(source)
        let refreshed = PlayerVersionSelection.item(
            opened: opened, resolved: movie("one", edition: "Theatrical")
        )
        let versions = PlayerVersionSelection.versions(for: refreshed)
        XCTAssertEqual(versions.count, 4)
        XCTAssertEqual(versions.filter { $0.sourceItemID == "one" }.count, 2)
        XCTAssertEqual(
            refreshed.sources.filter { $0.accountID != "server" || $0.itemID != "one" },
            opened.sources.filter { $0.accountID != "server" || $0.itemID != "one" }
        )
        let version = try XCTUnwrap(versions.first {
            $0.sourceItemID == "one" && $0.playbackMediaSourceID == "file-2"
        })
        let selected = try XCTUnwrap(PlayerVersionSelection.selecting(version.id, in: refreshed))
        XCTAssertEqual(selected.id, "one")
        XCTAssertEqual(selected.sourceAccountID, "server")
        XCTAssertEqual(selected.selectedVersionID, "file-2")
    }
}
