import Foundation
import CoreGraphics

/// Turns inline subtitle markup into display text plus the formatting the
/// renderer can honour: colour runs and source placement. Everything else
/// (karaoke, fonts, ruby, voice spans) is stripped, as before.
///
/// Only **inline** colour counts as source colour. ASS style-sheet colours are
/// deliberately ignored: nearly every script's `Default` style is white, and
/// treating that as the file's choice would override the viewer's text colour
/// on every line instead of acting as a fallback.
enum SubtitleMarkup {

    // MARK: - SubRip / WebVTT

    /// Parses SRT/VTT cue text: `<font color>` and WebVTT colour classes
    /// (`<c.yellow>`) become runs, `<i>`/`<b>` whole-cue emphasis, and an SRT
    /// `{\an8}` override the cue's plane.
    static func parseSubRip(_ raw: String) -> SubtitleText {
        let lowered = raw.lowercased()
        let isItalic = lowered.contains("<i>") || lowered.contains("<i ")
        let isBold = lowered.contains("<b>") || lowered.contains("<b ")

        var alignment: SubtitleAlignment?
        var builder = RunBuilder()
        var colorStack: [SubtitleColor?] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            if ch == "<", let close = raw[index...].firstIndex(of: ">") {
                let tag = String(raw[raw.index(after: index)..<close])
                    .trimmingCharacters(in: .whitespaces)
                applyHTMLTag(tag, stack: &colorStack, builder: &builder)
                index = raw.index(after: close)
                continue
            }
            // SRT carries ASS-style override blocks (`{\an8}` for a top line).
            if ch == "{", raw[raw.index(after: index)...].first == "\\",
               let close = raw[index...].firstIndex(of: "}") {
                let block = String(raw[raw.index(after: index)..<close])
                if alignment == nil { alignment = assOverrides(in: block).alignment }
                index = raw.index(after: close)
                continue
            }
            builder.append(ch)
            index = raw.index(after: index)
        }

        let runs = builder.finish(decodingEntities: true)
        return SubtitleText(
            runs: runs, isItalic: isItalic, isBold: isBold,
            layout: alignment.map { SubtitleCueLayout(alignment: $0) }
        )
    }

    private static func applyHTMLTag(
        _ tag: String, stack: inout [SubtitleColor?], builder: inout RunBuilder
    ) {
        let lowered = tag.lowercased()
        if lowered == "/font" || lowered == "/c" || lowered.hasPrefix("/c.") {
            _ = stack.popLast()
            builder.color = stack.last ?? nil
            return
        }
        let pushed: SubtitleColor?
        if lowered.hasPrefix("font") {
            pushed = fontColorAttribute(tag).flatMap(SubtitleColor.init(markup:)) ?? builder.color
        } else if lowered == "c" || lowered.hasPrefix("c.") {
            // WebVTT classes: `c.yellow.bg_black` — the first known colour wins.
            let classes = lowered.split(separator: ".").dropFirst()
            pushed = classes.lazy.compactMap { SubtitleColor(markup: String($0)) }.first ?? builder.color
        } else {
            return   // <i>, <b>, <v Speaker>, <ruby>, timestamps: no colour effect
        }
        stack.append(pushed)
        builder.color = pushed
    }

    /// The `color=` value of a `<font …>` tag, quoted or not.
    private static func fontColorAttribute(_ tag: String) -> String? {
        guard let range = tag.range(of: "color", options: .caseInsensitive) else { return nil }
        var rest = tag[range.upperBound...].drop { $0 == " " }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        if let quote = rest.first, quote == "\"" || quote == "'" {
            return String(rest.dropFirst().prefix { $0 != quote })
        }
        return String(rest.prefix { $0 != " " })
    }

    // MARK: - ASS / SSA

    /// Parses an ASS event's text: `\c`/`\1c` colour overrides become runs
    /// (`\r` resets), the first `\an` sets the plane and `\pos` the anchor,
    /// normalised against the script's play resolution.
    static func parseASS(_ raw: String, playResolution: CGSize) -> SubtitleText {
        let lowered = raw.lowercased()
        let isItalic = lowered.contains("\\i1")
        let isBold = lowered.contains("\\b1")

        var alignment: SubtitleAlignment?
        var anchor: CGPoint?
        var builder = RunBuilder()
        var depth = 0
        var block = ""
        for ch in raw {
            if ch == "{" {
                depth += 1
                if depth == 1 { block = "" }
            } else if ch == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                guard depth == 0 else { continue }
                let overrides = assOverrides(in: block)
                if alignment == nil { alignment = overrides.alignment }
                if anchor == nil, let pos = overrides.position,
                   playResolution.width > 0, playResolution.height > 0 {
                    anchor = CGPoint(x: pos.x / playResolution.width, y: pos.y / playResolution.height)
                }
                if overrides.resetsColor { builder.color = nil }
                if let color = overrides.color { builder.color = color }
            } else if depth > 0 {
                block.append(ch)
            } else {
                builder.append(ch)
            }
        }

        let runs = builder.finish(decodingEntities: false).map { run in
            SubtitleTextRun(
                run.text
                    .replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\h", with: "\u{00A0}"),
                color: run.color
            )
        }
        let layout: SubtitleCueLayout? = (alignment != nil || anchor != nil)
            ? SubtitleCueLayout(alignment: alignment ?? .bottomCenter, anchor: anchor)
            : nil
        return SubtitleText(
            runs: SubtitleText.trimmed(runs), isItalic: isItalic, isBold: isBold,
            layout: layout, rawASS: raw
        )
    }

    struct ASSOverrides {
        var alignment: SubtitleAlignment?
        var position: CGPoint?
        var color: SubtitleColor?
        var resetsColor = false
    }

    /// Reads the tags inside one `{…}` block (without the braces).
    static func assOverrides(in block: String) -> ASSOverrides {
        var result = ASSOverrides()
        for tag in block.split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lowered = tag.lowercased()
            if lowered.hasPrefix("an"), let n = Int(lowered.dropFirst(2)), let a = SubtitleAlignment(rawValue: n) {
                result.alignment = a
            } else if lowered.hasPrefix("pos("), lowered.hasSuffix(")") {
                let numbers = lowered.dropFirst(4).dropLast().split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.count == 2 { result.position = CGPoint(x: numbers[0], y: numbers[1]) }
            } else if lowered.hasPrefix("1c&h") || lowered.hasPrefix("c&h") {
                let hex = lowered.drop { $0 != "h" }.dropFirst().prefix { $0.isHexDigit }
                result.color = SubtitleColor(assBGR: String(hex))
            } else if lowered == "r" || (lowered.hasPrefix("r") && !lowered.hasPrefix("rnd")) {
                result.resetsColor = true
                result.color = nil
            }
        }
        return result
    }

    /// The script's `PlayResX`/`PlayResY`, which `\pos` coordinates are in.
    /// Per the ASS spec a script declaring neither is 384×288; one declaring
    /// only one axis derives the other at 4:3.
    static func playResolution(in lines: [String]) -> CGSize {
        var x: Double?
        var y: Double?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("[events]") { break }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "playresx": x = Double(parts[1])
            case "playresy": y = Double(parts[1])
            default: break
            }
        }
        switch (x, y) {
        case let (x?, y?): return CGSize(width: x, height: y)
        case let (x?, nil): return CGSize(width: x, height: x * 3 / 4)
        case let (nil, y?): return CGSize(width: y * 4 / 3, height: y)
        case (nil, nil): return CGSize(width: 384, height: 288)
        }
    }

    // MARK: - Runs

    /// Accumulates characters into same-colour runs.
    struct RunBuilder {
        var color: SubtitleColor?
        private var runs: [SubtitleTextRun] = []

        mutating func append(_ ch: Character) {
            if let last = runs.last, last.color == color {
                runs[runs.count - 1].text.append(ch)
            } else {
                runs.append(SubtitleTextRun(String(ch), color: color))
            }
        }

        func finish(decodingEntities: Bool) -> [SubtitleTextRun] {
            let decoded = decodingEntities
                ? runs.map { SubtitleTextRun(SubtitleMarkup.decodeEntities($0.text), color: $0.color) }
                : runs
            return decodingEntities ? SubtitleText.trimmed(decoded) : decoded
        }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", "\u{00A0}"),
            ("&lrm;", "\u{200E}"), ("&rlm;", "\u{200F}")
        ]
        for (entity, replacement) in map {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}

