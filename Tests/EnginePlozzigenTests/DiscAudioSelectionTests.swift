#if canImport(AetherEngine) && canImport(UIKit)
import AetherEngine
@testable import EnginePlozzigen
import XCTest

@MainActor
final class DiscAudioSelectionTests: XCTestCase {
    func testAlreadyPlayingRepresentationOfSharedPIDIsNotUnavailable() {
        let tracks = [
            track(1, pid: 0x1100, codec: "truehd"),
            track(2, pid: 0x1100, codec: "ac3"),
            track(3, pid: 0x1101, codec: "ac3")
        ]
        for active in [1, 2] {
            XCTAssertEqual(PlozzigenVideoEngine.discAudioTrackID(
                pid: 0x1100, tracks: tracks, activeTrackID: active
            ), active)
        }
        XCTAssertNil(PlozzigenVideoEngine.discAudioTrackID(
            pid: 0x1100, tracks: tracks, activeTrackID: 3
        ), "Do not guess a representation when neither candidate is playing.")
        XCTAssertEqual(PlozzigenVideoEngine.discAudioTrackID(
            pid: 0x1101, tracks: tracks, activeTrackID: 2
        ), 3)
    }

    func testMissingOrInvalidPIDCannotMatchActiveAudioByIndex() {
        let tracks = [track(1, pid: nil, codec: "ac3"), track(2, pid: 0x1101, codec: "ac3")]
        for pid in [-1, 1, 0x1100, 0x1fff] {
            XCTAssertNil(PlozzigenVideoEngine.discAudioTrackID(
                pid: pid, tracks: tracks, activeTrackID: 1
            ))
        }
    }

    private func track(_ id: Int, pid: Int?, codec: String) -> TrackInfo {
        TrackInfo(id: id, name: "Fixture", codec: codec, language: "eng",
                  isDefault: false, mpegTSPID: pid)
    }
}
#endif
