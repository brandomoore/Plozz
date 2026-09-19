import Foundation
import XCTest
@testable import CoreModels

final class EditionPlaybackRoutingTests: XCTestCase {
    private func movie(
        _ id: String,
        account: String = "plex",
        edition: String = "Director's Cut",
        mediaIDs: [String] = ["101", "102"]
    ) -> MediaItem {
        MediaItem(
            id: id, title: "Fixture", kind: .movie,
            providerIDs: ["Tmdb": "99"],
            sourceAccountID: account,
            edition: edition,
            versions: mediaIDs.enumerated().map { index, id in
                MediaVersion(id: id, edition: edition, height: index == 0 ? 1080 : 2160)
            }
        )
    }

    func testEveryIntrinsicFileKeepsBothEditionItemAndProviderMediaID() throws {
        let theatrical = movie("10", edition: "Theatrical", mediaIDs: ["101", "102"])
        let extended = movie("20", edition: "Extended", mediaIDs: ["201", "202"])
        let merged = try XCTUnwrap(MediaItemMerger.merge([theatrical, extended]).first)

        XCTAssertEqual(merged.sources.count, 2)
        let choices = merged.sources.flatMap(\.selectableVersions)
        XCTAssertEqual(Set(choices.map(\.id)).count, 4)
        for choice in choices {
            let played = MediaItem.retargetedForPlayback(
                item: merged, sources: merged.sources,
                activeAccountID: "plex", versionID: choice.id, explicit: true
            )
            XCTAssertEqual(played.id, choice.sourceItemID)
            XCTAssertEqual(played.sourceAccountID, "plex")
            XCTAssertEqual(played.selectedVersionID, choice.playbackMediaSourceID)
            XCTAssertEqual(played.selectedVersion?.id, choice.playbackMediaSourceID)
            XCTAssertEqual(played.edition, choice.edition)
            XCTAssertTrue(played.explicitSourceSelection)
        }
    }

