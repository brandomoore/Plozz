import CoreModels
import XCTest

final class StreamingQualitySupportTests: XCTestCase {
    func testSiloExposesNativeLimitsWithoutChangingOtherProviders() throws {
        XCTAssertNotNil(StreamingQualitySupport.silo.validationMessage(for: .low))
        XCTAssertNil(StreamingQualitySupport.standard.validationMessage(for: .low))
        for quality in StreamingQuality.allCases where quality != .low {
            XCTAssertNil(StreamingQualitySupport.silo.validationMessage(for: quality))
        }
        XCTAssertNil(StreamingQualitySupport.silo.validationMessage(
            for: try .custom(maximumHeight: 1080, bitrateKbps: 2_000)
        ))
        XCTAssertNotNil(StreamingQualitySupport.silo.validationMessage(
            for: try .custom(maximumHeight: 1440, bitrateKbps: 2_000)
        ))
        XCTAssertNotNil(StreamingQualitySupport.silo.validationMessage(
            for: try .custom(maximumHeight: 480, bitrateKbps: 291)
        ))
        XCTAssertNil(StreamingQualitySupport.silo.validationMessage(
            for: try .custom(maximumHeight: 480, bitrateKbps: 292)
        ))
        XCTAssertFalse(StreamingQualitySupport.silo.codecs.contains(.preferHEVC))
        XCTAssertTrue(StreamingQualitySupport.standard.codecs.contains(.preferHEVC))
    }

    func testSourceResumeContextDoesNotChangeTheUsersQualitySelection() {
        var before = StreamingPlaybackOptions(quality: .hd720)
        before.startPosition = 42
        var after = before
        after.startPosition = 100
        XCTAssertTrue(before.matchesSelection(after))
    }
}
