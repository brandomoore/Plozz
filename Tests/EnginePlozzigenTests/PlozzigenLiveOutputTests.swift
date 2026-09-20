import AetherEngine
import XCTest
@testable import EnginePlozzigen

final class PlozzigenLiveOutputTests: XCTestCase {
    func testOutputPoliciesLeavePanelModeInferenceToAether() {
        for var options in [
            LoadOptions(matchContentEnabled: true),
            PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:]),
        ] {
            for suppressesDisplayMatching in [true, false] {
                PlozzigenVideoEngine.applyLiveOutputPolicy(
                    .init(isAudible: true, sharesAudioSession: false,
                          suppressesDisplayMatching: suppressesDisplayMatching),
                    to: &options)
                XCTAssertFalse(options.panelIsInHDRMode)
                XCTAssertTrue(options.attemptsHDRMasterOnUnprovenPanel)
            }
        }
    }

    func testScheduledFilesAndNetworkStreamsShareDisplaySuppression() {
        var file = LoadOptions(matchContentEnabled: true)
        var stream = PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:])
        PlozzigenVideoEngine.applyLiveOutputPolicy(
            .init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true), to: &file
        )
        PlozzigenVideoEngine.applyLiveOutputPolicy(
            .init(isAudible: true, sharesAudioSession: true, suppressesDisplayMatching: true), to: &stream
        )
        XCTAssertTrue(file.suppressDisplayCriteria)
        XCTAssertTrue(stream.suppressDisplayCriteria)
        XCTAssertFalse(file.matchContentEnabled)
        XCTAssertFalse(stream.matchContentEnabled)
        XCTAssertTrue(stream.isLive)
        XCTAssertFalse(file.isLive)
    }

    func testSinglePlayerPolicyPreservesMatchingOnSubsequentLoad() {
        var options = LoadOptions(matchContentEnabled: false)
        options.suppressDisplayCriteria = true
        PlozzigenVideoEngine.applyLiveOutputPolicy(.init(), to: &options)
        XCTAssertTrue(options.matchContentEnabled)
        XCTAssertFalse(options.suppressDisplayCriteria)
    }
}
