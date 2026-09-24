import CoreGraphics
import XCTest
@testable import CoreModels

/// Source colour and placement survive parsing, so the renderer can honour
/// them (or fall back to the viewer's style when a cue declares none).
final class SubtitleMarkupTests: XCTestCase {
    private struct NotText: Error {}

    private func text(_ file: String) throws -> SubtitleText {
        let cue = try XCTUnwrap(SubtitleCueParser.parseCues(file).first)
        guard case .text(let text) = cue.body else { throw NotText() }
        return text
    }

    func testPlainSRTHasNoRunsOrLayout() throws {
        let t = try text("1\n00:00:01,000 --> 00:00:02,000\n <i>Hello</i> there \n")
        XCTAssertEqual(t.string, "Hello there")
        XCTAssertTrue(t.isItalic)
        XCTAssertNil(t.runs, "uncoloured cues keep the style's colour")
        XCTAssertNil(t.layout)
    }

    func testSRTFontColorBecomesRuns() throws {
        let t = try text("1\n00:00:01,000 --> 00:00:02,000\nSay <font color=\"#FFFF00\">yes</font> now\n")
        XCTAssertEqual(t.string, "Say yes now")
        let runs = try XCTUnwrap(t.runs)
        XCTAssertEqual(runs.map(\.text), ["Say ", "yes", " now"])
        XCTAssertNil(runs[0].color)
        XCTAssertEqual(runs[1].color, SubtitleColor(red: 1, green: 1, blue: 0))
        XCTAssertNil(runs[2].color)
    }

    func testSRTOverrideBlockSetsPlaneAndIsNotShown() throws {
        let t = try text("1\n00:00:01,000 --> 00:00:02,000\n{\\an8}Sign text\n")
        XCTAssertEqual(t.string, "Sign text")
        XCTAssertEqual(t.layout?.alignment, .topCenter)
        XCTAssertEqual(t.layout?.isSourcePositioned, true)
    }

    func testWebVTTColorClass() throws {
        let t = try text("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<c.cyan.bg_black>Narrator</c>: hi\n")
        XCTAssertEqual(t.string, "Narrator: hi")
        XCTAssertEqual(t.runs?.first?.color, SubtitleColor(red: 0, green: 1, blue: 1))
        XCTAssertNil(t.runs?.last?.color)
    }

    func testEntitiesDecodeInsideRuns() throws {
        let t = try text("1\n00:00:01,000 --> 00:00:02,000\n<font color=red>Tom &amp; Jerry</font>\n")
        XCTAssertEqual(t.string, "Tom & Jerry")
        XCTAssertEqual(t.runs?.count, 1)
    }

    private let assHeader = """
    [Script Info]
    PlayResX: 1920
    PlayResY: 1080

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

    func testASSColorOverrideAndReset() throws {
        let t = try text(assHeader + "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Plain {\\c&H0000FF&}red{\\r} back\n")
        XCTAssertEqual(t.string, "Plain red back")
        let runs = try XCTUnwrap(t.runs)
        XCTAssertEqual(runs.map(\.text), ["Plain ", "red", " back"])
        XCTAssertEqual(runs[1].color, SubtitleColor(red: 1, green: 0, blue: 0), "ASS colours are BGR")
        XCTAssertNil(runs[2].color)
    }

    func testASSPositionNormalisesAgainstPlayResolution() throws {
        let t = try text(assHeader + "Dialogue: 0,0:00:01.00,0:00:02.00,Sign,,0,0,0,,{\\an8\\pos(960,108)}Street name\n")
        XCTAssertEqual(t.string, "Street name")
        XCTAssertEqual(t.layout?.alignment, .topCenter)
        let anchor = try XCTUnwrap(t.layout?.anchor)
        XCTAssertEqual(anchor.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(anchor.y, 0.1, accuracy: 0.001)
    }

    func testASSLineBreaksAndPlainEventsStayUnformatted() throws {
        let t = try text(assHeader + "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}One\\NTwo\n")
        XCTAssertEqual(t.string, "One\nTwo")
        XCTAssertTrue(t.isItalic)
        XCTAssertNil(t.runs)
        XCTAssertNil(t.layout)
    }

    func testStyleDefaultsHonourSourceFormattingAndDecodeWhenMissing() throws {
        XCTAssertTrue(SubtitleStyle.default.usesSourcePosition)
        XCTAssertTrue(SubtitleStyle.default.usesSourceColors)
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"fontScale":1.2}"#.utf8))
        XCTAssertTrue(old.usesSourcePosition)
        XCTAssertTrue(old.usesSourceColors)
        var style = SubtitleStyle.default
        style.usesSourceColors = false
        let roundTrip = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(style))
        XCTAssertFalse(roundTrip.usesSourceColors)
    }
}