    func testLegacyRawIntrinsicChoiceFindsItsOwningSiblingNotFirstSource() throws {
        let merged = try XCTUnwrap(MediaItemMerger.merge([
            movie("10", mediaIDs: ["101", "102"]),
            movie("20", mediaIDs: ["201", "202"])
        ]).first)
        let played = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: "plex", versionID: "202"
        )
        XCTAssertEqual(played.id, "20")
        XCTAssertEqual(played.selectedVersionID, "202")
    }

    func testCollidingNumericIDsAreQualifiedByServerAndItem() throws {
        let merged = try XCTUnwrap(MediaItemMerger.merge([
            movie("10", account: "server-a"),
            movie("10", account: "server-b")
        ]).first)
        let first = try XCTUnwrap(merged.sources.first { $0.accountID == "server-a" })
        let second = try XCTUnwrap(merged.sources.first { $0.accountID == "server-b" })
        XCTAssertNotEqual(first.selectableVersions[0].id, second.selectableVersions[0].id)

        for requested in ["102", second.selectableVersions[1].id] {
            let played = MediaItem.retargetedForPlayback(
                item: merged, sources: merged.sources,
                activeAccountID: "server-b", versionID: requested
            )
            XCTAssertEqual(played.sourceAccountID, "server-b")
            XCTAssertEqual(played.selectedVersionID, "102")
        }
        let stale = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: "server-b", versionID: first.selectableVersions[1].id
        )
        XCTAssertEqual(stale.sourceAccountID, "server-b")
        XCTAssertNil(stale.selectedVersionID)
    }

    func testEvenSameServerDuplicateMediaIDsRequireAnUnambiguousChoice() throws {
        let merged = try XCTUnwrap(MediaItemMerger.merge([movie("10"), movie("20")]).first)
        let sibling = try XCTUnwrap(merged.sources.first { $0.itemID == "20" })
        let exact = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: "plex", versionID: sibling.selectableVersions[1].id
        )
        XCTAssertEqual(exact.id, "20")
        XCTAssertEqual(exact.selectedVersionID, "102")
        let ambiguous = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: "plex", versionID: "102"
        )
        XCTAssertEqual(ambiguous.id, "10")
        XCTAssertNil(ambiguous.selectedVersionID)
    }

    func testMixedSingleFileAndIntrinsicEditionsNeverSendSyntheticIDToProvider() throws {
        let single = movie("10", edition: "Theatrical", mediaIDs: [])
        let multiple = movie("20", edition: "Extended", mediaIDs: ["201", "202"])
        let merged = try XCTUnwrap(MediaItemMerger.merge([single, multiple]).first)
        let choices = merged.sources.flatMap(\.selectableVersions)
        XCTAssertEqual(choices.count, 3)
        let singleChoice = try XCTUnwrap(choices.first { $0.sourceItemID == "10" })
        XCTAssertEqual(singleChoice.editionLabel, "Theatrical")
        let played = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: "plex", versionID: singleChoice.id
        )
        XCTAssertEqual(played.id, "10")
        XCTAssertNil(played.selectedVersionID)
        XCTAssertEqual(played.edition, "Theatrical")
    }

    func testStaleSourceFallbackKeepsAnIntrinsicMediaIDAsWellAsBackingItem() {
        let primary = movie("10")
        let siblingFile = MediaVersion(
            id: "202", edition: "Extended", height: 2160,
            sourceItemID: "20", sourceAccountID: "plex"
        )
        let stale = MediaSourceRef(
            accountID: "plex", itemID: "10", kind: .movie,
            versions: primary.versions + [siblingFile]
        )
        let played = MediaItem.retargetedForPlayback(
            item: primary, sources: [stale],
            activeAccountID: "plex", versionID: "202", explicit: true
        )
        XCTAssertEqual(played.id, "20")
        XCTAssertEqual(played.selectedVersionID, "202")
        XCTAssertEqual(played.edition, "Extended")
    }

    func testVersionFromWrongKindCannotRetargetMovieOntoContainer() {
        let primary = movie("10")
        let series = MediaSourceRef(
            accountID: "plex", itemID: "series", kind: .series,
            versions: [MediaVersion(id: "202")]
        )
        let played = MediaItem.retargetedForPlayback(
            item: primary, sources: [series],
            activeAccountID: "plex", versionID: series.selectableVersions[0].id
        )
        XCTAssertEqual(played.id, "10")
        XCTAssertEqual(played.kind, .movie)
        XCTAssertNil(played.selectedVersionID)
    }

    func testStandaloneExplicitFileRetainsItsProviderIDAndProofForLaterRouting() {
        let item = movie("10")
        let played = MediaItem.retargetedForPlayback(
            item: item, sources: [], activeAccountID: "plex",
            versionID: "102", explicit: true
        )
        XCTAssertEqual(played.id, "10")
        XCTAssertEqual(played.selectedVersionID, "102")
        XCTAssertTrue(played.explicitSourceSelection)
        XCTAssertEqual(played.selectedSourceAccountID, "plex")
        XCTAssertEqual(played.sources.map(\.id), ["plex:10"])
    }

    func testEditionAndQualifiedVersionSurviveCodableButOpeningIntentDoesNot() throws {
        var original = movie("10", edition: "Final Cut", mediaIDs: [])
        original.editionOpeningSource = .init(accountID: "plex", itemID: "10")
        let source = MediaSourceRef(
            accountID: "plex", itemID: "10", kind: .movie,
            versions: [MediaVersion.synthesized(from: original)], edition: original.edition
        )
        original.sources = [source]
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.edition, "Final Cut")
        XCTAssertEqual(restored.sources[0].edition, "Final Cut")
        XCTAssertEqual(restored.sources[0].selectableVersions[0].editionLabel, "Final Cut")
        XCTAssertNil(restored.editionOpeningSource)
        XCTAssertFalse(restored.isMergedTitle)

        let intrinsic = movie("20").versions[1].qualified(accountID: "plex", itemID: "20")
        let decoded = try JSONDecoder().decode(MediaVersion.self, from: JSONEncoder().encode(intrinsic))
        XCTAssertEqual(decoded.id, intrinsic.id)
        XCTAssertEqual(decoded.playbackMediaSourceID, "102")
        XCTAssertEqual(decoded.qualified(accountID: "plex", itemID: "20"), intrinsic)
    }

    func testLegacyPayloadsDecodeWithoutNewFieldsAndKeepGenericMergedProvenance() throws {
        var value = movie("10")
        value.sources = [
            MediaSourceRef(accountID: "plex", itemID: "10"),
            MediaSourceRef(accountID: "plex", itemID: "20")
        ]
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        json.removeValue(forKey: "edition")
        json.removeValue(forKey: "isMergedTitle")
        let restored = try JSONDecoder().decode(
            MediaItem.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(restored.edition)
        XCTAssertTrue(restored.isMergedTitle)
        XCTAssertNil(restored.versions[0].providerMediaSourceID)
        XCTAssertEqual(restored.versions[0].playbackMediaSourceID, "101")
    }

    func testLabelsUseExplicitEditionThenNameThenRecognizedFilenameOnly() {
        XCTAssertEqual(
            MediaVersion(id: "1", name: "Fixture Extended", fileName: "Fixture.Theatrical.mkv",
                         edition: " Final Cut ").editionLabel,
            "Final Cut"
        )
        XCTAssertEqual(
            MediaVersion(id: "1", fileName: "Fixture.Extended.mkv").editionLabel,
            "Extended"
        )
        XCTAssertNil(MediaVersion(id: "1", fileName: "Fixture.2024.mkv").editionLabel)
        XCTAssertEqual(MediaVersion(id: "1", edition: "Final Cut").menuTitle, "Final Cut")
        XCTAssertEqual(
            MediaVersionDescriptor(version: MediaVersion(id: "1", edition: "Final Cut")).edition,
            "final cut"
        )
    }

    func testRoutedSiblingPreservesWatchStateAndExistingResumeReconciliation() {
        let primary = movie("10")
        let first = MediaSourceRef(
            accountID: "plex", itemID: "10", kind: .movie,
            versions: primary.versions, resumePosition: 400
        )
        let second = MediaSourceRef(
            accountID: "plex", itemID: "20", kind: .movie,
            versions: movie("20", mediaIDs: ["201", "202"]).versions,
            resumePosition: 200, isPlayed: false, hasBeenPlayed: true
        )
        let played = MediaItem.retargetedForPlayback(
            item: primary, sources: [first, second],
            activeAccountID: "plex", versionID: second.selectableVersions[1].id
        )
        XCTAssertEqual(played.id, "20")
        XCTAssertEqual(played.resumePosition, 400)
        XCTAssertFalse(played.isPlayed)
        XCTAssertTrue(played.hasBeenPlayed)
    }
}
