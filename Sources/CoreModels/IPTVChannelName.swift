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
        // Most lineups are ASCII, and a large one cleans tens of thousands of names
        // while Live TV opens. The byte path applies the same rules without Unicode work.
        cleanedASCII(name) ?? cleanedUnicode(name)
    }

    static func cleanedUnicode(_ name: String) -> String {
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

    /// The rules of `cleanedUnicode` for an ASCII name; `nil` for any other name.
    /// Plain loops over bytes: this also has to be quick in unoptimized builds.
    private static func cleanedASCII(_ name: String) -> String? {
        var contiguous = name
        return contiguous.withUTF8 { bytes -> String? in
            let count = bytes.count
            var index = 0
            while index < count {
                if bytes[index] >= 0x80 { return nil }
                index += 1
            }
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count + 1) { value -> String in
                // Whitespace runs collapse to one space; leading and trailing runs vanish.
                var length = 0
                var pendingSpace = false
                index = 0
                while index < count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) {
                        pendingSpace = length > 0
                    } else {
                        if pendingSpace { value[length] = 0x20; length += 1; pendingSpace = false }
                        value[length] = byte
                        length += 1
                    }
                }
                var lower = 0
                var upper = length
                if length > 0, value[0] == 0x23 || value[0] == 0x2A {
                    let marker = value[0]
                    var leading = 0
                    while leading < length, value[leading] == marker { leading += 1 }
                    var trailing = 0
                    while trailing < length, value[length - 1 - trailing] == marker { trailing += 1 }
                    if leading >= 2, trailing >= 2, leading + trailing < length {
                        var start = leading
                        var end = length - trailing
                        while start < end, value[start] == 0x20 { start += 1 }
                        while end > start, value[end - 1] == 0x20 { end -= 1 }
                        var scan = start
                        while scan < end, !isASCIILetterOrDigit(value[scan]) { scan += 1 }
                        if scan < end { lower = start; upper = end }
                    }
                }

                // A word is a byte range, or (when `tags` is set) a spaced tag that has been joined.
                var starts: [Int] = []
                var ends: [Int] = []
                var wordStart = -1
                index = lower
                while index < upper {
                    let byte = value[index]
                    if byte == 0x20 || byte == 0x7C {
                        if wordStart >= 0 { starts.append(wordStart); ends.append(index); wordStart = -1 }
                        if byte == 0x7C { starts.append(index); ends.append(index + 1) }
                    } else if wordStart < 0 {
                        wordStart = index
                    }
                    index += 1
                }
                if wordStart >= 0 { starts.append(wordStart); ends.append(upper) }
                var first = 0
                var wordCount = starts.count
                if wordCount > 3, ends[0] - starts[0] == 1, value[starts[0]] == 0x7C,
                   ends[2] - starts[2] == 1, value[starts[2]] == 0x7C,
                   ends[1] - starts[1] >= 2, ends[1] - starts[1] <= 5 {
                    var scan = starts[1]
                    while scan < ends[1], isASCIIUppercase(value[scan]) || isASCIIDigit(value[scan]) { scan += 1 }
                    if scan == ends[1] { first = 1 }
                }
                wordCount -= first

                // `tags[word]` names the spaced tag that word and its followers were joined into.
                var tags: [Int: Int] = [:]
                var skipped: [Int: Int] = [:]
                var end = wordCount
                while end > 1 {
                    var matched = -1
                    var candidate = 0
                    while candidate < asciiSpacedTags.count, matched < 0 {
                        let tag = asciiSpacedTags[candidate]
                        if end > tag.count {
                            var offset = 0
                            while offset < tag.count {
                                let word = first + end - tag.count + offset
                                if ends[word] - starts[word] != 1 || value[starts[word]] != tag[offset] { break }
                                offset += 1
                            }
                            if offset == tag.count { matched = candidate }
                        }
                        candidate += 1
                    }
                    if matched >= 0 {
                        let size = asciiSpacedTags[matched].count
                        tags[first + end - size] = matched
                        skipped[first + end - size] = size
                        end -= size
                    } else {
                        let word = first + end - 1
                        guard isASCIIFeedDescriptor(value, starts[word], ends[word]) else { break }
                        end -= 1
                    }
                }
                guard wordCount > 0 else { return name }
                var result: [UInt8] = []
                result.reserveCapacity(upper - lower)
                var word = first
                while word < starts.count {
                    if word > first { result.append(0x20) }
                    if let tag = tags[word] {
                        result.append(contentsOf: asciiSpacedTags[tag])
                        word += skipped[word] ?? 1
                    } else {
                        var scan = starts[word]
                        while scan < ends[word] { result.append(value[scan]); scan += 1 }
                        word += 1
                    }
                }
                return String(decoding: result, as: UTF8.self)
            }
        }
    }

    private static let asciiSpacedTags: [[UInt8]] = spacedTags.map { $0.flatMap { Array($0.utf8) } }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isASCIIUppercase(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || isASCIIUppercase(byte) || (byte >= 0x61 && byte <= 0x7A)
    }
    private static func isASCIIBracket(_ byte: UInt8) -> Bool {
        byte == 0x28 || byte == 0x29 || byte == 0x5B || byte == 0x5D
    }

    private static func isASCIIFeedDescriptor(
        _ value: UnsafeMutableBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> Bool {
        var lower = start
        var upper = end
        while lower < upper, isASCIIBracket(value[lower]) { lower += 1 }
        while upper > lower, isASCIIBracket(value[upper - 1]) { upper -= 1 }
        func byte(_ index: Int) -> UInt8 {
            let raw = value[index]
            return raw >= 0x61 && raw <= 0x7A ? raw - 0x20 : raw
        }
        func allDigits(_ from: Int, _ to: Int) -> Bool {
            guard from < to else { return false }
            var scan = from
            while scan < to, isASCIIDigit(value[scan]) { scan += 1 }
            return scan == to
        }
        let length = upper - lower
        // Every named descriptor starts with a letter or digit and has two to five characters.
        if length >= 2, length <= 5 {
            var token = [UInt8](repeating: 0, count: length)
            var scan = 0
            while scan < length { token[scan] = byte(lower + scan); scan += 1 }
            if feedDescriptors.contains(String(decoding: token, as: UTF8.self)) { return true }
        }
        if length >= 3, byte(upper - 3) == 0x46, byte(upper - 2) == 0x50, byte(upper - 1) == 0x53 {
            return allDigits(lower, upper - 3)
        }
        if length >= 1, byte(upper - 1) == 0x50 { return allDigits(lower, upper - 1) }
        if length >= 1, value[lower] == 0x2B { return allDigits(lower + 1, upper) }
        return allDigits(lower, upper)
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
