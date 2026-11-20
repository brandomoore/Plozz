import XCTest
@testable import CoreModels

/// Provider biographies are HTML. Rendering them raw showed tags to the viewer on a
/// cast member's page, so the conversion is pinned here.
final class HTMLTextTests: XCTestCase {
    func testStripsInlineTagsAndKeepsProse() {
        XCTAssertEqual(
            HTMLText.plainText(from: "<p><strong>Hobbies</strong> include acting.</p>"),
            "Hobbies include acting."
        )
    }

    func testParagraphsBecomeLineBreaks() {
        XCTAssertEqual(
            HTMLText.plainText(from: "<p>First line.</p><p>Second line.</p>"),
            "First line.\nSecond line."
        )
    }

    func testBreakTagsBecomeLineBreaks() {
        XCTAssertEqual(
            HTMLText.plainText(from: "First<br />Second<br/>Third"),
            "First\nSecond\nThird"
        )
    }

    func testDecodesNamedAndNumericEntities() {
        XCTAssertEqual(
            HTMLText.plainText(from: "M&amp;M said &quot;hi&quot; to &#39;you&#39;"),
            "M&M said \"hi\" to 'you'"
        )
    }

    func testDecodesHexEntities() {
        XCTAssertEqual(HTMLText.plainText(from: "caf&#xE9;"), "café")
    }

    func testListItemsGetBullets() {
        XCTAssertEqual(
            HTMLText.plainText(from: "<ul><li>Acting</li><li>Voice work</li></ul>"),
            "• Acting\n• Voice work"
        )
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(HTMLText.plainText(from: "Plain biography."), "Plain biography.")
    }

    func testCollapsesWhitespaceAndTrailingBreaks() {
        XCTAssertEqual(
            HTMLText.plainText(from: "<p>A   B</p>\n\n\n"),
            "A B"
        )
    }
}
