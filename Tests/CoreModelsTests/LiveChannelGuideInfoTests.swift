import CoreModels
import XCTest

/// The player shows guide data it didn't parse, so the reduction has to hold
/// up on its own: empty guide fields mean absent, and the info bar's
/// "subtitle – description" line joins only what exists.
final class LiveChannelGuideInfoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testSummaryJoinsSubtitleAndDescriptionAndSkipsWhatIsMissing() {
        XCTAssertEqual(program(subtitle: "Pilot", description: "It begins.").summary, "Pilot – It begins.")
        XCTAssertEqual(program(subtitle: "Pilot", description: nil).summary, "Pilot")
        XCTAssertEqual(program(subtitle: nil, description: "It begins.").summary, "It begins.")
        XCTAssertNil(program(subtitle: nil, description: nil).summary)
    }

    func testEmptyGuideFieldsAreTreatedAsAbsent() {
        let info = program(subtitle: "", description: "")
        XCTAssertNil(info.subtitle)
        XCTAssertNil(info.description)
        XCTAssertNil(info.summary)
    }

    func testProgressIsClampedToTheProgramme() {
        let info = program(subtitle: nil, description: nil)
        XCTAssertEqual(info.progress(at: start.addingTimeInterval(-60)), 0)
        XCTAssertEqual(info.progress(at: start.addingTimeInterval(900)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(info.progress(at: start.addingTimeInterval(3_600)), 1)
    }

    func testZeroLengthProgrammeIsEitherNotStartedOrDone() {
        let info = LiveChannelProgramInfo(title: "News", start: start, end: start)
        XCTAssertEqual(info.progress(at: start.addingTimeInterval(-1)), 0)
        XCTAssertEqual(info.progress(at: start), 1)
    }

    private func program(subtitle: String?, description: String?) -> LiveChannelProgramInfo {
        LiveChannelProgramInfo(
            title: "Show", subtitle: subtitle, description: description,
            start: start, end: start.addingTimeInterval(1_800)
        )
    }
}
