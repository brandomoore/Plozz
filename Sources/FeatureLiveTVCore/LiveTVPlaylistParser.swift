import CryptoKit
import CoreModels
import Foundation

public struct LiveTVPlaylistImport: Codable, Sendable {
    public let channels: [LiveTVPrototypeChannel]
    public let entryCount: Int
    public let skippedEntryCount: Int
    public let declaredGuideURLs: [URL]
    public let permitsPersistence: Bool
    public let originURL: URL?

    public init(
        channels: [LiveTVPrototypeChannel],
        entryCount: Int,
        skippedEntryCount: Int,
        declaredGuideURLs: [URL] = [],
        permitsPersistence: Bool = true, originURL: URL? = nil
    ) {
        self.channels = channels
        self.entryCount = entryCount
        self.skippedEntryCount = skippedEntryCount
        self.declaredGuideURLs = declaredGuideURLs
        self.permitsPersistence = permitsPersistence
        self.originURL = originURL
    }
}

public enum LiveTVSourceImportError: Error, Equatable, Sendable {
    case cancelled
    case downloadFailed
    case invalidResponse
    case responseTooLarge
    case invalidPlaylist
    case streamManifest
    case invalidGuide
    case guideTooLarge
    case guideSourceLimitReached
    case cacheFailed
    case unsafeGuideOrigin
    case guideWithoutPlaylist
    case authenticationRequired, temporarilyUnavailable, tooManyRequests, redirectBlocked

    public var userDescription: LocalizedStringResource {
        switch self {
        case .cancelled:
            "The Live TV import was cancelled."
        case .downloadFailed:
            "Plozz couldn't download the Live TV source."
        case .invalidResponse:
            "The Live TV source returned an invalid response."
        case .responseTooLarge:
            "The Live TV playlist is too large to import safely."
        case .invalidPlaylist:
            "The Live TV playlist isn't a supported M3U file."
        case .streamManifest:
            "This link is a video stream, not a channel playlist. Use your provider's M3U channel-list link."
        case .invalidGuide:
            "The Live TV guide isn't a supported XMLTV file."
        case .guideTooLarge:
            "The Live TV guide is too large to import safely."
        case .guideSourceLimitReached:
            "Some playlist-declared guides weren't added automatically. Use up to 32 preferred guide URLs for this source; its channels are still available."
        case .cacheFailed:
            "Your saved Live TV catalog couldn't be updated. The previous catalog has been kept."
        case .unsafeGuideOrigin:
            "This playlist declares a guide on another origin. Add that guide address explicitly in Sources to allow it."
        case .guideWithoutPlaylist:
            "This address contains a program guide, not playable channels. Add it to an existing playlist's guide sources."
        case .authenticationRequired:
            "This source rejected access. Check its address or credentials in Sources."
        case .temporarilyUnavailable:
            "This source is temporarily unavailable. Previously loaded channels and listings have been kept."
        case .tooManyRequests:
            "This source is limiting requests. Wait before refreshing again."
        case .redirectBlocked:
            "This source redirects outside its allowed origin. Add the destination address explicitly if you trust it."
        }
    }

    public var errorDescription: LocalizedStringResource {
        userDescription
    }
}

public struct LiveTVPlaylistParser: Sendable {
    public static let maximumBytes = 128 * 1_024 * 1_024
    public static let maximumEntries = 100_000
    public static let maximumLineBytes = 64 * 1_024
    // Contrast hints must not pull the regression channel catalog into shipping builds.
    private static let darkLogoURLs = Set(
        ["https://i.imgur.com/xP7Ehn8.png"].compactMap { URL(string: $0) }
    )

    private let baseURL: URL?

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    public func parse(_ data: Data) throws -> LiveTVPlaylistImport {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else {
            throw limitExceeded(.inputBytes, observed: data.count, maximum: Self.maximumBytes)
        }
        var stream = makeStream()
        try stream.append(data)
        return try stream.finish()
    }

