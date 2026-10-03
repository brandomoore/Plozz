import Foundation
import CoreGraphics

/// Turns inline subtitle markup into display text plus the formatting the
/// renderer can honour: colour runs and source placement. Everything else
/// (karaoke, fonts, ruby, voice spans) is stripped, as before.
///
/// Inline colours and supported WebVTT CSS count as source colour. ASS style-sheet colours are
/// deliberately ignored: nearly every script's `Default` style is white, and
/// treating that as the file's choice would override the viewer's text colour
/// on every line instead of acting as a fallback.
enum SubtitleMarkup {
    static let webVTTElements: Set<String> = ["c", "i", "b", "u", "ruby", "rt", "v", "lang"]

    // MARK: - SubRip / WebVTT

    /// Parses SRT/VTT cue text: `<font color>` and WebVTT colour classes
    /// (`<c.yellow>`) become runs, `<i>`/`<b>` whole-cue emphasis, and an SRT
    /// `{\an8}` override the cue's plane.
    static func parseSubRip(_ raw: String, webVTTStyles: WebVTTColorStyles? = nil) -> SubtitleText {
        let lowered = raw.lowercased()
        let isItalic = lowered.contains("<i>") || lowered.contains("<i ") || lowered.contains("<i.")
        let isBold = lowered.contains("<b>") || lowered.contains("<b ") || lowered.contains("<b.")

        var alignment: SubtitleAlignment?
        var builder = RunBuilder()
        let rootColor = webVTTStyles?.color()
        builder.color = rootColor
        var colorStack: [(element: String, color: SubtitleColor?)] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let ch = raw[index]
            if ch == "<", let close = raw[index...].firstIndex(of: ">") {
                let tag = String(raw[raw.index(after: index)..<close])
                    .trimmingCharacters(in: .whitespaces)
                applyHTMLTag(
                    tag, stack: &colorStack, builder: &builder,
                    webVTTStyles: webVTTStyles, rootColor: rootColor
                )
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
        _ tag: String, stack: inout [(element: String, color: SubtitleColor?)],
        builder: inout RunBuilder, webVTTStyles: WebVTTColorStyles?, rootColor: SubtitleColor?
    ) {
        let lowered = tag.lowercased()
        let name = tag.prefix { !$0.isWhitespace }.components(separatedBy: ".")
        let element = name[0].lowercased()
        if element.hasPrefix("/") {
            let closing = String(element.dropFirst())
            if let index = stack.lastIndex(where: { $0.element == closing }) {
                stack.removeSubrange(index...)
                builder.color = stack.last?.color ?? rootColor
            }
            return
        }
        let pushed: SubtitleColor?
        if lowered.hasPrefix("font") {
            pushed = fontColorAttribute(tag).flatMap(SubtitleColor.init(markup:)) ?? builder.color
        } else if let webVTTStyles, webVTTElements.contains(element) {
            pushed = webVTTStyles.color(
                element: element, classes: Array(name.dropFirst()), inherited: builder.color
            )
        } else if lowered == "c" || lowered.hasPrefix("c.") {
            let classes = lowered.split(separator: ".").dropFirst()
            pushed = classes.lazy.compactMap { SubtitleColor(markup: String($0)) }.first ?? builder.color
        } else {
            return   // <i>, <b>, <v Speaker>, <ruby>, timestamps: no colour effect
        }
        stack.append((element, pushed))
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
        var drawing = false
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
                if let mode = overrides.drawingMode { drawing = mode > 0 }
            } else if depth > 0 {
                block.append(ch)
            } else if !drawing {
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
        var drawingMode: Int?
    }

    /// Reads the tags inside one `{…}` block (without the braces).
    static func assOverrides(in block: String) -> ASSOverrides {
        var result = ASSOverrides()
        for tag in block.split(separator: "\\").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lowered = tag.lowercased()
            if lowered.hasPrefix("p"), let mode = Int(lowered.dropFirst()) {
                result.drawingMode = mode
            } else if lowered.hasPrefix("an"), let n = Int(lowered.dropFirst(2)), let a = SubtitleAlignment(rawValue: n) {
                result.alignment = a
            } else if lowered.hasPrefix("pos("), lowered.hasSuffix(")") {
                let numbers = lowered.dropFirst(4).dropLast().split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.count == 2, numbers.allSatisfy(\.isFinite) {
                    result.position = CGPoint(x: numbers[0], y: numbers[1])
                }
            } else if lowered.hasPrefix("1c&h") || lowered.hasPrefix("c&h") {
                let hex = lowered.drop { $0 != "h" }.dropFirst().prefix { $0.isHexDigit }
                result.color = SubtitleColor(assBGR: String(hex))
            } else if lowered == "c" || lowered == "1c" {
                result.resetsColor = true
                result.color = nil
            } else if lowered == "r" || (lowered.hasPrefix("r") && !lowered.hasPrefix("rnd")) {
                result.resetsColor = true
                result.color = nil
                result.drawingMode = 0
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
            guard let value = Double(parts[1]), value.isFinite, value > 0 else { continue }
            switch parts[0].lowercased() {
            case "playresx": x = value
            case "playresy": y = value
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
        let n: UInt32
        if let named = Self.namedMarkupColors[v] { n = named }
        else {
            var hex = v.hasPrefix("#") ? String(v.dropFirst()) : v
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let parsed = UInt32(hex, radix: 16) else { return nil }
            n = parsed
        }
        self.init(
            red: Double((n >> 16) & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double(n & 0xFF) / 255
        )
    }

    /// CSS color values are not class names: `green` is exactly #008000.
    init?(css value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v == "transparent" { self = .clear; return }
        if Self.namedMarkupColors[v] != nil { self.init(markup: v); return }
        if v.hasPrefix("#") {
            var hex = String(v.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { self.init(markup: hex); return }
            guard hex.count == 8, let n = UInt32(hex, radix: 16) else { return nil }
            self.init(
                red: Double((n >> 24) & 0xFF) / 255, green: Double((n >> 16) & 0xFF) / 255,
                blue: Double((n >> 8) & 0xFF) / 255, alpha: Double(n & 0xFF) / 255
            )
            return
        }
        guard (v.hasPrefix("rgb(") || v.hasPrefix("rgba(")), v.hasSuffix(")"),
              let open = v.firstIndex(of: "(") else { return nil }
        let body = String(v[v.index(after: open)..<v.index(before: v.endIndex)])
        let components: [String]
        if body.contains(",") {
            guard !body.contains("/") else { return nil }
            components = body.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard Set(components.prefix(3).map { $0.hasSuffix("%") }).count == 1 else { return nil }
        } else {
            let parts = body.components(separatedBy: "/")
            guard parts.count <= 2 else { return nil }
            var channels = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
            guard channels.count == 3 else { return nil }
            if parts.count == 2 { channels.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) }
            components = channels
        }
        guard components.count == 3 || components.count == 4 else { return nil }
        func channel(_ text: String, scale: Double) -> Double? {
            let percent = text.hasSuffix("%")
            guard let number = Double(percent ? String(text.dropLast()) : text), number.isFinite else { return nil }
            return min(1, max(0, number / (percent ? 100 : scale)))
        }
        guard let red = channel(components[0], scale: 255),
              let green = channel(components[1], scale: 255),
              let blue = channel(components[2], scale: 255),
              let alpha = components.count == 4 ? channel(components[3], scale: 1) : 1 else { return nil }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
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

    private static let namedMarkupColors: [String: UInt32] = [
        "white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000,
        "lime": 0x00FF00, "green": 0x008000, "limegreen": 0x32CD32, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "cyan": 0x00FFFF, "aqua": 0x00FFFF,
        "magenta": 0xFF00FF, "fuchsia": 0xFF00FF, "orange": 0xFFA500,
        "gray": 0x808080, "grey": 0x808080, "silver": 0xC0C0C0,
        "purple": 0x800080, "maroon": 0x800000, "navy": 0x000080,
        "olive": 0x808000, "teal": 0x008080
    ]
}
