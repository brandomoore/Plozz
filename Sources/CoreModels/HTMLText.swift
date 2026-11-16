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
        var result = ""
        var cursor = text.startIndex
        var copiedThrough = cursor
        while cursor < text.endIndex {
            defer { cursor = text.index(after: cursor) }
            guard text[cursor] == "&" else { continue }
            let start = text.index(after: cursor)
            let limit = text.index(start, offsetBy: 10, limitedBy: text.endIndex) ?? text.endIndex
            guard let end = text[start..<limit].firstIndex(of: ";") else { continue }
            let entity = text[start..<end]
            let replacement: String?
            if entity.hasPrefix("#") {
                let hexadecimal = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                let digits = entity.dropFirst(hexadecimal ? 2 : 1)
                if let value = UInt32(digits, radix: hexadecimal ? 16 : 10),
                   value > 0, let scalar = Unicode.Scalar(value) {
                    replacement = String(scalar)
                } else {
                    replacement = nil
                }
            } else {
                replacement = namedEntities[String(entity)]
            }
            guard let replacement else { continue }
            result += text[copiedThrough..<cursor]
            result += replacement
            cursor = end
            copiedThrough = text.index(after: end)
        }
        result += text[copiedThrough...]
        return result
    }
}
