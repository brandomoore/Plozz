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

    func testEntitiesAreDecodedOnlyOnceRegardlessOfSyntax() {
        XCTAssertEqual(
            HTMLText.plainText(from: "&#38;lt; &#x26;amp; &amp;lt; &amp;#60; &lt;b&gt;"),
            "&lt; &amp; &lt; &#60; <b>"
        )
    }

    func testUnknownMalformedAndInvalidScalarEntitiesStayLiteral() {
        let input = "&unknown; &#xD800; &#1114112; &#-1; &#x; &#; &amp &#999999999999; &&lt;"
        XCTAssertEqual(
            HTMLText.plainText(from: input),
            "&unknown; &#xD800; &#1114112; &#-1; &#x; &#; &amp &#999999999999; &<"
        )
        XCTAssertEqual(HTMLText.plainText(from: "&#x1F600;"), "😀")
    }

    func testLongMalformedEntityDoesNotPreventLaterDecoding() {
        let malformed = "&" + String(repeating: "9", count: 100_000)
        XCTAssertEqual(HTMLText.plainText(from: malformed + " &amp;"), malformed + " &")
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