extension SubtitleText {
    /// Trims leading/trailing whitespace across run boundaries, dropping runs
    /// that end up empty, so the joined text matches a trimmed plain string.
    static func trimmed(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        var runs = runs
        while let first = runs.first {
            let text = String(first.text.drop { $0.isWhitespace || $0.isNewline })
            if text.isEmpty { runs.removeFirst() } else { runs[0].text = text; break }
        }
        while let last = runs.last {
            var text = last.text
            while let c = text.last, c.isWhitespace || c.isNewline { text.removeLast() }
            if text.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = text; break }
        }
        return runs
    }
}

extension SubtitleColor {
    /// An HTML/WebVTT colour: `#RRGGBB`, `#RGB`, bare hex, or a common name.
    init?(markup value: String) {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = Self.namedMarkupColors[v] { self = named; return }
        var hex = v.hasPrefix("#") ? String(v.dropFirst()) : v
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((n >> 16) & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double(n & 0xFF) / 255
        )
    }

    /// An ASS `&HBBGGRR&` colour (an optional leading alpha byte is ignored).
    init?(assBGR hex: String) {
        guard !hex.isEmpty, hex.count <= 8, let n = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double(n & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double((n >> 16) & 0xFF) / 255
        )
    }

    /// WebVTT's default colour classes plus the HTML names SRT files use.
    private static let namedMarkupColors: [String: SubtitleColor] = [
        "white": .init(red: 1, green: 1, blue: 1),
        "black": .init(red: 0, green: 0, blue: 0),
        "red": .init(red: 1, green: 0, blue: 0),
        "lime": .init(red: 0, green: 1, blue: 0),
        "green": .init(red: 0, green: 0.5, blue: 0),
        "blue": .init(red: 0, green: 0, blue: 1),
        "yellow": .init(red: 1, green: 1, blue: 0),
        "cyan": .init(red: 0, green: 1, blue: 1),
        "aqua": .init(red: 0, green: 1, blue: 1),
        "magenta": .init(red: 1, green: 0, blue: 1),
        "fuchsia": .init(red: 1, green: 0, blue: 1),
        "orange": .init(red: 1, green: 0.65, blue: 0),
        "gray": .init(red: 0.5, green: 0.5, blue: 0.5),
        "grey": .init(red: 0.5, green: 0.5, blue: 0.5),
        "silver": .init(red: 0.75, green: 0.75, blue: 0.75),
        "purple": .init(red: 0.5, green: 0, blue: 0.5),
        "maroon": .init(red: 0.5, green: 0, blue: 0),
        "navy": .init(red: 0, green: 0, blue: 0.5),
        "olive": .init(red: 0.5, green: 0.5, blue: 0),
        "teal": .init(red: 0, green: 0.5, blue: 0.5)
    ]
}