    public func parse(_ text: String) throws -> LiveTVPlaylistImport {
        guard text.utf8.count <= Self.maximumBytes else {
            throw limitExceeded(.decodedBytes, observed: text.utf8.count, maximum: Self.maximumBytes)
        }
        var stream = makeStream()
        for byte in text.utf8 { try stream.append(byte) }
        return try stream.finish()
    }

    public func makeStream() -> Stream { Stream(parser: self) }

    public struct Stream: Sendable {
        private let parser: LiveTVPlaylistParser
        private var lineBuffer = Data()
        private var lineByteCount = 0
        private var previousByte: UInt8 = 0
        private var penultimateByte: UInt8 = 0
        private var hasHeader = false
        private var isHLS = false
        public private(set) var hasPlayableHLSTag = false
        public private(set) var byteCount = 0
        private var channels: [LiveTVPrototypeChannel] = []
        private var pending: PendingEntry?
        private var entryCount = 0
        private var skippedEntryCount = 0
        private var fallbackNumber = 0
        private var importedIDs = Set<String>()
        private var declaredGuideURLs: [URL] = []

        fileprivate init(parser: LiveTVPlaylistParser) { self.parser = parser }

        var bufferedByteCount: Int { lineBuffer.count }

        public mutating func append(_ data: Data) throws {
            for byte in data { try append(byte) }
        }

        public mutating func append(_ byte: UInt8) throws {
            if byteCount.isMultiple(of: 16_384) { try Task.checkCancellation() }
            byteCount += 1
            guard byteCount <= LiveTVPlaylistParser.maximumBytes else {
                throw parser.limitExceeded(.inputBytes, observed: byteCount, maximum: LiveTVPlaylistParser.maximumBytes)
            }
            let separatorLength: Int
            if (10...13).contains(byte) {
                separatorLength = 1
            } else if byte == 0x85, previousByte == 0xC2 {
                separatorLength = 2
            } else if (byte == 0xA8 || byte == 0xA9), previousByte == 0x80, penultimateByte == 0xE2 {
                separatorLength = 3
            } else {
                separatorLength = 0
            }
            penultimateByte = previousByte
            previousByte = byte
            lineByteCount += 1
            if lineBuffer.count < LiveTVPlaylistParser.maximumLineBytes + 3 { lineBuffer.append(byte) }
            if separatorLength > 0 {
                if lineByteCount == lineBuffer.count { lineBuffer.removeLast(separatorLength) }
                lineByteCount -= separatorLength
                try consumeBufferedLine()
            }
        }

        public mutating func finish() throws -> LiveTVPlaylistImport {
            try Task.checkCancellation()
            if lineByteCount > 0 { try consumeBufferedLine() }
            if isHLS { throw LiveTVSourceImportError.streamManifest }
            if pending != nil { skippedEntryCount += 1; pending = nil }
            guard hasHeader, entryCount > 0 else { throw LiveTVSourceImportError.invalidPlaylist }
            return LiveTVPlaylistImport(
                channels: channels, entryCount: entryCount, skippedEntryCount: skippedEntryCount,
                declaredGuideURLs: declaredGuideURLs, originURL: parser.baseURL
            )
        }

        private mutating func consumeBufferedLine() throws {
            defer {
                lineBuffer.removeAll(keepingCapacity: true)
                lineByteCount = 0
                previousByte = 0
                penultimateByte = 0
            }
            guard lineByteCount <= LiveTVPlaylistParser.maximumLineBytes else {
                if !hasHeader {
                    throw parser.limitExceeded(.headerLineBytes, observed: lineByteCount,
                                               maximum: LiveTVPlaylistParser.maximumLineBytes)
                }
                if lineBuffer.starts(with: Data("#EXTINF:".utf8)) {
                    try countEntry()
                    skippedEntryCount += 1
                }
                if pending != nil { skippedEntryCount += 1; pending = nil }
                return
            }
            guard let rawLine = String(data: lineBuffer, encoding: .utf8)
                ?? String(data: lineBuffer, encoding: .isoLatin1) else {
                throw LiveTVSourceImportError.invalidPlaylist
            }
            for line in rawLine.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                try consumeLine(String(line))
            }
        }

