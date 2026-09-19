import AetherEngine
import XCTest
@testable import EnginePlozzigen

final class PlozzigenLiveOutputTests: XCTestCase {
    func testPanelHDRAssertionRequiresActualFiniteHeadroomNotJustDisplayCapability() {
        XCTAssertTrue(PlozzigenVideoEngine.panelHDRAssertion(currentHeadroom: 2, potentialHeadroom: 4))
        XCTAssertFalse(PlozzigenVideoEngine.panelHDRAssertion(currentHeadroom: 1, potentialHeadroom: 4))
        XCTAssertFalse(PlozzigenVideoEngine.panelHDRAssertion(currentHeadroom: 2, potentialHeadroom: 1))
        XCTAssertFalse(PlozzigenVideoEngine.panelHDRAssertion(currentHeadroom: .nan, potentialHeadroom: 4))
        XCTAssertFalse(PlozzigenVideoEngine.panelHDRAssertion(currentHeadroom: 2, potentialHeadroom: .infinity))
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
