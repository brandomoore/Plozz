import Foundation

/// Converts provider-supplied HTML into displayable plain text.
///
/// Encyclopaedia and metadata sources return prose as HTML — `<p><strong>Hobbies…
/// </strong></p>`, `<br />`, entities — and rendering it verbatim shows the tags to
/// the viewer (reported on a cast member's biography page). This is deliberately a
/// small, dependency-free converter rather than a full HTML parser: biographies are
/// paragraphs, emphasis and line breaks, and a renderer that honours arbitrary markup
/// would also need sanitising, sizing and link policy that a plain `Text` cannot
/// express.
///
/// Behaviour:
/// - block-level tags (`p`, `div`, `br`, `li`, headings) become single newlines,
///   list items get a leading bullet,
/// - every other tag is removed (inline emphasis keeps its text),
/// - entities (`&amp;`, `&nbsp;`, `&#39;`, numeric forms) are decoded,
/// - runs of spaces collapse, blank-line runs collapse to one paragraph break,
///   and leading/trailing whitespace is trimmed.
public enum HTMLText {
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "section", "article", "table", "tr", "td", "th"
    ]

    public static func plainText(from html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }

        var text = html
        // Paragraph/list boundaries before tags are removed, so words either side
        // cannot run together into "HobbiesActing".
        text = text.replacingOccurrences(
            of: "<\\s*br\\s*/?\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</\\s*(p|div|li|ul|ol|h[1-6]|blockquote|section|article|tr|table)\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<\\s*li\\s*>", with: "\n• ", options: [.regularExpression, .caseInsensitive]
        )
        // Remaining tags carry no meaning for a plain Text view.
        text = text.replacingOccurrences(
            of: "<[^>]+>", with: "", options: [.regularExpression]
        )
        text = decodeEntities(in: text)

        // Collapse horizontal whitespace, then paragraph runs.
        text = text.replacingOccurrences(
            of: "[\\t\\x{00A0} ]+", with: " ", options: [.regularExpression]
        )
        text = text.replacingOccurrences(
            of: " *\\n *", with: "\n", options: [.regularExpression]
        )
        text = text.replacingOccurrences(
            of: "\\n{2,}", with: "\n", options: [.regularExpression]
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"
    ]

    private static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        let bytes = text.utf8
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == 38 {
                let start = bytes.index(after: index)
                var end = start
                // Numeric scalars need at most eight body bytes (#x10FFFF).
                // Bounded lookahead keeps malformed/unterminated input linear.
                for _ in 0..<8 where end < bytes.endIndex && bytes[end] != 59 {
                    end = bytes.index(after: end)
                }
                if end < bytes.endIndex, bytes[end] == 59,
                   let decoded = decodeEntity(String(decoding: bytes[start..<end], as: UTF8.self)) {
                    result.append(contentsOf: decoded.utf8)
                    index = bytes.index(after: end)
                    continue
                }
            }
            result.append(bytes[index])
            index = bytes.index(after: index)
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func decodeEntity(_ body: String) -> String? {
        if let named = namedEntities[body] { return named }
        guard body.hasPrefix("#") else { return nil }
        let hexadecimal = body.hasPrefix("#x") || body.hasPrefix("#X")
        let digits = body.dropFirst(hexadecimal ? 2 : 1)
        guard !digits.isEmpty,
              digits.utf8.allSatisfy({
                  (48...57).contains($0) || (hexadecimal && ((65...70).contains($0) || (97...102).contains($0)))
              }),
              let value = UInt32(digits, radix: hexadecimal ? 16 : 10),
              let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return String(scalar)
    }
}