        private mutating func consumeLine(_ rawLine: String) throws {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasHeader, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { return }
            if !hasHeader {
                guard line.hasPrefix("#EXTM3U") else { throw LiveTVSourceImportError.invalidPlaylist }
                hasHeader = true
                let attributes = parser.parseAttributes(String(line.dropFirst("#EXTM3U".count)))
                for key in ["url-tvg", "x-tvg-url"] {
                    for address in (attributes[key] ?? "").split(separator: ",") {
                        if let url = parser.supportedURL(
                            address.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: parser.baseURL
                        ), !declaredGuideURLs.contains(url) { declaredGuideURLs.append(url) }
                    }
                }
                return
            }
            if line.hasPrefix("#EXT-X-") {
                isHLS = true
                hasPlayableHLSTag = hasPlayableHLSTag || line.hasPrefix("#EXT-X-STREAM-INF:")
                    || line.hasPrefix("#EXT-X-TARGETDURATION:")
                channels.removeAll(keepingCapacity: false)
                importedIDs.removeAll(keepingCapacity: false)
                pending = nil
                return
            }
            guard !isHLS else { return }
            if line.hasPrefix("#EXTINF:") {
                if pending != nil { skippedEntryCount += 1 }
                try countEntry()
                pending = parser.parseEXTINF(line)
                if pending == nil { skippedEntryCount += 1 }
                return
            }
            if line.hasPrefix("#EXTVLCOPT:") {
                guard var entry = pending, let header = parser.parseVLCOption(line) else { return }
                entry.headers[header.name] = header.value
                pending = entry
                return
            }
            guard !line.hasPrefix("#"), var entry = pending else { return }
            pending = nil
            let pipe = line.firstIndex(of: "|")
            let address = pipe.map { String(line[..<$0]) } ?? line
            guard let streamURL = parser.supportedURL(address, relativeTo: parser.baseURL) else {
                skippedEntryCount += 1
                return
            }
            if let pipe {
                for header in parser.parsePipeHeaders(line[line.index(after: pipe)...]) {
                    entry.headers[header.name] = header.value
                }
            }
            fallbackNumber += 1
            let tvgID = parser.clean(entry.attributes["tvg-id"])
            let logoURL = parser.clean(entry.attributes["tvg-logo"])
                .flatMap { parser.supportedURL($0, relativeTo: parser.baseURL) }
            let groups = parser.categoryNames(from: entry.attributes["group-title"])
            let groupDescription = groups.isEmpty ? "Other" : groups.joined(separator: " • ")
            let digestInput = [tvgID ?? "", entry.name, streamURL.absoluteString].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(digestInput.utf8)).map { String(format: "%02x", $0) }.joined()
            let channelID = "iptv-\(digest)"
            guard importedIDs.insert(channelID).inserted else { skippedEntryCount += 1; return }
            channels.append(LiveTVPrototypeChannel(
                id: channelID, number: parser.validChannelNumber(entry.attributes["tvg-chno"]) ?? fallbackNumber,
                name: entry.name, category: groups.first ?? "Other", symbol: parser.symbol(for: groupDescription),
                accent: parser.accent(for: digest), source: .iptv, tagline: groupDescription,
                logoURL: logoURL, streamURL: streamURL,
                logoNeedsDarkBackground: logoURL.map(LiveTVPlaylistParser.darkLogoURLs.contains) ?? false,
                guideID: tvgID, guideName: parser.clean(entry.attributes["tvg-name"]), httpHeaders: entry.headers,
                language: parser.clean(entry.attributes["tvg-language"]),
                country: parser.clean(entry.attributes["tvg-country"]), groups: groups
            ))
        }

        private mutating func countEntry() throws {
            entryCount += 1
            guard entryCount <= LiveTVPlaylistParser.maximumEntries else {
                throw parser.limitExceeded(.entries, observed: entryCount, maximum: LiveTVPlaylistParser.maximumEntries)
            }
        }
    }

    private func limitExceeded(
        _ limit: LiveTVPlaylistLimitDiagnostic.Limit, observed: Int, maximum: Int
    ) -> LiveTVSourceImportError {
        LiveTVPlaylistLimitDiagnostic(limit: limit, observed: Int64(observed), maximum: Int64(maximum)).publish()
        return .responseTooLarge
    }

    private struct PendingEntry {
        let name: String
        let attributes: [String: String]
        var headers: [String: String] = [:]
    }

    private func parseEXTINF(_ line: String) -> PendingEntry? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let payload = line[line.index(after: colon)...]
        guard let comma = firstUnquotedComma(in: payload) else { return nil }
        let metadata = payload[..<comma]
        let rawName = payload[payload.index(after: comma)...]
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 1_024 else { return nil }
        return PendingEntry(
            name: name,
            attributes: parseAttributes(String(metadata))
        )
    }

    private func firstUnquotedComma(in text: Substring) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if (character == "\"" || character == "'") && !escaped {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            }
            if character == "," && quote == nil {
                return index
            }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
        }
        return nil
    }

    private func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            let keyStart = index
            while index < text.endIndex,
                  text[index] != "=",
                  !text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard keyStart < index else { break }
            let key = text[keyStart..<index].lowercased()
            let keyEnd = index
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "=" else {
                // A bare duration/token must not consume the attribute after it.
                index = keyEnd
                continue
            }
            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            var value = ""
            if text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                while index < text.endIndex, text[index] != quote {
                    if text[index] == "\\" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == quote || text[next] == "\\" {
                            index = next
                        }
                    }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index)
                }
            } else {
                while index < text.endIndex, !text[index].isWhitespace {
                    value.append(text[index])
                    index = text.index(after: index)
                }
            }
            if value.count <= 8_192 {
                result[key] = value
            }
        }
        return result
    }

    private func parseVLCOption(_ line: String) -> (name: String, value: String)? {
        let prefix = "#EXTVLCOPT:"
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let keyStart = line.index(line.startIndex, offsetBy: prefix.count)
        let key = line[keyStart..<separator].lowercased()
        let value = line[line.index(after: separator)...]
        switch key {
        case "http-referrer", "http-referer":
            return header(named: "Referer", value: String(value))
        case "http-user-agent":
            return header(named: "User-Agent", value: String(value))
        default:
            return nil
        }
    }

    private func parsePipeHeaders(_ suffix: Substring) -> [(name: String, value: String)] {
        suffix.split(separator: "&").compactMap { pair in
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let key = pair[..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(pair[pair.index(after: separator)...])
            let value = rawValue.removingPercentEncoding ?? rawValue
            switch key {
            case "user-agent":
                return header(named: "User-Agent", value: value)
            case "referer", "referrer":
                return header(named: "Referer", value: value)
            default:
                return nil
            }
        }
    }

    private func header(named name: String, value: String) -> (name: String, value: String)? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Scalars, not Characters: "\r\n" is one grapheme and would slip past `contains("\r")`.
        guard !value.isEmpty, value.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        switch name {
        case "Referer":
            guard let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host != nil,
                  url.user == nil,
                  url.password == nil
            else { return nil }
            return ("Referer", value)
        case "User-Agent":
            return ("User-Agent", value)
        default:
            return nil
        }
    }

    private func supportedURL(_ text: String, relativeTo baseURL: URL?) -> URL? {
        guard text.count <= 16_384,
              let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

    private func validChannelNumber(_ text: String?) -> Int? {
        guard let text, let number = Int(text), number > 0 else { return nil }
        return number
    }

    private func categoryNames(from value: String?) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value.split(separator: ";").compactMap { component in
            let category = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty,
                  category.count <= 256,
                  seen.insert(category.lowercased()).inserted
            else { return nil }
            return category
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let cleaned = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else { return nil }
        return cleaned
    }

    private func accent(for digest: String) -> Int {
        Int(digest.prefix(2), radix: 16).map { $0 % 6 } ?? 0
    }

    private func symbol(for group: String) -> String {
        let lower = group.lowercased()
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("sport") { return "sportscourt.fill" }
        if lower.contains("music") { return "music.note" }
        if lower.contains("kids") || lower.contains("animation") {
            return "sparkles.tv.fill"
        }
        if lower.contains("relig") { return "building.columns.fill" }
        return "tv.fill"
    }
}
