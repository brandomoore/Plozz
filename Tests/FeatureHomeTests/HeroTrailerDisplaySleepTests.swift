#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import FeatureHomeCore
import XCTest

/// Refs #389: an ambient trailer must not keep the display awake.
@MainActor
final class HeroTrailerDisplaySleepTests: XCTestCase {
    func testAmbientTrailerPlayerLetsTheDisplaySleep() {
        let controller = HeroTrailerController()
        defer { controller.stop() }
        XCTAssertFalse(controller.player.preventsDisplaySleepDuringVideoPlayback)
    }
}
#endif
