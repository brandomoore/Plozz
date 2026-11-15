import Foundation

/// Display cleanup only. Never use the result as a channel identity or guide-matching key.
public enum IPTVChannelName {
    /// Prefer affected names, retaining at most three distinct preview rows.
    public static func previewSamples(from names: some Sequence<String>) -> [String] {
        let limit = 3
        var changed: [(name: String, cleaned: String)] = []
        var unchanged: [String] = []
        for name in names {
            let value = cleaned(name)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if value != name {
                guard !changed.contains(where: { $0.cleaned == value }) else { continue }
                changed.append((name, value))
                if changed.count == limit { return changed.map(\.name) }
            } else if unchanged.count < limit, !unchanged.contains(name) {
                unchanged.append(name)
            }
        }
        return Array((changed.map(\.name) + unchanged.filter { name in
            !changed.contains(where: { $0.cleaned == name })
        }).prefix(limit))
    }

    public static func cleaned(_ name: String) -> String {
        var value = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let marker = value.first, marker == "#" || marker == "*" {
            let leading = value.prefix { $0 == marker }.count
            let trailing = value.reversed().prefix { $0 == marker }.count
            if leading >= 2, trailing >= 2, leading + trailing < value.count {
                let content = value.dropFirst(leading).dropLast(trailing)
                    .trimmingCharacters(in: .whitespaces)
                if content.contains(where: { $0.isLetter || $0.isNumber }) { value = content }
            }
        }

        var words = value.replacingOccurrences(of: "|", with: " | ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        // Keep the tag itself: a short uppercase prefix is not proof of a country.
        if words.count > 3, words[0] == "|", words[2] == "|",
           (2...5).contains(words[1].count),
           words[1].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
            words.removeFirst()
        }

        var end = words.count
        while end > 1 {
            if let tag = spacedTags.first(where: {
                end > $0.count && Array(words[(end - $0.count)..<end]) == $0
            }) {
                words.replaceSubrange((end - tag.count)..<end, with: [tag.joined()])
                end -= tag.count
            } else {
                let word = words[end - 1]
                let normalized = superscriptTags[word] ?? word
                guard isFeedDescriptor(normalized) else { break }
                words[end - 1] = normalized
                end -= 1
            }
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? name : result
    }

    private static let spacedTags = [
        ["U", "H", "D"], ["F", "H", "D"], ["H", "D"], ["S", "D"]
    ]
    private static let superscriptTags = [
        "\u{1D34}\u{1D30}": "HD",
        "\u{1DA0}\u{1D34}\u{1D30}": "FHD",
        "\u{1D41}\u{1D34}\u{1D30}": "UHD",
        "\u{02E2}\u{1D30}": "SD"
    ]
    private static let feedDescriptors: Set<String> = [
        "HD", "FHD", "UHD", "SD", "4K", "8K", "HDR", "HDR10", "HEVC", "H264", "H265", "H.264", "H.265"
    ]

    private static func isFeedDescriptor(_ word: String) -> Bool {
        let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]")).uppercased()
        if feedDescriptors.contains(token) { return true }
        let number: Substring
        if token.hasSuffix("FPS") { number = token.dropLast(3) }
        else if token.hasSuffix("P") { number = token.dropLast() }
        else if token.hasPrefix("+") { number = token.dropFirst() }
        else { number = token[...] }
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
