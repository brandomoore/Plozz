#if canImport(SwiftUI)
import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class SystemCaptionStyleConfirmationTests: XCTestCase {
    func testEnablingDefersAllChangesAndCancelPreservesTheCustomStyle() {
        let confirmation = SystemCaptionStyleConfirmation()
        var style = SubtitleStyle.default
        style.fontScale = 1.37
        style.textColor = .yellow
        let original = style
        confirmation.request(true, currentlyMatching: style.followsSystemStyle) {
            style.followsSystemStyle = $0
        }
        XCTAssertTrue(confirmation.isPresented)
        XCTAssertEqual(style, original)
        confirmation.cancel()
        confirmation.confirm { style.followsSystemStyle = $0 }
        XCTAssertEqual(style, original)
    }

    func testConfirmationAppliesSystemMatchingExactlyOnce() {
        let confirmation = SystemCaptionStyleConfirmation()
        var values: [Bool] = []
        confirmation.request(true, currentlyMatching: false) { values.append($0) }
        XCTAssertTrue(values.isEmpty)
        confirmation.confirm { values.append($0) }
        confirmation.confirm { values.append($0) }
        XCTAssertEqual(values, [true])
        XCTAssertFalse(confirmation.isPresented)
    }

    func testDisablingAndUnchangedRequestsDoNotPrompt() {
        let confirmation = SystemCaptionStyleConfirmation()
        var values: [Bool] = []
        confirmation.request(false, currentlyMatching: true) { values.append($0) }
        XCTAssertEqual(values, [false])
        confirmation.request(true, currentlyMatching: true) { values.append($0) }
        confirmation.request(false, currentlyMatching: false) { values.append($0) }
        XCTAssertEqual(values, [false])
        XCTAssertFalse(confirmation.isPresented)
    }
}
#endif
