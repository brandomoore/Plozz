import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerVersionMenuTests: XCTestCase {
    func testVersionControlAppearsOnlyForRealAlternativesAndPreservesOtherControls() {
        let controls = PlayerControlsModel()
        controls.engineCapabilities = [.playbackSpeed]
        XCTAssertEqual(controls.trackControlCategories, [.speed])
        controls.versions.options = [
            .init(version: .init(id: "current"), isSelected: true)
        ]
        XCTAssertEqual(controls.trackControlCategories, [.speed])
        controls.versions.options.append(.init(version: .init(id: "alternate"), isSelected: false))
        XCTAssertEqual(controls.trackControlCategories, [.version, .speed])
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
}
