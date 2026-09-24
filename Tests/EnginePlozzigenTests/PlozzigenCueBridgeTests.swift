import CoreGraphics
import CoreModels
import XCTest
@testable import EnginePlozzigen

/// Aether's `\an`/`\pos` placement and colour runs reach Plozz's cue model
/// instead of being flattened to plain text.
@MainActor
final class PlozzigenCueBridgeTests: XCTestCase {
    func testPlainTextStaysUnformatted() {
        let text = PlozzigenVideoEngine.bridgedText(
            [.init(text: "Hello")], alignment: nil, position: nil
        )
        XCTAssertEqual(text.string, "Hello")
        XCTAssertNil(text.runs)
        XCTAssertNil(text.layout)
    }

    func testColourRunsAndPlacementCarryAcross() throws {
        let text = PlozzigenVideoEngine.bridgedText(
            [.init(text: "Plain "), .init(text: "gold", rgb: (255, 204, 0))],
            alignment: 8, position: CGPoint(x: 0.5, y: 0.1)
        )
        XCTAssertEqual(text.string, "Plain gold")
        let runs = try XCTUnwrap(text.runs)
        XCTAssertNil(runs[0].color)
        XCTAssertEqual(runs[1].color?.red, 1)
        XCTAssertEqual(runs[1].color?.green ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(text.layout?.alignment, .topCenter)
        XCTAssertEqual(text.layout?.anchor, CGPoint(x: 0.5, y: 0.1))
    }

    func testWholeCueEmphasisNeedsEveryVisibleRun() {
        let italic = PlozzigenVideoEngine.bridgedText(
            [.init(text: "a", isItalic: true), .init(text: " "), .init(text: "b", isItalic: true)],
            alignment: nil, position: nil
        )
        XCTAssertTrue(italic.isItalic)
        let mixed = PlozzigenVideoEngine.bridgedText(
            [.init(text: "a", isItalic: true), .init(text: "b")], alignment: nil, position: nil
        )
        XCTAssertFalse(mixed.isItalic)
    }
}
