import CoreModels
import SwiftUI
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerVersionMenuTests: XCTestCase {
    func testVersionControlAppearsOnlyForRealAlternativesAndPreservesOtherControls() {
        let controls = controlsWithoutSystemAudio()
        controls.engineCapabilities = [.playbackSpeed]
        XCTAssertEqual(controls.trackControlCategories, [.speed])
        controls.versions.options = [
            .init(version: .init(id: "current"), isSelected: true)
        ]
        XCTAssertEqual(controls.trackControlCategories, [.speed])
        controls.versions.options.append(.init(version: .init(id: "alternate"), isSelected: false))
        XCTAssertEqual(controls.trackControlCategories, [.speed, .playback])
    }

    func testSelectionForwardsQualifiedIdentityAndNeverRestartsTheSelectedFile() {
        let model = PlayerVersionMenuModel()
        let current = MediaVersion(id: "1").qualified(accountID: "server-a", itemID: "movie-a")
        let alternate = MediaVersion(id: "1").qualified(accountID: "server-a", itemID: "movie-b")
        model.options = [
            .init(version: current, isSelected: true),
            .init(version: alternate, isSelected: false)
        ]
        var selected: [String] = []
        model.onSelect = { selected.append($0) }
        model.select(current.id)
        XCTAssertTrue(selected.isEmpty)
        model.select(alternate.id)
        XCTAssertEqual(selected, [alternate.id])
        XCTAssertEqual(alternate.playbackMediaSourceID, "1")
        model.select("stale-version")
        XCTAssertEqual(selected, [alternate.id])
    }

    func testVersionRowsWrapSharedFactsAndRetainSelectionAction() throws {
        let controls = PlayerControlsModel()
        let version = MediaVersion(
            id: "file", fileName: "Movie.REMUX.mkv", height: 2160,
            duration: 7_200, videoCodec: "hevc", audioCodec: "truehd", audioChannels: 8,
            sourceMetadata: .init(audio: .init(language: "eng"), audioLanguages: ["fra"])
        )
        controls.versions.options = [.init(version: version, isSelected: false)]
        var selected: String?
        var closed = false
        controls.versions.onSelect = { selected = $0 }
        let row = try XCTUnwrap(PlayerOptionsPanel.versionRows(
            model: controls, locale: Locale(identifier: "en_US"), close: { closed = true }
        ).first)
        XCTAssertNil(row.titleLineLimit)
        XCTAssertEqual(row.facts, Text(verbatim: "Remux · HEVC · French, English · Dolby TrueHD 7.1 · 2h"))
        XCTAssertEqual(row.subtitle, Text(verbatim: "Movie.REMUX.mkv"))
        XCTAssertEqual(row.versionPresentation, .init(version, locale: Locale(identifier: "en_US")))
        XCTAssertEqual(row.versionPresentation?.supplementalFactsWithoutBadges, ["Remux", "2h"])
        row.action()
        XCTAssertTrue(closed)
        XCTAssertEqual(selected, "file")
    }
}
